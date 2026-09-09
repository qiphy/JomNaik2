class Itinerary {
  const Itinerary({
    required this.duration,
    required this.legs,
    this.fallbackMessage,
    this.fareAmount,
    this.fareLabel,
    this.congestion,
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
      congestion: json['congestion'] is Map
          ? Map<String, dynamic>.from(json['congestion'] as Map)
          : null,
    );
  }

  final num duration;
  final List<ItineraryLeg> legs;
  final String? fallbackMessage;
  final double? fareAmount;
  final String? fareLabel;
  final Map<String, dynamic>? congestion;
}

class ItineraryLeg {
  const ItineraryLeg({
    required this.mode,
    required this.startTime,
    required this.endTime,
    this.routeShortName,
    this.headsign,
    this.fromPlace,
    this.toPlace,
    this.isSheltered = false,
    this.isTransferWalk = false,
    this.isNearestStationAccess = false,
    this.paymentMethod,
    this.liveBusEstimate,
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
      fromPlace: ItineraryPlace.fromJsonOrNull(json['from']),
      toPlace: ItineraryPlace.fromJsonOrNull(json['to']),
      isSheltered: json['isSheltered'] == true,
      isTransferWalk: json['isTransferWalk'] == true,
      isNearestStationAccess: json['isNearestStationAccess'] == true,
      paymentMethod: json['paymentMethod']?.toString(),
      liveBusEstimate: LiveBusEstimate.fromJsonOrNull(json['liveBusEstimate']),
      intermediateStops: _intermediateStopsFromJson(json['intermediateStops']),
      incidentReports: _legIncidentsFromJson(json['incidentReports']),
    );
  }

  final String mode;
  final String startTime;
  final String endTime;
  final String? routeShortName;
  final String? headsign;
  final ItineraryPlace? fromPlace;
  final ItineraryPlace? toPlace;
  final bool isSheltered;
  final bool isTransferWalk;
  final bool isNearestStationAccess;
  final String? paymentMethod;
  final LiveBusEstimate? liveBusEstimate;
  final List<IntermediateStop> intermediateStops;
  final List<LegIncident> incidentReports;

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
  });

  factory LegIncident.fromJson(Map<String, dynamic> json) => LegIncident(
    stationName: json['stationName']?.toString() ?? 'Affected station',
    type: json['type']?.toString() ?? 'disruption',
    route: json['route']?.toString(),
  );

  final String stationName;
  final String type;
  final String? route;

  String get label => formatIncidentLabel(type, route);
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
    'busSafety' => '$bus safety or accessibility issue reported',
    _ => 'Service disruption reported',
  };
}