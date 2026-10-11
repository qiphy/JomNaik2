import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/offline_raptor_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall methodCall) async {
      return '.';
    },
  );

  group('First-mile and Last-mile E-hailing Connectivity Tests', () {
    test('OfflineRaptorRouter converts final stretch > 1km to HAIL car route', () async {
      final router = OfflineRaptorRouter();
      
      // Persiaran KLCC to a location ~2.5km away from any station in Subang/Shah Alam
      // Coordinates: Sunway Medical Centre area or USJ residential area far from LRT
      // Let's test KLCC (3.15712, 101.71834) to a coordinate ~2km from a station:
      // (3.0673, 101.6035) -> Sunway Pyramid / Lagoon area where station is > 1.2km away
      final result = await router.plan(
        fromLat: 3.15712,
        fromLon: 101.71834,
        toLat: 3.0733,
        toLon: 101.6078,
        departure: DateTime(2026, 10, 12, 12, 0),
      );

      expect(result, isNotNull);
      final itineraries = (result!['itineraries'] as List).cast<Map<String, dynamic>>();
      expect(itineraries, isNotEmpty);

      for (final it in itineraries) {
        final legs = (it['legs'] as List).cast<Map<String, dynamic>>();
        expect(legs, isNotEmpty);

        // Check the final leg
        final lastLeg = legs.last;
        final lastMode = lastLeg['mode'];

        // If the last stretch was > 1km, it MUST be HAIL, never WALK
        if (lastMode == 'HAIL') {
          expect(lastLeg['routeShortName'], contains('E-hailing'));
          expect(lastLeg['isLastMile'], isTrue);
          expect(it['routeCategory'], equals('hybrid'));
          expect(it['hybridLastMile'], isTrue);
          expect(it['fareMin'], isNotNull);
          expect(it['fareMax'], isNotNull);
        } else if (lastMode == 'WALK') {
          // If WALK, distance must be <= 1000m
          final from = lastLeg['from'] as Map;
          final to = lastLeg['to'] as Map;
          final fromLat = (from['lat'] as num).toDouble();
          final fromLon = (from['lon'] as num).toDouble();
          final toLat = (to['lat'] as num).toDouble();
          final toLon = (to['lon'] as num).toDouble();

          final dist = OfflineRaptorRouter.distanceBetween(fromLat, fromLon, toLat, toLon);
          expect(dist, lessThanOrEqualTo(1000.0),
              reason: 'Final walk stretch must not exceed 1km');
        }
      }
    });

    test('First-mile stretch > 1km converts to HAIL car route', () async {
      final router = OfflineRaptorRouter();

      // Origin far from transit station (>1.5km), destination at KLCC Station
      final result = await router.plan(
        fromLat: 3.0733,
        fromLon: 101.6078,
        toLat: 3.158935,
        toLon: 101.713287,
        departure: DateTime(2026, 10, 12, 12, 0),
      );

      if (result != null) {
        final itineraries = (result['itineraries'] as List).cast<Map<String, dynamic>>();
        for (final it in itineraries) {
          final legs = (it['legs'] as List).cast<Map<String, dynamic>>();
          final firstLeg = legs.first;
          final firstMode = firstLeg['mode'];

          if (firstMode == 'HAIL') {
            expect(firstLeg['routeShortName'], contains('E-hailing'));
            expect(firstLeg['isFirstMile'], isTrue);
            expect(it['routeCategory'], equals('hybrid'));
            expect(it['hybridFirstMile'], isTrue);
          } else if (firstMode == 'WALK') {
            final from = firstLeg['from'] as Map;
            final to = firstLeg['to'] as Map;
            final fromLat = (from['lat'] as num).toDouble();
            final fromLon = (from['lon'] as num).toDouble();
            final toLat = (to['lat'] as num).toDouble();
            final toLon = (to['lon'] as num).toDouble();

            final dist = OfflineRaptorRouter.distanceBetween(fromLat, fromLon, toLat, toLon);
            expect(dist, lessThanOrEqualTo(1000.0),
                reason: 'First walk stretch must not exceed 1km');
          }
        }
      }
    });
  });
}
