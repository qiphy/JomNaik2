import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:jomride/models/itinerary.dart';
import 'package:jomride/offline_raptor_router.dart';
import 'package:jomride/services/routing_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall methodCall) async {
          return '.';
        },
      );

  group('Departure Time Availability Checks', () {
    test(
      'isItineraryMapAvailableAtDeparture correctly filters operating transit vs closed transit',
      () {
        final nightSearch = DateTime(2026, 10, 12, 1, 0, 0); // 1:00 AM
        final daySearch = DateTime(2026, 10, 12, 10, 0, 0); // 10:00 AM

        // Scenario A: Transit doesn't start until 5:30 AM (4.5 hour wait)
        final earlyMorningTransit = {
          'routeCategory': 'transit',
          'duration': 1800,
          'legs': [
            {
              'mode': 'WALK',
              'startTime': DateTime(2026, 10, 12, 1, 0, 0).toIso8601String(),
              'endTime': DateTime(2026, 10, 12, 1, 10, 0).toIso8601String(),
            },
            {
              'mode': 'RAIL',
              'startTime': DateTime(2026, 10, 12, 5, 30, 0).toIso8601String(),
              'endTime': DateTime(2026, 10, 12, 6, 0, 0).toIso8601String(),
            },
          ],
        };

        // Excluded when searching at 1:00 AM
        expect(
          isItineraryMapAvailableAtDeparture(earlyMorningTransit, nightSearch),
          isFalse,
          reason:
              'Route requiring user to wait until 5:30 AM must be excluded at 1:00 AM',
        );

        // Scenario B: Daytime transit departing in 8 minutes
        final activeDayTransit = {
          'routeCategory': 'transit',
          'duration': 1800,
          'legs': [
            {
              'mode': 'WALK',
              'startTime': DateTime(2026, 10, 12, 10, 0, 0).toIso8601String(),
              'endTime': DateTime(2026, 10, 12, 10, 5, 0).toIso8601String(),
            },
            {
              'mode': 'SUBWAY',
              'startTime': DateTime(2026, 10, 12, 10, 8, 0).toIso8601String(),
              'endTime': DateTime(2026, 10, 12, 10, 30, 0).toIso8601String(),
            },
          ],
        };

        expect(
          isItineraryMapAvailableAtDeparture(activeDayTransit, daySearch),
          isTrue,
          reason: 'Transit departing within acceptable window must be included',
        );

        // Scenario C: Pure direct walking and pure e-hailing are available 24/7
        final directWalk = {
          'routeCategory': 'walking',
          'duration': 900,
          'legs': [
            {
              'mode': 'WALK',
              'startTime': nightSearch.toIso8601String(),
              'endTime': nightSearch
                  .add(const Duration(minutes: 15))
                  .toIso8601String(),
            },
          ],
        };

        final directEhail = {
          'routeCategory': 'ehailing',
          'duration': 600,
          'legs': [
            {
              'mode': 'HAIL',
              'startTime': nightSearch.toIso8601String(),
              'endTime': nightSearch
                  .add(const Duration(minutes: 10))
                  .toIso8601String(),
            },
          ],
        };

        expect(
          isItineraryMapAvailableAtDeparture(directWalk, nightSearch),
          isTrue,
        );
        expect(
          isItineraryMapAvailableAtDeparture(directEhail, nightSearch),
          isTrue,
        );

        // Scenario D: Transfer wait exceeding 60 minutes is excluded
        final longTransferTransit = {
          'routeCategory': 'transit',
          'duration': 7200,
          'legs': [
            {
              'mode': 'RAIL',
              'startTime': DateTime(2026, 10, 12, 10, 5, 0).toIso8601String(),
              'endTime': DateTime(2026, 10, 12, 10, 20, 0).toIso8601String(),
            },
            {
              'mode': 'BUS',
              'startTime': DateTime(
                2026,
                10,
                12,
                11,
                45,
                0,
              ).toIso8601String(), // 85 min wait
              'endTime': DateTime(2026, 10, 12, 12, 10, 0).toIso8601String(),
            },
          ],
        };

        expect(
          isItineraryMapAvailableAtDeparture(longTransferTransit, daySearch),
          isFalse,
          reason: 'Transfer wait > 60 minutes must be excluded',
        );
      },
    );

    test(
      'OfflineRaptorRouter returns null when searching at 1:00 AM (services closed)',
      () async {
        final router = OfflineRaptorRouter();

        // KLCC Station to Pasar Seni at 1:00 AM
        final nightDeparture = DateTime(2026, 10, 12, 1, 0, 0);
        final result = await router.plan(
          fromLat: 3.158935,
          fromLon: 101.713287,
          toLat: 3.1424,
          toLon: 101.6961,
          departure: nightDeparture,
        );

        expect(
          result,
          isNull,
          reason:
              'At 1:00 AM, all transit services are closed, so router must not return journeys starting hours later',
        );
      },
    );

    test(
      'OfflineRaptorRouter finds routes when searching at 10:00 AM (daytime operating hours)',
      () async {
        final router = OfflineRaptorRouter();

        // KLCC Station to Pasar Seni at 10:00 AM
        final dayDeparture = DateTime(2026, 10, 12, 10, 0, 0);
        final result = await router.plan(
          fromLat: 3.158935,
          fromLon: 101.713287,
          toLat: 3.1424,
          toLon: 101.6961,
          departure: dayDeparture,
        );

        expect(result, isNotNull);
        final itineraries = (result!['itineraries'] as List)
            .cast<Map<String, dynamic>>();
        expect(itineraries, isNotEmpty);

        // Verify that the first leg starts near the departure time
        final firstItinerary = itineraries.first;
        final legs = (firstItinerary['legs'] as List)
            .cast<Map<String, dynamic>>();
        final firstStartTime = DateTime.parse(
          legs.first['startTime'] as String,
        );
        final waitMinutes = firstStartTime.difference(dayDeparture).inMinutes;

        expect(waitMinutes, lessThanOrEqualTo(45));
      },
    );

    test(
      'RoutingService at 1:00 AM explains transit is closed and provides walking and e-hailing',
      () async {
        final router = OfflineRaptorRouter();
        final routingService = RoutingService(
          httpClient: http.Client(),
          backendBaseUrl: 'http://localhost:9999', // offline / unreachable mock
          offlineRouter: router,
        );

        String? userMessage;
        final nightDeparture = DateTime(2026, 10, 12, 1, 0, 0);

        final routeResult = await routingService.getRoute(
          fromLat: 3.158935,
          fromLon: 101.713287,
          toLat: 3.1650,
          toLon: 101.7200,
          departure: nightDeparture,
          onMessage: (msg) {
            userMessage = msg;
          },
        );

        expect(routeResult, isNotNull);
        expect(
          userMessage,
          contains(
            'Public transit is not operating at the requested departure time',
          ),
        );

        final itineraries = (routeResult!['itineraries'] as List)
            .cast<Map<String, dynamic>>();
        expect(itineraries, isNotEmpty);

        // Verify available modes
        final availableModes =
            routeResult['availableModes'] as Map<String, dynamic>;
        expect(availableModes['transit'], isFalse);
        expect(availableModes['walk'], isTrue);

        // Verify that returned options are immediately available at the requested departure time
        for (final it in itineraries) {
          final category = it['routeCategory'];
          expect(category != 'transit' && category != 'hybrid', isTrue);
          final legs = (it['legs'] as List).cast<Map<String, dynamic>>();
          final start = DateTime.parse(legs.first['startTime'] as String);
          expect(
            start.difference(nightDeparture).inMinutes.abs(),
            lessThanOrEqualTo(5),
          );
        }
      },
    );
  });
}
