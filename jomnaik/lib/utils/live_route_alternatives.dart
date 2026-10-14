List<Map<String, dynamic>> selectSaferRouteAlternatives({
  required Map<String, dynamic> currentItinerary,
  required Iterable<Map<String, dynamic>> candidates,
  required int currentRemainingSeconds,
  int maximumExtraSeconds = 600,
  int limit = 4,
}) {
  final currentRisk =
      (currentItinerary['incidentRiskScore'] as num?)?.toDouble() ?? 0;
  if (currentRisk <= 0 || limit <= 0) return const [];

  final currentSignature = _itinerarySignature(currentItinerary);
  final maximumDuration = currentRemainingSeconds + maximumExtraSeconds;
  final alternatives = candidates.where((candidate) {
    final risk = (candidate['incidentRiskScore'] as num?)?.toDouble() ?? 0;
    final duration = (candidate['duration'] as num?)?.toInt();
    return risk < currentRisk &&
        _itinerarySignature(candidate) != currentSignature &&
        duration != null &&
        duration <= maximumDuration;
  }).toList();

  alternatives.sort((left, right) {
    final leftRisk = (left['incidentRiskScore'] as num?)?.toDouble() ?? 0;
    final rightRisk = (right['incidentRiskScore'] as num?)?.toDouble() ?? 0;
    final riskOrder = leftRisk.compareTo(rightRisk);
    if (riskOrder != 0) return riskOrder;
    final leftDuration = (left['duration'] as num?)?.toInt() ?? 1 << 30;
    final rightDuration = (right['duration'] as num?)?.toInt() ?? 1 << 30;
    return leftDuration.compareTo(rightDuration);
  });

  return alternatives.take(limit).toList(growable: false);
}

String _itinerarySignature(Map<String, dynamic> itinerary) {
  final rawLegs = itinerary['legs'];
  if (rawLegs is! List) return '';
  final legs = rawLegs.whereType<Map>().toList();
  final transitLegs = legs.where((leg) {
    final mode = leg['mode']?.toString().toUpperCase();
    return mode != 'WALK' && mode != 'HAIL';
  }).toList();
  final signatureLegs = transitLegs.isNotEmpty ? transitLegs : legs;
  return signatureLegs.map((leg) {
    final mode = leg['mode']?.toString().toUpperCase() ?? '';
    final route = leg['routeShortName']?.toString() ?? '';
    final from = leg['from'];
    final to = leg['to'];
    final fromId = from is Map ? from['stopId'] ?? from['name'] : '';
    final toId = to is Map ? to['stopId'] ?? to['name'] : '';
    return '$mode:$route:$fromId->$toId';
  }).join('|');
}