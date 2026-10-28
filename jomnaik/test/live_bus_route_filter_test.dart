import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/offline_raptor_router.dart';

void main() {
  group('Live bus route filtering', () {
    final routes = <String, dynamic>{
      'rapid-kl-bus:S1040': ['104', 'Example bus', 3],
      'ktmb:KTM1': ['KTM', 'Example rail', 2],
    };
    final trips = <dynamic>[
      ['rapid-kl-bus:weekday_trip_1', 'rapid-kl-bus:S1040'],
    ];
    final now = DateTime.utc(2026, 10, 12, 6);

    Map<String, dynamic> vehicle({
      String feed = 'rapid-kl-bus',
      String? tripId = 'weekday_trip_1',
      String? routeId,
      int? timestamp,
      num lat = 3.1,
      num lon = 101.6,
    }) => {
      'feed': feed,
      'tripId': tripId,
      'routeId': routeId,
      'timestamp': timestamp ?? now.millisecondsSinceEpoch ~/ 1000,
      'lat': lat,
      'lon': lon,
    };

    test('maps fresh bus trip IDs onto their static route IDs', () {
      final result = OfflineRaptorRouter.liveBusRouteIdsFromVehicles(
        vehicles: [vehicle()],
        routes: routes,
        trips: trips,
        now: now,
      );

      expect(result, {'rapid-kl-bus:S1040'});
    });

    test('uses route ID when trip ID is unavailable', () {
      final result = OfflineRaptorRouter.liveBusRouteIdsFromVehicles(
        vehicles: [vehicle(tripId: null, routeId: 'S1040')],
        routes: routes,
        trips: trips,
        now: now,
      );

      expect(result, {'rapid-kl-bus:S1040'});
    });

    test('ignores stale positions, rail feeds, and invalid coordinates', () {
      final result = OfflineRaptorRouter.liveBusRouteIdsFromVehicles(
        vehicles: [
          vehicle(timestamp: now.millisecondsSinceEpoch ~/ 1000 - 121),
          vehicle(feed: 'ktmb', routeId: 'KTM1'),
          vehicle(tripId: null, routeId: 'KTM1'),
          vehicle(lat: 95),
        ],
        routes: routes,
        trips: trips,
        now: now,
      );

      expect(result, isEmpty);
    });
  });
}
