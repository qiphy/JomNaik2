import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'models/itinerary.dart';
import 'offline_bundle_store.dart';

/// Static, on-device public-transit fallback. It deliberately has no live
/// vehicle, traffic, weather, or crowdsourcing inputs; callers must label its
/// results accordingly.
class OfflineRaptorRouter {
  static const _asset = 'assets/offline/raptor_klang_valley.json';
  static const _maximumTransitWaitSeconds = 45 * 60;
  Map<String, dynamic>? _data;
  List<_Trip>? _trips;
  final _store = OfflineBundleStore();

  /// Polls the optional small backend for a newer static timetable bundle.
  /// Failure is intentionally ignored: the bundled timetable remains usable.
  Future<void> refreshFromBackend(String baseUrl) async {
    try {
      final manifestResponse = await http
          .get(Uri.parse('$baseUrl/api/offline/manifest'))
          .timeout(const Duration(seconds: 10));
      if (manifestResponse.statusCode != 200) {
        return;
      }
      final manifest = jsonDecode(manifestResponse.body);
      if (manifest is! Map ||
          manifest['downloadUrl'] is! String ||
          manifest['version'] is! String) {
        return;
      }
      if (await _store.readVersion() == manifest['version']) {
        return;
      }
      final bundleResponse = await http
          .get(Uri.parse(manifest['downloadUrl'] as String))
          .timeout(const Duration(seconds: 45));
      if (bundleResponse.statusCode != 200 ||
          bundleResponse.bodyBytes.isEmpty) {
        return;
      }
      final bundle = utf8.decode(bundleResponse.bodyBytes);
      final decoded = jsonDecode(bundle);
      if (decoded is! Map || decoded['version'] != 1) {
        return;
      }
      await _store.writeBundle(bundle, manifest['version'] as String);
      _data = Map<String, dynamic>.from(decoded);
      _trips = null;
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> plan({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    DateTime? departure,
    String? fromStopId,
    String? toStopId,
    String walkingPreference = 'standard',
  }) async {
    final data = await _load();
    final trips = _trips ??= (data['trips'] as List)
        .whereType<List>()
        .map(_Trip.fromRaw)
        .toList(growable: false);
    final stops = Map<String, dynamic>.from(data['stops'] as Map);
    final when = departure ?? DateTime.now();
    final dayStart = DateTime(when.year, when.month, when.day);
    var startSeconds = when.difference(dayStart).inSeconds;
    if (startSeconds < 0) {
      startSeconds = (startSeconds % 86400 + 86400) % 86400;
    }
    // The bundled timetable has no verified pedestrian accessibility tags.
    // Slower estimates make constrained preferences favor less walking.
    final walkingSpeed = switch (walkingPreference) {
      'avoid_stairs' => 1.0,
      'step_free' => 0.8,
      _ => 1.25,
    };
    // Find transit stops within walking distance (<= 1000m) and an unlimited
    // hybrid radius (e-hailing can reach any stop). Searching walkable stops
    // separately ensures genuine walking-access public transit (such as BRT at
    // South Quay) is never pruned by a distant station reached via e-hailing.
    final walkableOrigins = _nearby(
      stops,
      fromLat,
      fromLon,
      preferred: fromStopId,
      maxDistanceMeters: 1000,
      walkingSpeed: walkingSpeed,
    );
    final allOrigins = _nearby(
      stops,
      fromLat,
      fromLon,
      preferred: fromStopId,
      maxDistanceMeters: double.infinity,
      walkingSpeed: walkingSpeed,
      targetLat: toLat,
      targetLon: toLon,
    );

    final walkableDestinations = _nearby(
      stops,
      toLat,
      toLon,
      preferred: toStopId,
      maxDistanceMeters: 1000,
      walkingSpeed: walkingSpeed,
    );
    final allDestinations = _nearby(
      stops,
      toLat,
      toLon,
      preferred: toStopId,
      maxDistanceMeters: double.infinity,
      walkingSpeed: walkingSpeed,
    );

    if (allOrigins.isEmpty || allDestinations.isEmpty) {
      return null;
    }

    final activeTrips = <_Trip>[];
    for (final trip in trips) {
      if (_serviceActive(trip.serviceId, when, data)) {
        activeTrips.add(trip);
      }
    }
    // Account for overnight trips from yesterday's service calendar (trips running past 24:00)
    // when departing in early morning hours (before 4:00 AM)
    if (startSeconds < 14400) {
      final yesterday = when.subtract(const Duration(days: 1));
      for (final trip in trips) {
        if (_serviceActive(trip.serviceId, yesterday, data)) {
          final hasOvernight = trip.calls
                  .any((c) => c.arrival >= 86400 || c.departure >= 86400) ||
              trip.frequencies.any((f) => f.length >= 2 && f[1] >= 86400);
          if (hasOvernight) {
            activeTrips.add(_shiftTripByDay(trip, -86400));
          }
        }
      }
    }

    final rawItineraries = <Map<String, dynamic>>[];

    // Pass 1: Walkable access. Always plan pure public-transit if walkable stops exist.
    if (walkableOrigins.isNotEmpty) {
      rawItineraries.addAll(
        _runRaptor(
          origin: walkableOrigins,
          destination: walkableDestinations.isNotEmpty
              ? walkableDestinations
              : allDestinations,
          activeTrips: activeTrips,
          data: data,
          when: when,
          startSeconds: startSeconds,
          fromLat: fromLat,
          fromLon: fromLon,
          toLat: toLat,
          toLon: toLon,
          walkingSpeed: walkingSpeed,
        ),
      );
    }

    // Pass 2: Hybrid access. If there are wider stops, also explore hybrid options.
    if (allOrigins.length > walkableOrigins.length ||
        (walkableDestinations.isEmpty && allDestinations.isNotEmpty)) {
      rawItineraries.addAll(
        _runRaptor(
          origin: allOrigins,
          destination: allDestinations,
          activeTrips: activeTrips,
          data: data,
          when: when,
          startSeconds: startSeconds,
          fromLat: fromLat,
          fromLon: fromLon,
          toLat: toLat,
          toLon: toLon,
          walkingSpeed: walkingSpeed,
        ),
      );
    } else if (walkableOrigins.isEmpty) {
      rawItineraries.addAll(
        _runRaptor(
          origin: allOrigins,
          destination: allDestinations,
          activeTrips: activeTrips,
          data: data,
          when: when,
          startSeconds: startSeconds,
          fromLat: fromLat,
          fromLon: fromLon,
          toLat: toLat,
          toLon: toLon,
          walkingSpeed: walkingSpeed,
        ),
      );
    }

    if (rawItineraries.isEmpty) {
      return null;
    }

    // Deduplicate patterns while preserving distinct transit and access modes
    final deduplicated = <String, Map<String, dynamic>>{};
    for (final it in rawItineraries) {
      final rawLegs = it['legs'];
      final legs = rawLegs is List
          ? rawLegs.whereType<Map>().toList()
          : const <Map>[];
      final transitLegs = legs.where(
        (l) => l['mode'] != 'WALK' && l['mode'] != 'HAIL',
      );
      final transitSig = transitLegs
          .map((l) => '${l['mode']}:${l['routeShortName']}')
          .join('|');
      final firstMode = legs.isNotEmpty ? legs.first['mode'] : 'none';
      final lastMode = legs.isNotEmpty ? legs.last['mode'] : 'none';
      final key = '${it['routeCategory']}|$firstMode|$lastMode|$transitSig';
      final existing = deduplicated[key];
      if (existing == null) {
        deduplicated[key] = it;
      } else {
        final currentDuration =
            (it['duration'] as num?)?.toDouble() ?? double.infinity;
        final existingDuration =
            (existing['duration'] as num?)?.toDouble() ?? double.infinity;
        if (currentDuration < existingDuration) {
          deduplicated[key] = it;
        }
      }
    }

    final itineraries = deduplicated.values.toList();
    final availableItineraries = itineraries.where((it) {
      return isItineraryMapAvailableAtDeparture(it, when);
    }).toList();

    if (availableItineraries.isEmpty) {
      return null;
    }

    double preferenceCost(Map<String, dynamic> itinerary) {
      final duration =
          (itinerary['duration'] as num?)?.toDouble() ?? double.infinity;
      if (walkingPreference == 'standard') return duration;
      final walking = (itinerary['walkingSeconds'] as num?)?.toDouble() ?? 0;
      final transfers = (itinerary['transferCount'] as num?)?.toDouble() ?? 0;
      final walkingWeight = walkingPreference == 'step_free' ? 2.0 : 1.5;
      final transferPenalty = walkingPreference == 'step_free' ? 480 : 240;
      return duration +
          walking * (walkingWeight - 1) +
          transfers * transferPenalty;
    }

    availableItineraries.sort((left, right) {
      final preferenceComparison = preferenceCost(
        left,
      ).compareTo(preferenceCost(right));
      if (preferenceComparison != 0) return preferenceComparison;
      final distanceComparison =
          ((left['distanceMeters'] as num?)?.toDouble() ?? double.infinity)
              .compareTo(
                (right['distanceMeters'] as num?)?.toDouble() ??
                    double.infinity,
              );
      if (distanceComparison != 0) return distanceComparison;
      final durationComparison =
          ((left['duration'] as num?)?.toInt() ?? 1 << 30).compareTo(
            (right['duration'] as num?)?.toInt() ?? 1 << 30,
          );
      if (durationComparison != 0) return durationComparison;
      final transferComparison =
          ((left['transferCount'] as num?)?.toInt() ?? 1 << 30).compareTo(
            (right['transferCount'] as num?)?.toInt() ?? 1 << 30,
          );
      return transferComparison;
    });
    return {'itineraries': availableItineraries, 'offlineRouting': true};
  }

  List<Map<String, dynamic>> _runRaptor({
    required List<_NearbyStop> origin,
    required List<_NearbyStop> destination,
    required List<_Trip> activeTrips,
    required Map<String, dynamic> data,
    required DateTime when,
    required int startSeconds,
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    required double walkingSpeed,
  }) {
    if (origin.isEmpty || destination.isEmpty) return const [];

    final labels = <String, _Label>{};
    for (final stop in origin) {
      labels[stop.id] = _Label(
        arrival: startSeconds + stop.walkSeconds,
        rides: const [],
        initialStop: stop.id,
        initialWalkSeconds: stop.walkSeconds,
      );
    }
    _applyTransfers(labels, data);

    final candidates = <({_Label label, String destination})>[];
    for (var round = 0; round < 4; round++) {
      final next = Map<String, _Label>.from(labels);
      final stops = Map<String, dynamic>.from(data['stops'] as Map);
      for (final trip in activeTrips) {
        _scanTrip(trip, labels, next, stops, fromLat, fromLon);
      }
      _applyTransfers(next, data);
      for (final stop in destination) {
        final label = next[stop.id];
        if (label == null) continue;
        final arrival = label.arrival + stop.walkSeconds;
        candidates.add((
          label: label.copyWith(arrival: arrival),
          destination: stop.id,
        ));
      }
      labels
        ..clear()
        ..addAll(next);
    }
    final uniqueCandidates = <String, ({_Label label, String destination})>{};
    for (final candidate in candidates) {
      if (candidate.label.rides.isEmpty) continue;
      final signature = [
        candidate.destination,
        for (final ride in candidate.label.rides) ride.trip.routeId,
      ].join('|');
      final existing = uniqueCandidates[signature];
      if (existing == null ||
          candidate.label.arrival < existing.label.arrival ||
          (candidate.label.arrival == existing.label.arrival &&
              candidate.label.initialWalkSeconds < existing.label.initialWalkSeconds)) {
        uniqueCandidates[signature] = candidate;
      }
    }
    final transitCandidates = uniqueCandidates.values.toList()
      ..sort(
        (left, right) => left.label.arrival.compareTo(right.label.arrival),
      );
    if (transitCandidates.isEmpty) {
      return const [];
    }
    final itineraries = <Map<String, dynamic>>[];
    for (final candidate in transitCandidates) {
      final route = _toItinerary(
        data: data,
        departure: when,
        startSeconds: startSeconds,
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        destinationStop: candidate.destination,
        label: candidate.label,
        walkingSpeed: walkingSpeed,
      );
      itineraries.addAll(
        (route['itineraries'] as List).whereType<Map<String, dynamic>>(),
      );
    }
    return itineraries;
  }

  Future<Map<String, dynamic>> _load() async {
    if (_data != null) return _data!;
    final raw =
        await _store.readBundle() ?? await rootBundle.loadString(_asset);
    final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    try {
      final rail = jsonDecode(
        await rootBundle.loadString('assets/transit/rail_lines.geojson'),
      );
      if (rail is Map) decoded['railShapes'] = rail['features'];
    } catch (_) {}
    try {
      final transit = jsonDecode(
        await rootBundle.loadString(
          'assets/65f71978-dde6-4d73-86a7-767322b8edbb/Rapid KL.geojson',
        ),
      );
      if (transit is Map) decoded['routeShapes'] = transit['features'];
    } catch (_) {}
    _data = decoded;
    return _data!;
  }

  List<_NearbyStop> _nearby(
    Map<String, dynamic> stops,
    double lat,
    double lon, {
    String? preferred,
    double maxDistanceMeters = 800,
    double walkingSpeed = 1.25,
    double? targetLat,
    double? targetLon,
  }) {
    final choices = <_NearbyStop>[];
    final preferredId = _resolveStopId(preferred, stops);
    if (preferredId != null) {
      final stop = stops[preferredId] as List;
      final stopLat = (stop[1] as num).toDouble();
      final stopLon = (stop[2] as num).toDouble();
      final dist = _distance(lat, lon, stopLat, stopLon);
      choices.add(
        _NearbyStop(
          preferredId,
          dist > 1000
              ? math.max(300, (dist / 9.7).round() + 180)
              : math.max(30, (dist / walkingSpeed).round()),
        ),
      );
      // A tapped transit stop is an explicit destination/origin. Do not
      // replace it with a nearby earlier station simply because another stop
      // has a marginally better coordinate.
      return choices;
    }

    final directDistToTarget = (targetLat != null && targetLon != null)
        ? _distance(lat, lon, targetLat, targetLon)
        : null;

    for (final entry in stops.entries) {
      final stop = entry.value;
      if (stop is! List || stop.length < 3) continue;
      final stopLat = (stop[1] as num).toDouble();
      final stopLon = (stop[2] as num).toDouble();
      final distance = _distance(
        lat,
        lon,
        stopLat,
        stopLon,
      );
      if (distance <= maxDistanceMeters) {
        // Do not route via hybrid e-hailing to a far away station in the opposite
        // direction of the destination (where distance to destination increases).
        if (distance > 1000 && directDistToTarget != null) {
          final stopDistToTarget = _distance(stopLat, stopLon, targetLat!, targetLon!);
          if (stopDistToTarget > directDistToTarget + 400) {
            continue;
          }
        }
        choices.add(
          _NearbyStop(
            entry.key,
            distance > 1000
                ? math.max(300, (distance / 9.7).round() + 180)
                : math.max(30, (distance / walkingSpeed).round()),
          ),
        );
      }
    }
    choices.sort((a, b) => a.walkSeconds.compareTo(b.walkSeconds));
    return choices.take(12).toList();
  }

  String? _resolveStopId(String? preferred, Map<String, dynamic> stops) {
    if (preferred == null || preferred.isEmpty) return null;
    if (stops.containsKey(preferred)) return preferred;
    final suffix = preferred.contains(':')
        ? preferred.substring(preferred.lastIndexOf(':') + 1)
        : preferred;
    for (final id in stops.keys) {
      if (id == suffix || id.endsWith(':$suffix')) return id;
    }
    return null;
  }

  void _scanTrip(
    _Trip trip,
    Map<String, _Label> previous,
    Map<String, _Label> next,
    Map<String, dynamic> stops,
    double fromLat,
    double fromLon,
  ) {
    _Boarding? boarding;
    for (var index = 0; index < trip.calls.length; index++) {
      final call = trip.calls[index];
      final label = previous[call.stopId];
      if (label != null) {
        final departure = trip.nextDeparture(index, label.arrival);

        // If the next departure is more than 45 minutes away, do not wait on the platform
        if (departure != null &&
            departure - label.arrival <= _maximumTransitWaitSeconds) {
          final offset = departure - call.departure;
          final currentOffset = boarding == null
              ? null
              : boarding.departure - trip.calls[boarding.index].departure;
          if (currentOffset == null || offset < currentOffset) {
            boarding = _Boarding(index, departure, label);
          } else if (offset == currentOffset && boarding != null) {
            // For the exact same vehicle run, prefer boarding at a stop closer to the
            // passenger's origin to prevent sending the user backwards to a distant station.
            final currStopData = stops[call.stopId] as List?;
            final boardStopData = stops[trip.calls[boarding.index].stopId] as List?;
            final currDist = currStopData != null && currStopData.length >= 3
                ? _distance(fromLat, fromLon, (currStopData[1] as num).toDouble(), (currStopData[2] as num).toDouble())
                : double.infinity;
            final boardDist = boardStopData != null && boardStopData.length >= 3
                ? _distance(fromLat, fromLon, (boardStopData[1] as num).toDouble(), (boardStopData[2] as num).toDouble())
                : double.infinity;
            if (currDist < boardDist || label.initialWalkSeconds < boarding.label.initialWalkSeconds) {
              boarding = _Boarding(index, departure, label);
            }
          }
        }
      }
      if (boarding == null || index <= boarding.index) continue;
      final arrival = trip.arrivalAt(index, boarding.departure, boarding.index);
      final candidate = _Label(
        arrival: arrival,
        initialStop: boarding.label.initialStop,
        initialWalkSeconds: boarding.label.initialWalkSeconds,
        rides: [
          ...boarding.label.rides,
          _Ride(
            trip: trip,
            fromIndex: boarding.index,
            toIndex: index,
            departure: boarding.departure,
            arrival: arrival,
          ),
        ],
      );
      final existing = next[call.stopId];
      if (existing == null || candidate.arrival < existing.arrival) {
        next[call.stopId] = candidate;
      }
    }
  }

  void _applyTransfers(Map<String, _Label> labels, Map<String, dynamic> data) {
    final transfers = Map<String, dynamic>.from(
      data['transfers'] as Map? ?? const {},
    );
    final stops = Map<String, dynamic>.from(data['stops'] as Map);
    for (var pass = 0; pass < 2; pass++) {
      final updates = <String, _Label>{};
      for (final entry in labels.entries) {
        final links = <dynamic>[
          if (transfers[entry.key] is List) ...(transfers[entry.key] as List),
          ..._nearbyRailTransfers(entry.key, stops),
        ];
        for (final link in links) {
          if (link is! List || link.length < 2) continue;
          final target = link[0].toString();
          final arrival = entry.value.arrival + (link[1] as num).toInt();
          final old = labels[target] ?? updates[target];
          if (old == null || arrival < old.arrival) {
            updates[target] = entry.value.copyWith(arrival: arrival);
          }
        }
      }
      if (updates.isEmpty) {
        break;
      }
      labels.addAll(updates);
    }
  }

  bool _isRailId(String id) =>
      id.startsWith('rapid-kl-rail:') || id.startsWith('ktmb:');

  List<List<Object>> _nearbyRailTransfers(
    String sourceId,
    Map<String, dynamic> stops,
  ) {
    if (!_isRailId(sourceId)) return const [];
    final source = stops[sourceId];
    if (source is! List || source.length < 3) return const [];
    final sourceLat = (source[1] as num?)?.toDouble();
    final sourceLon = (source[2] as num?)?.toDouble();
    if (sourceLat == null || sourceLon == null) return const [];
    final links = <List<Object>>[];
    for (final entry in stops.entries) {
      if (entry.key == sourceId || !_isRailId(entry.key)) {
        continue;
      }
      final target = entry.value;
      if (target is! List || target.length < 3) continue;
      final distance = _distance(
        sourceLat,
        sourceLon,
        (target[1] as num?)?.toDouble() ?? 0,
        (target[2] as num?)?.toDouble() ?? 0,
      );
      if (distance <= 500) {
        links.add([entry.key, math.max(60, (distance / 1.25).round())]);
      }
    }
    return links;
  }

  bool _serviceActive(
    String serviceId,
    DateTime date,
    Map<String, dynamic> data,
  ) {
    final ymd =
        '${date.year.toString().padLeft(4, '0')}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
    final exceptions = Map<String, dynamic>.from(
      data['exceptions'] as Map? ?? const {},
    );
    final exception = exceptions[serviceId] is Map
        ? exceptions[serviceId][ymd]
        : null;
    if (exception == 1) return true;
    if (exception == 2) return false;
    final calendar = (data['calendars'] as Map?)?[serviceId];
    if (calendar is! List) return true;
    final startStr = calendar[7].toString();
    final endStr = calendar[8].toString();
    final isWithinOrPast = ymd.compareTo(startStr) >= 0;
    return isWithinOrPast && calendar[date.weekday - 1] == true;
  }

  _Trip _shiftTripByDay(_Trip trip, int deltaSeconds) => _Trip(
        trip.id,
        trip.routeId,
        trip.serviceId,
        trip.headsign,
        trip.calls
            .map((c) => _Call(
                  c.stopId,
                  c.arrival + deltaSeconds,
                  c.departure + deltaSeconds,
                ))
            .toList(growable: false),
        trip.frequencies
            .map((f) => [f[0] + deltaSeconds, f[1] + deltaSeconds, f[2]])
            .toList(growable: false),
      );

  Map<String, dynamic> _toItinerary({
    required Map<String, dynamic> data,
    required DateTime departure,
    required int startSeconds,
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    required String destinationStop,
    required _Label label,
    required double walkingSpeed,
  }) {
    final stops = Map<String, dynamic>.from(data['stops'] as Map);
    final routes = Map<String, dynamic>.from(data['routes'] as Map);
    final legs = <Map<String, dynamic>>[];

    final initialStopData = stops[label.initialStop] as List?;
    final initialDistance = initialStopData != null && initialStopData.length >= 3
        ? _distance(
            fromLat,
            fromLon,
            (initialStopData[1] as num).toDouble(),
            (initialStopData[2] as num).toDouble(),
          )
        : 0.0;

    if (initialDistance > 1000) {
      // Backtracking check: if the user took e-hailing to a distant station, ensure the
      // transit service does not ride back past a stop closer to the origin.
      if (label.rides.isNotEmpty) {
        final firstRide = label.rides.first;
        for (var n = firstRide.fromIndex + 1; n <= firstRide.toIndex; n++) {
          final interData = stops[firstRide.trip.calls[n].stopId] as List?;
          if (interData != null && interData.length >= 3) {
            final interDist = _distance(
              fromLat,
              fromLon,
              (interData[1] as num).toDouble(),
              (interData[2] as num).toDouble(),
            );
            if (interDist < initialDistance - 300) {
              return const {'itineraries': <Map<String, dynamic>>[]};
            }
          }
        }
      }

      final hailSeconds = math.max(300, (initialDistance / 9.7).round() + 180);
      legs.add({
        'mode': 'HAIL',
        'startTime': _iso(departure, startSeconds),
        'endTime': _iso(departure, startSeconds + hailSeconds),
        'routeShortName': 'E-hailing to nearest stop',
        'paymentMethod': 'Pay in the e-hailing app',
        'isFirstMile': true,
        'from': {'name': 'Start', 'lat': fromLat, 'lon': fromLon},
        'to': _place(label.initialStop, stops),
      });
    } else if (label.initialWalkSeconds > 0) {
      final isDirectPedestrian = initialDistance <= 250;
      legs.add(
        _walkLeg(
          departure,
          startSeconds,
          startSeconds + label.initialWalkSeconds,
          fromLat,
          fromLon,
          label.initialStop,
          stops,
          false,
          isDirectPedestrian: isDirectPedestrian,
          geometry: isDirectPedestrian
              ? [
                  [fromLon, fromLat],
                  _placeCoordinates(label.initialStop, stops),
                ]
              : null,
        ),
      );
    }

    for (var i = 0; i < label.rides.length; i++) {
      final ride = label.rides[i];
      if (i > 0 && label.rides[i - 1].toStop != ride.fromStop) {
        final transferPath = _shortestTransferPath(
          label.rides[i - 1].toStop,
          ride.fromStop,
          data,
        );
        legs.add(
          _walkLeg(
            departure,
            label.rides[i - 1].arrival,
            ride.departure,
            null,
            null,
            ride.fromStop,
            stops,
            true,
            fromStop: label.rides[i - 1].toStop,
            geometry: transferPath
                .map((stopId) => _placeCoordinates(stopId, stops))
                .toList(),
          ),
        );
      }
      final route = routes[ride.trip.routeId] as List? ?? const [];
      final mode = _mode(route.length > 2 ? route[2] as int : 3);
      final shapeGeometry = _routeGeometry(
        routeId: ride.trip.routeId,
        fromStop: ride.fromStop,
        toStop: ride.toStop,
        stops: stops,
        shapes: [
          if (data['railShapes'] is List) ...(data['railShapes'] as List),
          if (data['routeShapes'] is List) ...(data['routeShapes'] as List),
        ],
        fallback: const [],
      );
      final geometry = shapeGeometry.isNotEmpty
          ? shapeGeometry
          : [
              for (var n = ride.fromIndex; n <= ride.toIndex; n++)
                _placeCoordinates(ride.trip.calls[n].stopId, stops),
            ];
      final routeShortName = route.isNotEmpty ? route[0].toString() : 'Service';
      final terminus = _resolveLegTerminus(
        ride: ride,
        routeShortName: routeShortName,
        stops: stops,
        data: data,
      );
      final effectiveHeadsign = terminus ?? (ride.trip.headsign.isNotEmpty ? ride.trip.headsign : null);

      legs.add({
        'mode': mode,
        'startTime': _iso(departure, ride.departure),
        'endTime': _iso(departure, ride.arrival),
        'routeShortName': routeShortName,
        'headsign': effectiveHeadsign,
        'terminus': terminus,
        'from': _place(ride.fromStop, stops),
        'to': _place(ride.toStop, stops),
        // The offline bundle has no road graph, but the ordered GTFS stops
        // provide a useful transit alignment instead of a single endpoint
        // segment.
        'legGeometry': {'type': 'LineString', 'coordinates': geometry},
        if (shapeGeometry.isEmpty && mode == 'BUS')
          'geometryQuality': 'unverified',
        'intermediateStops': [
          for (var n = ride.fromIndex + 1; n < ride.toIndex; n++)
            _place(ride.trip.calls[n].stopId, stops),
        ],
      });
    }

    final lastArrival = label.rides.last.arrival;
    final last = label.rides.last.toStop;
    final finalWalk = _distance(
      ((stops[last] as List)[1] as num).toDouble(),
      ((stops[last] as List)[2] as num).toDouble(),
      toLat,
      toLon,
    );
    if (finalWalk > 1000) {
      // If the destination is more than 1km from the last transit stop,
      // change the final stretch to use a car route and e-hailing.
      final hailSeconds = math.max(300, (finalWalk / 9.7).round() + 180);
      legs.add({
        'mode': 'HAIL',
        'startTime': _iso(departure, lastArrival),
        'endTime': _iso(departure, lastArrival + hailSeconds),
        'routeShortName': 'E-hailing from nearest stop',
        'paymentMethod': 'Pay in the e-hailing app',
        'isLastMile': true,
        'from': _place(last, stops),
        'to': {'name': 'Destination', 'lat': toLat, 'lon': toLon},
      });
    } else if (finalWalk > 20) {
      final isDirectPedestrian = finalWalk <= 250;
      legs.add(
        _walkLeg(
          departure,
          lastArrival,
          label.arrival,
          null,
          null,
          destinationStop,
          stops,
          false,
          toLat: toLat,
          toLon: toLon,
          fromStop: last,
          isDirectPedestrian: isDirectPedestrian,
          geometry: isDirectPedestrian
              ? [
                  _placeCoordinates(last, stops),
                  [toLon, toLat],
                ]
              : null,
        ),
      );
    }
    _mergeConsecutiveTransitLegs(legs);
    final transitModes = legs
        .where((leg) => leg['mode'] != 'WALK' && leg['mode'] != 'HAIL')
        .map((leg) => leg['mode'])
        .toSet();
    final transitRouteIds = label.rides
        .map((ride) => ride.trip.routeId)
        .toSet();
    final walkingSeconds = legs.where((leg) => leg['mode'] == 'WALK').fold<int>(
      0,
      (total, leg) {
        final start = DateTime.tryParse(leg['startTime']?.toString() ?? '');
        final end = DateTime.tryParse(leg['endTime']?.toString() ?? '');
        return total +
            (start != null && end != null
                ? end.difference(start).inSeconds
                : 0);
      },
    );
    for (final leg in legs) {
      final legDist = _legDistanceMeters(leg);
      leg['distanceMeters'] = legDist;
      final legTo = leg['to'];
      if (legTo is Map && legTo['lat'] is num && legTo['lon'] is num) {
        leg['distanceToDestinationMeters'] = _distance(
          (legTo['lat'] as num).toDouble(),
          (legTo['lon'] as num).toDouble(),
          toLat,
          toLon,
        );
      }
    }
    final distanceMeters = legs.fold<double>(
      0,
      (total, leg) => total + _legDistanceMeters(leg),
    );
    final hasFirstMileHail = legs.isNotEmpty && legs.first['mode'] == 'HAIL';
    final hasLastMileHail = legs.isNotEmpty && legs.last['mode'] == 'HAIL';
    final hasHail = hasFirstMileHail || hasLastMileHail;

    double fareMin = transitModes.isNotEmpty ? 1.50 : 0.0;
    double fareMax = transitModes.isNotEmpty ? 3.50 : 0.0;
    for (final leg in legs) {
      if (leg['mode'] == 'HAIL') {
        final km = _legDistanceMeters(leg) / 1000.0;
        fareMin += km * 1.0;
        fareMax += km * 3.0;
      }
    }

    final durationSeconds = legs.isEmpty
        ? label.arrival - startSeconds
        : (DateTime.parse(legs.last['endTime'] as String)
              .difference(
                DateTime.parse(legs.first['startTime'] as String),
              )
              .inSeconds);

    return {
      'itineraries': [
        {
          'duration': durationSeconds,
          'routeCategory': hasHail
              ? 'hybrid'
              : (transitModes.contains('BUS') ? 'bus' : 'rail'),
          'transferCount': math.max(0, transitRouteIds.length - 1),
          'walkingSeconds': walkingSeconds,
          'distanceMeters': distanceMeters,
          if (hasHail) ...{
            'hybridFirstMile': hasFirstMileHail,
            'hybridLastMile': hasLastMileHail,
            'fareMin': fareMin,
            'fareMax': fareMax,
            'fareLabel': hasFirstMileHail && hasLastMileHail
                ? 'Estimated first and last-mile e-hailing fare'
                : hasLastMileHail
                    ? 'Estimated connecting e-hailing fare'
                    : 'Estimated first-mile e-hailing fare',
            'optionMessage': hasFirstMileHail && hasLastMileHail
                ? 'E-hailing to the nearest stop and from the last stop, with public transport for the main journey.'
                : hasLastMileHail
                    ? 'Public transport with e-hailing for the final mile because the destination is more than 1 km from the last stop.'
                    : 'E-hailing to the nearest stop, followed by public transport. This avoids a long walk to a connecting service.',
          },
          'fallbackMessage':
              'Offline timetable route — last-mile walking or e-hailing is '
              'included when the destination is not practical by bus.',
          'legs': legs,
        },
      ],
      'offlineRouting': true,
    };
  }

  void _mergeConsecutiveTransitLegs(List<Map<String, dynamic>> legs) {
    for (var index = legs.length - 1; index > 0; index--) {
      final previous = legs[index - 1];
      final current = legs[index];
      final previousMode = previous['mode']?.toString().toUpperCase();
      final currentMode = current['mode']?.toString().toUpperCase();
      if (previousMode == null ||
          previousMode != currentMode ||
          previousMode == 'WALK' ||
          previousMode == 'HAIL' ||
          previous['routeShortName']?.toString() !=
              current['routeShortName']?.toString() ||
          previous['headsign']?.toString() != current['headsign']?.toString()) {
        continue;
      }

      final previousTo = previous['to'];
      final currentFrom = current['from'];
      if (previousTo is! Map || currentFrom is! Map) continue;
      final previousToLat = (previousTo['lat'] as num?)?.toDouble();
      final previousToLon = (previousTo['lon'] as num?)?.toDouble();
      final currentFromLat = (currentFrom['lat'] as num?)?.toDouble();
      final currentFromLon = (currentFrom['lon'] as num?)?.toDouble();
      if (previousToLat == null ||
          previousToLon == null ||
          currentFromLat == null ||
          currentFromLon == null ||
          _distance(
                previousToLat,
                previousToLon,
                currentFromLat,
                currentFromLon,
              ) >
              300) {
        continue;
      }

      final previousGeometry = previous['legGeometry'];
      final currentGeometry = current['legGeometry'];
      if (previousGeometry is Map && currentGeometry is Map) {
        final previousCoordinates = previousGeometry['coordinates'];
        final currentCoordinates = currentGeometry['coordinates'];
        if (previousCoordinates is List && currentCoordinates is List) {
          previous['legGeometry'] = {
            ...previousGeometry,
            'coordinates': [
              ...previousCoordinates,
              ...currentCoordinates.skip(1),
            ],
          };
        }
      }
      final previousStops = previous['intermediateStops'];
      final currentStops = current['intermediateStops'];
      previous['intermediateStops'] = [
        if (previousStops is List) ...previousStops,
        previousTo,
        if (currentStops is List) ...currentStops,
      ];
      previous['endTime'] = current['endTime'];
      previous['to'] = current['to'];
      legs.removeAt(index);
    }
  }

  String? _resolveLegTerminus({
    required _Ride ride,
    required String routeShortName,
    required Map<String, dynamic> stops,
    required Map<String, dynamic> data,
  }) {
    final routeId = ride.trip.routeId;
    final isSunwayLine = routeShortName.toUpperCase().contains('SUNWAY') ||
        routeShortName.toUpperCase().contains('BRT') ||
        routeId.contains('B1000') ||
        routeId.contains('BRT');

    if (isSunwayLine) {
      final hasTwoDirections = _routeHasTwoDistinctDirections(routeId, ride, data);
      if (!hasTwoDirections ||
          ride.trip.headsign.trim().isEmpty ||
          _isMisleadingSunwayHeadsign(ride)) {
        return _sunwayLineDirectionTerminus(ride, stops);
      }
    }

    if (ride.trip.headsign.trim().isNotEmpty) {
      return _cleanStationName(ride.trip.headsign.trim());
    }
    if (ride.trip.calls.isNotEmpty) {
      final lastStopId = ride.trip.calls.last.stopId;
      final raw = _place(lastStopId, stops)['name']?.toString();
      if (raw != null && raw.isNotEmpty) {
        return _cleanStationName(raw);
      }
    }
    return null;
  }

  bool _routeHasTwoDistinctDirections(
    String routeId,
    _Ride ride,
    Map<String, dynamic> data,
  ) {
    if (ride.trip.calls.length >= 2 &&
        ride.trip.calls.first.stopId == ride.trip.calls.last.stopId) {
      return false;
    }
    final tripsRaw = data['trips'];
    if (tripsRaw is! List) return false;
    final terminals = <String>{};
    for (final raw in tripsRaw) {
      if (raw is List && raw.length >= 5 && raw[1] == routeId) {
        if (raw.length >= 3 && raw[2] != ride.trip.serviceId) {
          continue;
        }
        final calls = raw[4];
        if (calls is List && calls.length >= 2) {
          final first = calls.first;
          final last = calls.last;
          if (first is List && last is List) {
            final start = first[0].toString();
            final end = last[0].toString();
            if (start != end) {
              terminals.add('$start->$end');
            }
          }
        }
      }
    }
    return terminals.length >= 2;
  }

  bool _isMisleadingSunwayHeadsign(_Ride ride) {
    final headsign = ride.trip.headsign.toUpperCase();
    if (headsign.isEmpty) return true;
    final calls = ride.trip.calls;
    if (calls.isNotEmpty && ride.fromIndex < ride.toIndex) {
      final terminalId = calls.last.stopId;
      if ((terminalId.contains('SETIA') || terminalId.contains('1005840')) &&
          headsign.contains('USJ')) {
        return true;
      }
      if ((terminalId.contains('USJ') || terminalId.contains('1005834')) &&
          headsign.contains('SETIA')) {
        return true;
      }
    }
    return false;
  }

  String _sunwayLineDirectionTerminus(_Ride ride, Map<String, dynamic> stops) {
    final calls = ride.trip.calls;
    if (calls.length >= 13) {
      if (ride.toIndex <= 6) {
        final stopName = _place(calls[6].stopId, stops)['name']?.toString();
        if (stopName != null && stopName.isNotEmpty) {
          return _cleanStationName(stopName);
        }
      } else {
        final stopName = _place(calls.last.stopId, stops)['name']?.toString();
        if (stopName != null && stopName.isNotEmpty) {
          return _cleanStationName(stopName);
        }
      }
    }

    if (calls.isNotEmpty && ride.fromIndex < ride.toIndex) {
      final terminalStopId = calls.last.stopId;
      final stopName = _place(terminalStopId, stops)['name']?.toString();
      if (stopName != null && stopName.isNotEmpty) {
        return _cleanStationName(stopName);
      }
    }

    const corridor = [
      'USJ7',
      'SOUTH QUAY',
      'SUNU-MONASH',
      'SUNMED',
      'SUNWAY LAGOON',
      'MENTARI',
      'SETIA JAYA',
    ];
    final fromName = (_place(ride.fromStop, stops)['name'] ?? '')
        .toString()
        .toUpperCase();
    final toName = (_place(ride.toStop, stops)['name'] ?? '')
        .toString()
        .toUpperCase();
    int indexOf(String name) {
      for (var i = 0; i < corridor.length; i++) {
        if (name.contains(corridor[i])) return i;
      }
      return -1;
    }

    final fromIdx = indexOf(fromName);
    final toIdx = indexOf(toName);
    if (fromIdx != -1 && toIdx != -1 && toIdx < fromIdx) {
      return 'USJ 7';
    }
    return 'Setia Jaya';
  }

  String _cleanStationName(String raw) {
    var cleaned = raw
        .replaceAll(RegExp(r'^STESEN\s+BRT\s+', caseSensitive: false), '')
        .replaceAll(RegExp(r'^STESEN\s+', caseSensitive: false), '')
        .trim();

    final toMatches = RegExp(r'\bto\s+', caseSensitive: false).allMatches(cleaned).toList();
    if (toMatches.isNotEmpty) {
      cleaned = cleaned.substring(toMatches.last.end).trim();
    }

    for (final separator in ['→', '->']) {
      final separatorIndex = cleaned.lastIndexOf(separator);
      if (separatorIndex >= 0) {
        cleaned = cleaned.substring(separatorIndex + separator.length).trim();
      }
    }

    if (RegExp(r'^USJ\s*7$', caseSensitive: false).hasMatch(cleaned)) {
      return 'USJ 7';
    }
    if (RegExp(r'^(SUNWAY[-\s]*)?SETIA\s*JAYA$', caseSensitive: false).hasMatch(cleaned)) {
      return 'Setia Jaya';
    }
    return cleaned;
  }

  List<List<double>> _routeGeometry({
    required String routeId,
    required String fromStop,
    required String toStop,
    required Map<String, dynamic> stops,
    required dynamic shapes,
    required List<List<double>> fallback,
  }) {
    final shortRoute = routeId.split(':').last;
    if (shapes is! List) return fallback;
    for (final feature in shapes) {
      if (feature is! Map ||
          feature['geometry'] is! Map ||
          feature['properties'] is! Map) {
        continue;
      }
      final properties = Map<String, dynamic>.from(
        feature['properties'] as Map,
      );
      if (properties['route_id']?.toString() != shortRoute) continue;
      final geometry = feature['geometry'] as Map;
      final raw = geometry['coordinates'];
      if (raw is! List) continue;
      final lines = geometry['type'] == 'MultiLineString'
          ? raw.whereType<List>()
          : [raw];
      final shapes = <List<List<double>>>[];
      for (final line in lines) {
        final shape = line
            .whereType<List>()
            .where((point) => point.length >= 2)
            .map(
              (point) => [
                (point[0] as num).toDouble(),
                (point[1] as num).toDouble(),
              ],
            )
            .toList();
        if (shape.length >= 2) shapes.add(shape);
      }
      if (shapes.isEmpty) continue;
      final from = _placeCoordinates(fromStop, stops);
      final to = _placeCoordinates(toStop, stops);
      List<List<double>>? shape;
      var bestScore = double.infinity;
      for (final candidate in shapes) {
        final forwardScore =
            _distance(
              candidate.first[1],
              candidate.first[0],
              from[1],
              from[0],
            ) +
            _distance(candidate.last[1], candidate.last[0], to[1], to[0]);
        final reverseScore =
            _distance(candidate.first[1], candidate.first[0], to[1], to[0]) +
            _distance(candidate.last[1], candidate.last[0], from[1], from[0]);
        final score = math.min(forwardScore, reverseScore);
        if (score < bestScore) {
          bestScore = score;
          shape = candidate;
        }
      }
      if (shape == null) continue;
      var fromIndex = _nearestShapeIndex(shape, from);
      var toIndex = _nearestShapeIndex(shape, to);
      if (fromIndex == toIndex) return fallback;
      if (fromIndex > toIndex) {
        final swap = fromIndex;
        fromIndex = toIndex;
        toIndex = swap;
      }
      var clipped = shape.sublist(fromIndex, toIndex + 1);
      if (_distance(clipped.first[1], clipped.first[0], from[1], from[0]) >
          _distance(clipped.last[1], clipped.last[0], from[1], from[0])) {
        clipped = clipped.reversed.toList();
      }
      final fromError = _distance(
        clipped.first[1],
        clipped.first[0],
        from[1],
        from[0],
      );
      final toError = _distance(clipped.last[1], clipped.last[0], to[1], to[0]);
      final clippedDistance = _geometryDistance(clipped);
      final stopDistance = _distance(from[1], from[0], to[1], to[0]);
      if (fromError > 350 ||
          toError > 350 ||
          clippedDistance > math.max(12000, stopDistance * 12)) {
        continue;
      }
      return clipped;
    }

    return fallback;
  }

  double _geometryDistance(List<List<double>> coordinates) {
    var distance = 0.0;
    for (var index = 1; index < coordinates.length; index++) {
      distance += _distance(
        coordinates[index - 1][1],
        coordinates[index - 1][0],
        coordinates[index][1],
        coordinates[index][0],
      );
    }
    return distance;
  }

  int _nearestShapeIndex(List<List<double>> shape, List<double> point) {
    var bestIndex = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < shape.length; i++) {
      final distance = _distance(shape[i][1], shape[i][0], point[1], point[0]);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  double _legDistanceMeters(Map<String, dynamic> leg) {
    final geometry = leg['legGeometry'];
    if (geometry is Map && geometry['coordinates'] is List) {
      final coordinates = (geometry['coordinates'] as List)
          .whereType<List>()
          .where((point) => point.length >= 2)
          .map(
            (point) => [
              (point[0] as num).toDouble(),
              (point[1] as num).toDouble(),
            ],
          )
          .toList();
      var distance = 0.0;
      for (var i = 1; i < coordinates.length; i++) {
        distance += _distance(
          coordinates[i - 1][1],
          coordinates[i - 1][0],
          coordinates[i][1],
          coordinates[i][0],
        );
      }
      return distance;
    }
    final from = leg['from'];
    final to = leg['to'];
    if (from is Map &&
        to is Map &&
        from['lat'] is num &&
        from['lon'] is num &&
        to['lat'] is num &&
        to['lon'] is num) {
      return _distance(
        (from['lat'] as num).toDouble(),
        (from['lon'] as num).toDouble(),
        (to['lat'] as num).toDouble(),
        (to['lon'] as num).toDouble(),
      );
    }
    return 0;
  }

  Map<String, dynamic> _walkLeg(
    DateTime base,
    int start,
    int end,
    double? fromLat,
    double? fromLon,
    String toStop,
    Map<String, dynamic> stops,
    bool transfer, {
    String? fromStop,
    double? toLat,
    double? toLon,
    List<List<double>>? geometry,
    bool isDirectPedestrian = false,
  }) => {
    'mode': 'WALK',
    'startTime': _iso(base, start),
    'endTime': _iso(base, end),
    'isTransferWalk': transfer,
    if (isDirectPedestrian) 'isDirectPedestrian': true,
    'from': fromStop != null
        ? _place(fromStop, stops)
        : {'name': 'Start', 'lat': fromLat, 'lon': fromLon},
    'to': toLat != null
        ? {'name': 'Destination', 'lat': toLat, 'lon': toLon}
        : _place(toStop, stops),
    if (geometry != null && geometry.length >= 2)
      'legGeometry': {'type': 'LineString', 'coordinates': geometry},
  };

  List<String> _shortestTransferPath(
    String sourceId,
    String targetId,
    Map<String, dynamic> data,
  ) {
    if (sourceId == targetId) return [sourceId];
    final transfers = Map<String, dynamic>.from(
      data['transfers'] as Map? ?? const {},
    );
    final stops = Map<String, dynamic>.from(data['stops'] as Map);
    final distances = <String, int>{sourceId: 0};
    final previous = <String, String>{};
    final pending = <String>{sourceId};
    while (pending.isNotEmpty) {
      String? current;
      for (final id in pending) {
        if (current == null ||
            (distances[id] ?? 1 << 30) < (distances[current] ?? 1 << 30)) {
          current = id;
        }
      }
      if (current == null) break;
      pending.remove(current);
      if (current == targetId) break;
      final links = <dynamic>[
        if (transfers[current] is List) ...(transfers[current] as List),
        ..._nearbyRailTransfers(current, stops),
      ];
      for (final link in links) {
        if (link is! List || link.length < 2) continue;
        final next = link[0].toString();
        final weight = (link[1] as num?)?.toInt() ?? 60;
        final candidate = (distances[current] ?? 0) + weight;
        if (candidate < (distances[next] ?? 1 << 30)) {
          distances[next] = candidate;
          previous[next] = current;
          pending.add(next);
        }
      }
    }
    if (!distances.containsKey(targetId)) return [sourceId, targetId];
    final path = <String>[targetId];
    while (path.last != sourceId) {
      final parent = previous[path.last];
      if (parent == null) return [sourceId, targetId];
      path.add(parent);
    }
    return path.reversed.toList();
  }

  Map<String, dynamic> _place(String id, Map<String, dynamic> stops) {
    final stop = stops[id] as List?;
    return {
      'name': stop?[0] ?? 'Transit stop',
      'lat': stop?[1],
      'lon': stop?[2],
      'stopId': id,
    };
  }

  List<double> _placeCoordinates(String id, Map<String, dynamic> stops) {
    final stop = stops[id] as List?;
    return [
      (stop?[2] as num?)?.toDouble() ?? 0,
      (stop?[1] as num?)?.toDouble() ?? 0,
    ];
  }

  String _iso(DateTime base, int seconds) => DateTime(
    base.year,
    base.month,
    base.day,
  ).add(Duration(seconds: seconds)).toIso8601String();

  String _mode(int type) => switch (type) {
    0 => 'TRAM',
    1 => 'SUBWAY',
    2 => 'RAIL',
    _ => 'BUS',
  };

  static double distanceBetween(double aLat, double aLon, double bLat, double bLon) {
    final dLat = (bLat - aLat) * math.pi / 180,
        dLon = (bLon - aLon) * math.pi / 180;
    final x =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(aLat * math.pi / 180) *
            math.cos(bLat * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 12742000 * math.asin(math.sqrt(x));
  }

  double _distance(double aLat, double aLon, double bLat, double bLon) =>
      distanceBetween(aLat, aLon, bLat, bLon);
}

class _NearbyStop {
  const _NearbyStop(this.id, this.walkSeconds);
  final String id;
  final int walkSeconds;
}

class _Call {
  const _Call(this.stopId, this.arrival, this.departure);
  final String stopId;
  final int arrival;
  final int departure;
}

class _Trip {
  _Trip(
    this.id,
    this.routeId,
    this.serviceId,
    this.headsign,
    this.calls,
    this.frequencies,
  );
  factory _Trip.fromRaw(List raw) => _Trip(
    raw[0].toString(),
    raw[1].toString(),
    raw[2].toString(),
    raw[3].toString(),
    (raw[4] as List).map((e) {
      final v = e as List;
      return _Call(
        v[0].toString(),
        (v[1] as num).toInt(),
        (v[2] as num).toInt(),
      );
    }).toList(),
    (raw[5] as List)
        .whereType<List>()
        .map((v) => v.map((n) => (n as num).toInt()).toList())
        .toList(),
  );
  final String id, routeId, serviceId, headsign;
  final List<_Call> calls;
  final List<List<int>> frequencies;

  int? nextDeparture(int index, int ready) {
    final base = calls[index].departure;
    if (frequencies.isEmpty) return base >= ready ? base : null;
    final first = calls.first.departure;
    int? best;
    for (final f in frequencies) {
      final initial = f[0] + base - first;
      if (ready > f[1] + base - first) continue;
      final n = math.max(0, ((ready - initial + f[2] - 1) ~/ f[2]));
      final value = initial + n * f[2];
      if (value <= f[1] + base - first && (best == null || value < best)) {
        best = value;
      }
    }
    return best;
  }

  int arrivalAt(int index, int boarded, int boardIndex) =>
      calls[index].arrival + (boarded - calls[boardIndex].departure);
}

class _Ride {
  const _Ride({
    required this.trip,
    required this.fromIndex,
    required this.toIndex,
    required this.departure,
    required this.arrival,
  });
  final _Trip trip;
  final int fromIndex, toIndex, departure, arrival;
  String get fromStop => trip.calls[fromIndex].stopId;
  String get toStop => trip.calls[toIndex].stopId;
}

class _Label {
  const _Label({
    required this.arrival,
    required this.rides,
    required this.initialStop,
    required this.initialWalkSeconds,
  });
  final int arrival, initialWalkSeconds;
  final String initialStop;
  final List<_Ride> rides;
  _Label copyWith({int? arrival}) => _Label(
    arrival: arrival ?? this.arrival,
    rides: rides,
    initialStop: initialStop,
    initialWalkSeconds: initialWalkSeconds,
  );
}

class _Boarding {
  const _Boarding(this.index, this.departure, this.label);
  final int index, departure;
  final _Label label;
}
