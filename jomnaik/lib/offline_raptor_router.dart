import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'offline_bundle_store.dart';

/// Static, on-device public-transit fallback. It deliberately has no live
/// vehicle, traffic, weather, or crowdsourcing inputs; callers must label its
/// results accordingly.
class OfflineRaptorRouter {
  static const _asset = 'assets/offline/raptor_klang_valley.json';
  static const _maximumTransitWaitSeconds = 10 * 60;
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
  }) async {
    final data = await _load();
    final trips = _trips ??= (data['trips'] as List)
        .whereType<List>()
        .map(_Trip.fromRaw)
        .toList(growable: false);
    final stops = Map<String, dynamic>.from(data['stops'] as Map);
    final when = departure ?? DateTime.now();
    final dayStart = DateTime(when.year, when.month, when.day);
    final startSeconds = when.difference(dayStart).inSeconds;
    // Include stops beyond walking distance so the client can replace a long
    // access walk with an e-hailing first mile.
    final origin = _nearby(
      stops,
      fromLat,
      fromLon,
      preferred: fromStopId,
      maxDistanceMeters: 3000,
    );
    // Consider later stops that are better aligned with the destination. The
    // final-mile builder decides whether the remaining distance is walkable or
    // should use e-hailing.
    final destination = _nearby(
      stops,
      toLat,
      toLon,
      preferred: toStopId,
      maxDistanceMeters: 3000,
    );
    if (origin.isEmpty || destination.isEmpty) {
      return null;
    }

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
      for (final trip in trips) {
        if (!_serviceActive(trip.serviceId, when, data)) continue;
        _scanTrip(trip, labels, next);
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
          candidate.label.arrival < existing.label.arrival) {
        uniqueCandidates[signature] = candidate;
      }
    }
    final transitCandidates = uniqueCandidates.values.toList()
      ..sort(
        (left, right) => left.label.arrival.compareTo(right.label.arrival),
      );
    if (transitCandidates.isEmpty) {
      return null;
    }
    final itineraries = <Map<String, dynamic>>[];
    // Keep several genuinely different route patterns. The client ranks them
    // by walking burden, then transfers and duration, instead of presenting
    // only one low-transfer route and one multi-transfer route.
    for (final candidate in transitCandidates.take(8)) {
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
      );
      itineraries.addAll(
        (route['itineraries'] as List).whereType<Map<String, dynamic>>(),
      );
    }
    itineraries.sort((left, right) {
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
    return {
      'itineraries': itineraries.take(6).toList(),
      'offlineRouting': true,
    };
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
  }) {
    final choices = <_NearbyStop>[];
    final preferredId = _resolveStopId(preferred, stops);
    if (preferredId != null) {
      final stop = stops[preferredId] as List;
      final stopLat = (stop[1] as num).toDouble();
      final stopLon = (stop[2] as num).toDouble();
      choices.add(
        _NearbyStop(preferredId, _distance(lat, lon, stopLat, stopLon).round()),
      );
      // A tapped transit stop is an explicit destination/origin. Do not
      // replace it with a nearby earlier station simply because another stop
      // has a marginally better coordinate.
      return choices;
    }

    for (final entry in stops.entries) {
      final stop = entry.value;
      if (stop is! List || stop.length < 3) continue;
      final distance = _distance(
        lat,
        lon,
        (stop[1] as num).toDouble(),
        (stop[2] as num).toDouble(),
      );
      if (distance <= maxDistanceMeters) {
        choices.add(
          _NearbyStop(entry.key, math.max(30, (distance / 1.25).round())),
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
  ) {
    _Boarding? boarding;
    for (var index = 0; index < trip.calls.length; index++) {
      final call = trip.calls[index];
      final label = previous[call.stopId];
      if (label != null) {
        final departure = trip.nextDeparture(index, label.arrival);
        if (departure != null &&
            departure - label.arrival <= _maximumTransitWaitSeconds &&
            (boarding == null || departure < boarding.departure)) {
          boarding = _Boarding(index, departure, label);
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

  List<List<Object>> _nearbyRailTransfers(
    String sourceId,
    Map<String, dynamic> stops,
  ) {
    if (!sourceId.startsWith('rapid-kl-rail:')) return const [];
    final source = stops[sourceId];
    if (source is! List || source.length < 3) return const [];
    final sourceLat = (source[1] as num?)?.toDouble();
    final sourceLon = (source[2] as num?)?.toDouble();
    if (sourceLat == null || sourceLon == null) return const [];
    final links = <List<Object>>[];
    for (final entry in stops.entries) {
      if (entry.key == sourceId || !entry.key.startsWith('rapid-kl-rail:')) {
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
      if (distance <= 300) {
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
    return ymd.compareTo(calendar[7].toString()) >= 0 &&
        ymd.compareTo(calendar[8].toString()) <= 0 &&
        calendar[date.weekday - 1] == true;
  }

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
  }) {
    final stops = Map<String, dynamic>.from(data['stops'] as Map);
    final routes = Map<String, dynamic>.from(data['routes'] as Map);
    final legs = <Map<String, dynamic>>[];
    if (label.initialWalkSeconds > 0) {
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
      legs.add({
        'mode': mode,
        'startTime': _iso(departure, ride.departure),
        'endTime': _iso(departure, ride.arrival),
        'routeShortName': route.isNotEmpty ? route[0].toString() : 'Service',
        'headsign': ride.trip.headsign,
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
      (stops[last] as List)[1],
      (stops[last] as List)[2],
      toLat,
      toLon,
    );
    if (finalWalk <= 1000 && finalWalk > 20) {
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
        ),
      );
    } else if (finalWalk > 1000) {
      // Keep the public-transport itinerary complete with a walking final
      // mile. _lastMileEhailingAlternatives converts this leg into an
      // optional e-hailing alternative; it must not be the only option.
      final walkSeconds = math.max(60, (finalWalk / 1.35).round());
      legs.add({
        'mode': 'WALK',
        'startTime': _iso(departure, lastArrival),
        'endTime': _iso(departure, lastArrival + walkSeconds),
        'routeShortName': 'Walking',
        'from': _place(last, stops),
        'to': {'name': 'Destination', 'lat': toLat, 'lon': toLon},
      });
    }
    _mergeConsecutiveTransitLegs(legs);
    final transitModes = legs
        .where((leg) => leg['mode'] != 'WALK')
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
    final distanceMeters = legs.fold<double>(
      0,
      (total, leg) => total + _legDistanceMeters(leg),
    );
    return {
      'itineraries': [
        {
          'duration': legs.isEmpty
              ? label.arrival - startSeconds
              : (DateTime.parse(legs.last['endTime'] as String)
                    .difference(
                      DateTime.parse(legs.first['startTime'] as String),
                    )
                    .inSeconds),
          'routeCategory': transitModes.contains('BUS') ? 'bus' : 'rail',
          'transferCount': math.max(0, transitRouteIds.length - 1),
          'walkingSeconds': walkingSeconds,
          'distanceMeters': distanceMeters,
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
              150) {
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
        if (previousTo is Map) previousTo,
        if (currentStops is List) ...currentStops,
      ];
      previous['endTime'] = current['endTime'];
      previous['to'] = current['to'];
      legs.removeAt(index);
    }
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
  }) => {
    'mode': 'WALK',
    'startTime': _iso(base, start),
    'endTime': _iso(base, end),
    'isTransferWalk': transfer,
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
  double _distance(double aLat, double aLon, double bLat, double bLon) {
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
