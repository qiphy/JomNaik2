import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/offline_raptor_router.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall methodCall) async => '.',
      );

  test('Sunway University to KLCC includes the BRT Sunway Line', () async {
    final result = await OfflineRaptorRouter().plan(
      fromLat: 3.06728,
      fromLon: 101.60386,
      toLat: 3.158935,
      toLon: 101.713287,
      departure: DateTime(2026, 10, 12, 12),
    );

    expect(result, isNotNull);
    final itineraries = result!['itineraries'] as List;
    for (final itinerary in itineraries) {
      final legs = (itinerary as Map<String, dynamic>)['legs'] as List;
      // Keep itinerary diagnostics visible in the test output.
      // ignore: avoid_print
      print(
        legs
            .whereType<Map>()
            .map((leg) {
              final from = (leg['from'] as Map?)?['name'] ?? 'Start';
              final to = (leg['to'] as Map?)?['name'] ?? 'End';
              return '${leg['mode']}:${leg['routeShortName']} ($from → $to)';
            })
            .join(' | '),
      );
    }
    final includesBrt = itineraries.any((itinerary) {
      final legs = (itinerary as Map<String, dynamic>)['legs'] as List;
      return legs.whereType<Map>().any(
        (leg) =>
            leg['routeShortName']?.toString().toUpperCase().contains('BRT') ==
                true ||
            leg['routeShortName']?.toString().toUpperCase().contains(
                  'SUNWAY LINE',
                ) ==
                true,
      );
    });
    expect(includesBrt, isTrue);
  });
}
