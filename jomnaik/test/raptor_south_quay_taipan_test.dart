import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/models/itinerary.dart';
import 'package:jomride/offline_raptor_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall methodCall) async => '.',
      );

  test('South Quay to Taipan reproduces available route alternatives', () async {
    final router = OfflineRaptorRouter();
    for (final origin in [
      (name: 'BRT platform', id: 'rapid-kl-rail:BRT6'),
      (name: 'BRT bus stop', id: 'rapid-kl-bus:1005835'),
      (name: 'unresolved coordinate', id: null),
    ]) {
      for (final destination in [
        (name: 'Taipan LRT platform', id: 'rapid-kl-rail:KJ32'),
        (name: 'Taipan bus stop', id: 'rapid-kl-bus:1006590'),
      ]) {
        final result = await router.plan(
          fromLat: 3.0617,
          fromLon: 101.5969,
          fromStopId: origin.id,
          toLat: 3.04815,
          toLon: 101.590233,
          toStopId: destination.id,
          departure: DateTime(2026, 10, 14, 10),
        );

        expect(result, isNotNull, reason: 'Origin: ${origin.name}');
        final itineraries = (result!['itineraries'] as List)
            .cast<Map<String, dynamic>>();
        expect(itineraries, isNotEmpty, reason: 'Origin: ${origin.name}');
        final available = itineraries
            .where((itinerary) =>
                isItineraryMapAvailableAtDeparture(
                  itinerary,
                  DateTime(2026, 10, 14, 10),
                ))
            .toList();
        // ignore: avoid_print
        print(
          '${origin.name} -> ${destination.name}: '
          '${available.length}/${itineraries.length} available at 10:00',
        );
        for (final itinerary in itineraries) {
          final legs = (itinerary['legs'] as List)
              .cast<Map<String, dynamic>>();
          // ignore: avoid_print
          print(
            '${origin.name} -> ${destination.name}: ${legs.map((leg) => '${leg['mode']}:${leg['routeShortName']} '
                '(${(leg['from'] as Map?)?['name']} -> '
                '${(leg['to'] as Map?)?['name']})').join(' | ')}',
          );
        }
        if (origin.id == null &&
            destination.id == 'rapid-kl-rail:KJ32') {
          bool hasRoute(
            Map<String, dynamic> itinerary,
            bool Function(Map<String, dynamic>) predicate,
          ) =>
              (itinerary['legs'] as List)
                  .whereType<Map<String, dynamic>>()
                  .any(predicate);

          expect(
            available.any(
              (itinerary) =>
                  hasRoute(
                    itinerary,
                    (leg) =>
                        leg['mode'] == 'TRAM' &&
                        leg['routeShortName'] == 'BRT',
                  ) &&
                  hasRoute(
                    itinerary,
                    (leg) =>
                        leg['mode'] == 'SUBWAY' &&
                        leg['routeShortName'] == 'KJL',
                  ),
            ),
            isTrue,
          );
          expect(
            available.any(
              (itinerary) =>
                  hasRoute(
                    itinerary,
                    (leg) =>
                        leg['mode'] == 'BUS' &&
                        leg['routeShortName'] == '770',
                  ) &&
                  !hasRoute(itinerary, (leg) => leg['mode'] == 'TRAM'),
            ),
            isTrue,
            reason: 'Route 770 is an alternative, not a continuation after BRT.',
          );
          expect(
            available.any(
              (itinerary) =>
                  hasRoute(itinerary, (leg) => leg['mode'] == 'TRAM') &&
                  hasRoute(
                    itinerary,
                    (leg) =>
                        leg['mode'] == 'BUS' &&
                        leg['routeShortName'] == '770',
                  ),
            ),
            isFalse,
            reason: 'Do not route from South Quay BRT backward via bus 770.',
          );
        }
      }
    }
  });
}