class Itinerary {
  const Itinerary({
    required this.duration,
    required this.legs,
    this.fallbackMessage,
    this.fareAmount,
    this.fareLabel,
    this.fareMin,
    this.fareMax,
    this.congestion,
    this.incidentDelaySeconds = 0,
  });

  factory Itinerary.fromJson(Map<String, dynamic> json) {
    final rawLegs = json['legs'];
    final fallback = json['fallback'];
    final fare = json['fare'];
    return Itinerary(
      duration: json['duration'] is num ? json['duration'] as num : 0,
      legs: rawLegs is List
          ? rawLegs
                .whereType<Map>()
                .map(
                  (leg) =>
                      ItineraryLeg.fromJson(Map<String, dynamic>.from(leg)),
                )
                .toList()
          : const [],
      fallbackMessage:
          json['fallbackMessage']?.toString() ??
          (fallback is Map ? fallback['message']?.toString() : null),
      fareAmount: fare is Map && fare['amount'] is num
          ? (fare['amount'] as num).toDouble()
          : null,
      fareLabel: fare is Map ? fare['label']?.toString() : null,
      fareMin: json['fareMin'] is num
          ? (json['fareMin'] as num).toDouble()
          : null,
      fareMax: json['fareMax'] is num
          ? (json['fareMax'] as num).toDouble()
          : null,
      congestion: json['congestion'] is Map
          ? Map<String, dynamic>.from(json['congestion'] as Map)
          : null,
      incidentDelaySeconds:
          (json['incidentDelaySeconds'] as num?)?.toInt() ?? 0,
    );
  }

  final num duration;
  final List<ItineraryLeg> legs;
  final String? fallbackMessage;
  final double? fareAmount;
  final String? fareLabel;
  final double? fareMin;
  final double? fareMax;
  final Map<String, dynamic>? congestion;
  final int incidentDelaySeconds;

  bool get hasIncidents =>
      incidentDelaySeconds > 0 ||
      legs.any((leg) => leg.incidentReports.isNotEmpty);

  int get incidentReportsCount => legs.fold<int>(
        0,
        (sum, leg) => sum + leg.incidentReports.length,
      );
}

class ItineraryLeg {
  const ItineraryLeg({
    required this.mode,
    required this.startTime,
    required this.endTime,
    this.routeShortName,
    this.headsign,
    this.terminus,
    this.fromPlace,
    this.toPlace,
    this.isSheltered = false,
    this.isTransferWalk = false,
    this.isNearestStationAccess = false,
    this.paymentMethod,
    this.liveBusEstimate,
    this.distanceMeters,
    this.distanceToDestinationMeters,
    this.trafficLevel,
    this.trafficDelaySeconds,
    this.drivingDurationSeconds,
    this.intermediateStops = const [],
    this.incidentReports = const [],
  });

  factory ItineraryLeg.fromJson(Map<String, dynamic> json) {
    final from = json['from'];
    final to = json['to'];
    return ItineraryLeg(
      mode: json['mode']?.toString() ?? 'UNKNOWN',
      startTime: _legTime(
        json['startTime'],
        from is Map ? from['departure'] ?? from['scheduledDeparture'] : null,
      ),
      endTime: _legTime(
        json['endTime'],
        to is Map ? to['arrival'] ?? to['scheduledArrival'] : null,
      ),
      routeShortName: json['routeShortName']?.toString(),
      headsign: json['headsign']?.toString(),
      terminus: json['terminus']?.toString() ?? json['headsign']?.toString(),
      fromPlace: ItineraryPlace.fromJsonOrNull(json['from']),
      toPlace: ItineraryPlace.fromJsonOrNull(json['to']),
      isSheltered: json['isSheltered'] == true,
      isTransferWalk: json['isTransferWalk'] == true,
      isNearestStationAccess: json['isNearestStationAccess'] == true,
      paymentMethod: json['paymentMethod']?.toString(),
      liveBusEstimate: LiveBusEstimate.fromJsonOrNull(json['liveBusEstimate']),
      distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
      distanceToDestinationMeters: (json['distanceToDestinationMeters'] as num?)
          ?.toDouble(),
      trafficLevel: json['trafficLevel']?.toString(),
      trafficDelaySeconds: (json['trafficDelaySeconds'] as num?)?.toInt(),
      drivingDurationSeconds: (json['drivingDuration'] as num?)?.toInt(),
      intermediateStops: _intermediateStopsFromJson(json['intermediateStops']),
      incidentReports: _legIncidentsFromJson(json['incidentReports']),
    );
  }

  final String mode;
  final String startTime;
  final String endTime;
  final String? routeShortName;
  final String? headsign;
  final String? terminus;
  final ItineraryPlace? fromPlace;
  final ItineraryPlace? toPlace;
  final bool isSheltered;
  final bool isTransferWalk;
  final bool isNearestStationAccess;
  final String? paymentMethod;
  final LiveBusEstimate? liveBusEstimate;
  final double? distanceMeters;
  final double? distanceToDestinationMeters;
  final String? trafficLevel;
  final int? trafficDelaySeconds;
  final int? drivingDurationSeconds;
  final List<IntermediateStop> intermediateStops;
  final List<LegIncident> incidentReports;

  String get terminalDirection {
    final sign = terminus?.trim().isNotEmpty == true
        ? terminus!.trim()
        : (headsign?.trim().isNotEmpty == true
            ? headsign!.trim()
            : toPlace?.name.trim() ?? '');
    if (sign.isEmpty) return 'Direction unavailable';

    final toMatches = RegExp(
      r'\bto\s+',
      caseSensitive: false,
    ).allMatches(sign).toList();
    if (toMatches.isNotEmpty) {
      final match = toMatches.last;
      final terminal = sign.substring(match.end).trim();
      if (terminal.isNotEmpty) return 'to $terminal';
    }

    for (final separator in ['→', '->']) {
      final separatorIndex = sign.lastIndexOf(separator);
      if (separatorIndex >= 0) {
        final terminal = sign
            .substring(separatorIndex + separator.length)
            .trim();
        if (terminal.isNotEmpty) return 'to $terminal';
      }
    }

    return 'to $sign';
  }

  static String _legTime(dynamic primary, dynamic fallback) {
    final value = primary ?? fallback;
    return value?.toString() ?? '';
  }
}

class LegIncident {
  const LegIncident({
    required this.stationName,
    required this.type,
    this.route,
    this.comment,
  });

  factory LegIncident.fromJson(Map<String, dynamic> json) => LegIncident(
    stationName: json['stationName']?.toString() ?? 'Affected station',
    type: json['type']?.toString() ?? 'disruption',
    route: json['route']?.toString(),
    comment: json['comment']?.toString(),
  );

  final String stationName;
  final String type;
  final String? route;
  final String? comment;

  String get label {
    final base = formatIncidentLabel(type, route);
    if (comment != null && comment!.trim().isNotEmpty) {
      return '$base • "${comment!.trim()}"';
    }
    return base;
  }
}

class LiveBusEstimate {
  const LiveBusEstimate({
    required this.timestamp,
    required this.trafficAdjusted,
  });

  static LiveBusEstimate? fromJsonOrNull(dynamic value) {
    if (value is! Map || value['timestamp'] is! num) return null;
    return LiveBusEstimate(
      timestamp: (value['timestamp'] as num).toInt(),
      trafficAdjusted: value['trafficAdjusted'] == true,
    );
  }

  String get minutesRemaining {
    final seconds = (DateTime.fromMillisecondsSinceEpoch(
      timestamp,
    ).difference(DateTime.now()).inSeconds).clamp(0, 7200);
    if (seconds < 60) return 'due now';
    return 'in ${(seconds / 60).ceil()} min';
  }

  final int timestamp;
  final bool trafficAdjusted;
}

class ItineraryPlace {
  const ItineraryPlace({required this.name, this.lat, this.lon});

  static ItineraryPlace? fromJsonOrNull(dynamic value) {
    if (value is! Map || value['name'] == null) return null;
    return ItineraryPlace(
      name: value['name'].toString(),
      lat: value['lat'] is num ? (value['lat'] as num).toDouble() : null,
      lon: value['lon'] is num ? (value['lon'] as num).toDouble() : null,
    );
  }

  final String name;
  final double? lat;
  final double? lon;
}

class IntermediateStop {
  const IntermediateStop({
    required this.name,
    required this.lat,
    required this.lon,
  });

  factory IntermediateStop.fromJson(Map<String, dynamic> json) {
    return IntermediateStop(
      name: json['name']?.toString() ?? 'Unnamed stop',
      lat: json['lat'] is num ? (json['lat'] as num).toDouble() : 0,
      lon: json['lon'] is num ? (json['lon'] as num).toDouble() : 0,
    );
  }

  final String name;
  final double lat;
  final double lon;
}

List<IntermediateStop> _intermediateStopsFromJson(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((stop) => IntermediateStop.fromJson(Map<String, dynamic>.from(stop)))
      .toList();
}

List<LegIncident> _legIncidentsFromJson(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map(
        (incident) => LegIncident.fromJson(Map<String, dynamic>.from(incident)),
      )
      .toList();
}

/// Formats standard GTFS incident types into human-readable labels.
String formatIncidentLabel(String type, String? route) {
  final bus = route == null || route.trim().isEmpty ? 'Bus' : 'Bus $route';
  return switch (type) {
    'stuckTrain' => 'Train has been stationary for over 5 minutes',
    'missingBus' => 'Bus or BRT has not arrived for over 10 minutes',
    'crowding' => 'Crowding reported',
    'safety' => 'Safety or accessibility issue reported',
    'busNotArrived' => '$bus has not arrived for over 10 minutes',
    'busCrowding' => '$bus crowding reported',
    'busBreakdown' => '$bus breakdown or service issue reported',
    'busReroute' => '$bus rerouted or detour reported',
    'busSafety' => '$bus safety or accessibility issue reported',
    _ => 'Service disruption reported',
  };
}

/// Checks whether an itinerary can actually be taken at the requested departure time,
/// ensuring transit services are actively operating without requiring long platform or
/// overnight transfer waits.
bool isItineraryMapAvailableAtDeparture(
  Map<String, dynamic> itinerary,
  DateTime requestedDeparture, {
  Duration maxPlatformWait = const Duration(minutes: 45),
  Duration maxTransferWait = const Duration(minutes: 60),
}) {
  final category = itinerary['routeCategory']?.toString().toLowerCase();
  // Pure direct walking and pure direct e-hailing are always available immediately
  if (category == 'walking' || category == 'walk' || category == 'ehailing') {
    return true;
  }

  final rawLegs = itinerary['legs'];
  if (rawLegs is! List || rawLegs.isEmpty) return false;

  final legs = rawLegs
      .whereType<Map>()
      .map((l) => Map<String, dynamic>.from(l))
      .toList();

  final transitLegs = <Map<String, dynamic>>[];
  for (final leg in legs) {
    final mode = leg['mode']?.toString().toUpperCase();
    if (mode != null && mode != 'WALK' && mode != 'HAIL') {
      transitLegs.add(leg);
    }
  }

  // If there are no transit legs (e.g. direct walk or hail), it can be taken immediately
  if (transitLegs.isEmpty) {
    return true;
  }

  // 1. Check the first leg of the whole journey:
  // Can it begin at the requested departure time?
  final firstLeg = legs.first;
  final firstLegStartStr = firstLeg['startTime']?.toString();
  if (firstLegStartStr != null) {
    final firstLegStart = DateTime.tryParse(firstLegStartStr);
    if (firstLegStart != null) {
      // If the first leg starts more than 45 minutes after requested time,
      // it cannot be taken at the requested departure time.
      if (firstLegStart.difference(requestedDeparture).inMinutes > 45) {
        return false;
      }
      // If the first leg departure is in the past by more than 5 minutes:
      if (requestedDeparture.difference(firstLegStart).inMinutes > 5) {
        return false;
      }
    }
  }

  // 2. Check the first transit leg:
  // How long does the user wait at the platform before the first transit vehicle arrives?
  final firstTransit = transitLegs.first;
  final firstTransitStartStr = firstTransit['startTime']?.toString();
  if (firstTransitStartStr == null) return false;
  final firstTransitStart = DateTime.tryParse(firstTransitStartStr);
  if (firstTransitStart == null) return false;

  DateTime userArrivalAtTransitStop = requestedDeparture;
  final firstTransitIndex = legs.indexOf(firstTransit);
  if (firstTransitIndex > 0) {
    final priorLeg = legs[firstTransitIndex - 1];
    final priorEndStr = priorLeg['endTime']?.toString();
    if (priorEndStr != null) {
      userArrivalAtTransitStop =
          DateTime.tryParse(priorEndStr) ?? requestedDeparture;
    }
  }

  final initialPlatformWait = firstTransitStart.difference(
    userArrivalAtTransitStop,
  );
  if (initialPlatformWait.inSeconds < -60 ||
      initialPlatformWait > maxPlatformWait) {
    return false;
  }

  // 3. Check transfers between subsequent transit legs
  for (var i = 1; i < transitLegs.length; i++) {
    final prevTransit = transitLegs[i - 1];
    final currTransit = transitLegs[i];
    final prevEndStr = prevTransit['endTime']?.toString();
    final currStartStr = currTransit['startTime']?.toString();
    if (prevEndStr != null && currStartStr != null) {
      final prevEnd = DateTime.tryParse(prevEndStr);
      final currStart = DateTime.tryParse(currStartStr);
      if (prevEnd != null && currStart != null) {
        final transferWait = currStart.difference(prevEnd);
        if (transferWait.inSeconds < -60 || transferWait > maxTransferWait) {
          return false;
        }
      }
    }
  }

  return true;
}

extension ItineraryAvailabilityExtension on Itinerary {
  bool isAvailableAtDeparture(
    DateTime requestedDeparture, {
    Duration maxPlatformWait = const Duration(minutes: 45),
    Duration maxTransferWait = const Duration(minutes: 60),
  }) {
    final transitLegs = legs
        .where((l) => l.mode != 'WALK' && l.mode != 'HAIL')
        .toList();

    if (transitLegs.isEmpty) return true;

    final firstLegStart = DateTime.tryParse(legs.first.startTime);
    if (firstLegStart != null) {
      if (firstLegStart.difference(requestedDeparture).inMinutes > 45) {
        return false;
      }
      if (requestedDeparture.difference(firstLegStart).inMinutes > 5) {
        return false;
      }
    }

    final firstTransit = transitLegs.first;
    final firstTransitStart = DateTime.tryParse(firstTransit.startTime);
    if (firstTransitStart == null) return false;

    DateTime userArrivalAtTransitStop = requestedDeparture;
    final firstTransitIndex = legs.indexOf(firstTransit);
    if (firstTransitIndex > 0) {
      userArrivalAtTransitStop =
          DateTime.tryParse(legs[firstTransitIndex - 1].endTime) ??
          requestedDeparture;
    }

    final initialPlatformWait = firstTransitStart.difference(
      userArrivalAtTransitStop,
    );
    if (initialPlatformWait.inSeconds < -60 ||
        initialPlatformWait > maxPlatformWait) {
      return false;
    }

    for (var i = 1; i < transitLegs.length; i++) {
      final prevEnd = DateTime.tryParse(transitLegs[i - 1].endTime);
      final currStart = DateTime.tryParse(transitLegs[i].startTime);
      if (prevEnd != null && currStart != null) {
        final transferWait = currStart.difference(prevEnd);
        if (transferWait.inSeconds < -60 || transferWait > maxTransferWait) {
          return false;
        }
      }
    }

    return true;
  }
}
