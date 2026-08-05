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
    final origin = _nearby(stops, fromLat, fromLon, preferred: fromStopId);
    final destination = _nearby(stops, toLat, toLon, preferred: toStopId);
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

    _Label? best;
    String? bestDestination;
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
        if (best == null || arrival < best.arrival) {
          best = label.copyWith(arrival: arrival);
          bestDestination = stop.id;
        }
      }
      labels
        ..clear()
        ..addAll(next);
    }
    if (best == null || bestDestination == null || best.rides.isEmpty) {
      return null;
    }
    return _toItinerary(
      data: data,
      departure: when,
      startSeconds: startSeconds,
      fromLat: fromLat,
      fromLon: fromLon,
      toLat: toLat,
      toLon: toLon,
      destinationStop: bestDestination,
      label: best,
    );
  }

  Future<Map<String, dynamic>> _load() async {
    if (_data != null) return _data!;
    final raw =
        await _store.readBundle() ?? await rootBundle.loadString(_asset);
    _data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    return _data!;
  }

  List<_NearbyStop> _nearby(
    Map<String, dynamic> stops,
    double lat,
    double lon, {
    String? preferred,
  }) {
    final choices = <_NearbyStop>[];
    if (preferred != null && stops.containsKey(preferred)) {
      final stop = stops[preferred] as List;
      choices.add(_NearbyStop(preferred, 0));
      // Retain the exact selected stop even if its GTFS pin is imprecise.
      if (stop.length >= 3) return choices;
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
      if (distance <= 800) {
        choices.add(
          _NearbyStop(entry.key, math.max(30, (distance / 1.25).round())),
        );
      }
    }
    choices.sort((a, b) => a.walkSeconds.compareTo(b.walkSeconds));
    return choices.take(12).toList();
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
    for (var pass = 0; pass < 2; pass++) {
      final updates = <String, _Label>{};
      for (final entry in labels.entries) {
        final links = transfers[entry.key];
        if (links is! List) continue;
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
          ),
        );
      }
      final route = routes[ride.trip.routeId] as List? ?? const [];
      legs.add({
        'mode': _mode(route.length > 2 ? route[2] as int : 3),
        'startTime': _iso(departure, ride.departure),
        'endTime': _iso(departure, ride.arrival),
        'routeShortName': route.isNotEmpty ? route[0].toString() : 'Service',
        'headsign': ride.trip.headsign,
        'from': _place(ride.fromStop, stops),
        'to': _place(ride.toStop, stops),
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
    if (finalWalk > 20) {
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
    }
    final transitModes = legs
        .where((leg) => leg['mode'] != 'WALK')
        .map((leg) => leg['mode'])
        .toSet();
    return {
      'itineraries': [
        {
          'duration': label.arrival - startSeconds,
          'routeCategory': transitModes.contains('BUS') ? 'bus' : 'rail',
          'fallbackMessage':
              'Offline timetable route — live delays, traffic, weather, and crowd reports are unavailable.',
          'legs': legs,
        },
      ],
      'offlineRouting': true,
    };
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
  };

  Map<String, dynamic> _place(String id, Map<String, dynamic> stops) {
    final stop = stops[id] as List?;
    return {
      'name': stop?[0] ?? 'Transit stop',
      'lat': stop?[1],
      'lon': stop?[2],
      'stopId': id,
    };
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
