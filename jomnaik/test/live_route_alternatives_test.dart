import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/utils/live_route_alternatives.dart';

void main() {
  final current = {
    'incidentRiskScore': 2.0,
    'duration': 1200,
    'legs': [
      {'mode': 'SUBWAY', 'routeShortName': 'KJL', 'from': {'stopId': 'A'}, 'to': {'stopId': 'B'}},
    ],
  };

  test('returns distinct, lower-risk options within the time allowance', () {
    final alternative = {
      'incidentRiskScore': 0.0,
      'duration': 1500,
      'legs': [
        {'mode': 'BUS', 'routeShortName': 'T776', 'from': {'stopId': 'A'}, 'to': {'stopId': 'B'}},
      ],
    };
    final sameRoute = {
      ...current,
      'incidentRiskScore': 0.0,
      'duration': 1300,
      'legs': [
        {'mode': 'WALK', 'to': {'name': 'Different start'}},
        {'mode': 'SUBWAY', 'routeShortName': 'KJL', 'from': {'stopId': 'A'}, 'to': {'stopId': 'B'}},
      ],
    };
    final tooSlow = {
      ...alternative,
      'duration': 1900,
      'legs': [
        {'mode': 'BUS', 'routeShortName': 'T776', 'from': {'stopId': 'A'}, 'to': {'stopId': 'C'}},
      ],
    };
    final stillRisky = {
      ...alternative,
      'incidentRiskScore': 2.0,
      'duration': 1100,
      'legs': [
        {'mode': 'TRAM', 'routeShortName': 'BRT', 'from': {'stopId': 'A'}, 'to': {'stopId': 'C'}},
      ],
    };

    expect(
      selectSaferRouteAlternatives(
        currentItinerary: current,
        candidates: [sameRoute, tooSlow, stillRisky, alternative],
        currentRemainingSeconds: 1200,
      ),
      [alternative],
    );
  });

  test('does not offer alternatives when the current route has no incidents', () {
    expect(
      selectSaferRouteAlternatives(
        currentItinerary: {...current, 'incidentRiskScore': 0},
        candidates: [
          {
            'incidentRiskScore': 0,
            'duration': 600,
            'legs': [
              {'mode': 'BUS', 'routeShortName': 'T776'},
            ],
          },
        ],
        currentRemainingSeconds: 1200,
      ),
      isEmpty,
    );
  });
}