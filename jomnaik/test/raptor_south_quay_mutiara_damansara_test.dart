import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/offline_raptor_router.dart';

bool hasLeg(Map<String, dynamic> itinerary, bool Function(Map) matches) {
  final rawLegs = itinerary['legs'];
  return rawLegs is List && rawLegs.whereType<Map>().any(matches);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall methodCall) async => '.',
      );

  test('South Quay to Mutiara Damansara itinerary comparison', () async {
    final router = OfflineRaptorRouter();
    for (final preference in ['standard', 'avoid_stairs', 'step_free']) {
      final result = await router.plan(
        fromLat: 3.0617,
        fromLon: 101.5969,
        toLat: 3.155301,
        toLon: 101.609077,
        toStopId: 'rapid-kl-rail:KG08',
        departure: DateTime(2026, 10, 15, 10),
        walkingPreference: preference,
      );

      expect(result, isNotNull, reason: preference);
      final itineraries = (result!['itineraries'] as List)
          .cast<Map<String, dynamic>>();
      expect(itineraries, isNotEmpty, reason: preference);
      expect(itineraries.first['routeCategory'], 'rail', reason: preference);
      expect(
        itineraries.any(
          (itinerary) => hasLeg(
            itinerary,
            (leg) => leg['routeShortName']?.toString().toUpperCase() == 'T807',
          ),
        ),
        isTrue,
        reason: 'Keep T807 available as an alternative for $preference.',
      );
    }
  });

  test('Route choices to Jalan USJ 10/1D from nearby origins', () async {
    final router = OfflineRaptorRouter();
    for (final origin in [
      (name: 'South Quay', lat: 3.0617, lon: 101.5969),
      (name: 'KLCC', lat: 3.158935, lon: 101.713287),
      (name: 'Mutiara Damansara', lat: 3.155301, lon: 101.609077),
    ]) {
      final result = await router.plan(
        fromLat: origin.lat,
        fromLon: origin.lon,
        toLat: 3.0486706,
        toLon: 101.5843640,
        departure: DateTime(2026, 10, 15, 10),
      );

      expect(result, isNotNull, reason: origin.name);
      final itineraries = (result!['itineraries'] as List)
          .cast<Map<String, dynamic>>();
      expect(itineraries, isNotEmpty, reason: origin.name);
      expect(
        itineraries.first['routeCategory'],
        'rail',
        reason: 'Prefer a rail-only option to a faster mixed bus itinerary.',
      );
      expect(
        hasLeg(itineraries.first, (leg) => leg['mode'] == 'BUS'),
        isFalse,
        reason:
            '${origin.name}: the recommended route should not include a bus.',
      );
      if (origin.name == 'KLCC') {
        expect(
          itineraries.any(
            (itinerary) =>
                hasLeg(
                  itinerary,
                  (leg) => leg['routeShortName']?.toString() == '770',
                ) &&
                hasLeg(
                  itinerary,
                  (leg) => leg['routeShortName']?.toString() == 'KJL',
                ),
          ),
          isTrue,
          reason: 'Retain the faster KJL-plus-770 itinerary as an alternative.',
        );
      }
    }
  });
}
