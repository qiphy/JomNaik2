import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/models/itinerary.dart';
import 'package:jomride/models/transit.dart';
import 'package:jomride/offline_raptor_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall methodCall) async => '.',
      );

  group('Bus Transit Routing & Anti-Backtracking Tests', () {
    test('Router does not route user to a far away station in the opposite direction and back', () async {
      final router = OfflineRaptorRouter();

      // Test routing where candidate transit lines run through nearby and distant stops
      // Origin: Near South Quay (3.0617, 101.5969)
      // Destination: Towards USJ 7 / SS 18 (3.0720, 101.5880)
      final result = await router.plan(
        fromLat: 3.0617,
        fromLon: 101.5969,
        toLat: 3.0720,
        toLon: 101.5880,
        departure: DateTime(2026, 10, 12, 14, 0),
      );

      expect(result, isNotNull);
      final itineraries = (result!['itineraries'] as List).cast<Map<String, dynamic>>();
      expect(itineraries, isNotEmpty);

      for (final it in itineraries) {
        final legs = (it['legs'] as List).cast<Map<String, dynamic>>();
        // Ensure no itinerary starts with a far away e-hailing leg (>1000m) that backtracks
        if (legs.isNotEmpty && legs.first['mode'] == 'HAIL') {
          final firstLegTo = legs.first['to'] as Map;
          final stopLat = (firstLegTo['lat'] as num).toDouble();
          final stopLon = (firstLegTo['lon'] as num).toDouble();
          final directDist = OfflineRaptorRouter.distanceBetween(3.0617, 101.5969, 3.0720, 101.5880);
          final stopDistToDest = OfflineRaptorRouter.distanceBetween(stopLat, stopLon, 3.0720, 101.5880);
          
          expect(
            stopDistToDest,
            lessThanOrEqualTo(directDist + 500),
            reason: 'First leg must not hail the user to a far away station in the opposite direction of destination',
          );
        }
      }
    });

    test('RAPTOR excludes buses without a live GPS route', () async {
      final router = OfflineRaptorRouter();
      const fromLat = 3.0617;
      const fromLon = 101.5969;
      const toLat = 3.0720;
      const toLon = 101.5880;
      final departure = DateTime(2026, 10, 12, 14, 0);
      final withoutGpsConstraint = await router.plan(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        departure: departure,
      );
      final withoutGps = (withoutGpsConstraint?['itineraries'] as List? ?? [])
          .whereType<Map<String, dynamic>>();
      final busesWithoutConstraint = withoutGps
          .expand((itinerary) => itinerary['legs'] as List)
          .where((leg) => leg is Map && leg['mode'] == 'BUS');
      expect(busesWithoutConstraint, isNotEmpty);

      final filtered = await router.plan(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        departure: departure,
        liveBusRouteIds: const {},
      );
      final filteredItineraries = (filtered?['itineraries'] as List? ?? [])
          .whereType<Map<String, dynamic>>();
      expect(
        filteredItineraries
            .expand((itinerary) => itinerary['legs'] as List)
            .where((leg) => leg is Map && leg['mode'] == 'BUS'),
        isEmpty,
      );
    });

    test('Bus departures prioritize estimated arrival times first, falling back to scheduled times', () {
      final nowMs = DateTime(2026, 10, 12, 14, 0).millisecondsSinceEpoch;

      final sampleEstimated = StopDeparture(
        route: '770',
        time: '14:08',
        timestamp: nowMs + 8 * 60 * 1000,
        isEstimated: true,
        direction: 'To Pasar Seni',
      );

      final sampleScheduledSameRouteLater = StopDeparture(
        route: '770',
        time: '14:30',
        timestamp: nowMs + 30 * 60 * 1000,
        isEstimated: false,
        direction: 'To Pasar Seni',
      );

      final sampleScheduledOtherRoute = StopDeparture(
        route: '771',
        time: '14:15',
        timestamp: nowMs + 15 * 60 * 1000,
        isEstimated: false,
        direction: 'To Subang Mewah',
      );

      final departures = [
        sampleEstimated,
        sampleScheduledOtherRoute,
        sampleScheduledSameRouteLater,
      ]..sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // 1. Estimated arrival time comes first for the tracked service
      expect(departures.first.isEstimated, isTrue);
      expect(departures.first.route, equals('770'));
      expect(departures.first.time, equals('14:08'));

      // 2. Services without active tracking fall back to scheduled times and are NOT dropped
      final scheduledServices = departures.where((d) => !d.isEstimated).toList();
      expect(scheduledServices, isNotEmpty);
      expect(scheduledServices.any((d) => d.route == '771'), isTrue);
      expect(scheduledServices.any((d) => d.route == '770'), isTrue);
    });

    test('Itinerary bus leg displays live arrival when estimated, and scheduled time when not', () {
      final legWithLiveEstimate = ItineraryLeg(
        mode: 'BUS',
        startTime: '2026-10-12T14:15:00',
        endTime: '2026-10-12T14:40:00',
        routeShortName: '770',
        headsign: 'To Pasar Seni',
        liveBusEstimate: const LiveBusEstimate(
          timestamp: 1791879300000,
          trafficAdjusted: false,
        ),
      );

      final legWithScheduledOnly = ItineraryLeg(
        mode: 'BUS',
        startTime: '2026-10-12T14:20:00',
        endTime: '2026-10-12T14:45:00',
        routeShortName: '771',
        headsign: 'To Subang Mewah',
      );

      expect(legWithLiveEstimate.liveBusEstimate, isNotNull);
      expect(legWithLiveEstimate.liveBusEstimate!.minutesRemaining, isNotEmpty);

      // Falls back cleanly to scheduled timetable times
      expect(legWithScheduledOnly.liveBusEstimate, isNull);
      expect(legWithScheduledOnly.startTime, equals('2026-10-12T14:20:00'));
    });
  });
}
