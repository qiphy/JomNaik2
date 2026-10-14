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

  test('South Quay to Universiti can use BRT then KJL', () async {
    for (final originStopId in ['rapid-kl-rail:BRT6', 'rapid-kl-bus:1005835']) {
      final result = await OfflineRaptorRouter().plan(
        fromLat: 3.0617,
        fromLon: 101.5969,
        fromStopId: originStopId,
        toLat: 3.114616,
        toLon: 101.661639,
        toStopId: 'rapid-kl-rail:KJ19',
        departure: DateTime(2026, 10, 12, 12),
      );

      expect(result, isNotNull, reason: 'Origin ID: $originStopId');
      final itineraries = (result!['itineraries'] as List)
          .cast<Map<String, dynamic>>();
      expect(itineraries, isNotEmpty, reason: 'Origin ID: $originStopId');

      for (final itinerary in itineraries) {
        final legs = (itinerary['legs'] as List).cast<Map<String, dynamic>>();
        // ignore: avoid_print
        print(
          '$originStopId: ${legs.map((leg) => '${leg['mode']}:${leg['routeShortName']} '
              '(${(leg['from'] as Map?)?['name']} → '
              '${(leg['to'] as Map?)?['name']})').join(' | ')}',
        );
      }

      expect(
        itineraries.any((itinerary) {
          final legs = (itinerary['legs'] as List).whereType<Map>();
          final hasBrt = legs.any(
            (leg) =>
                leg['routeShortName']?.toString().toUpperCase().contains(
                      'BRT',
                    ) ==
                    true ||
                leg['routeShortName']?.toString().toUpperCase().contains(
                      'SUNWAY LINE',
                    ) ==
                    true,
          );
          final hasKjl = legs.any(
            (leg) => leg['routeShortName']?.toString().toUpperCase() == 'KJL',
          );
          return hasBrt && hasKjl;
        }),
        isTrue,
        reason: 'The scheduled route should connect through USJ 7.',
      );

      if (originStopId == 'rapid-kl-bus:1005835') {
        expect(
          itineraries.any((itinerary) {
            final legs = (itinerary['legs'] as List).whereType<Map>().toList();
            final sunwayIndex = legs.indexWhere(
              (leg) =>
                  leg['routeShortName']?.toString().toUpperCase() ==
                  'SUNWAY LINE',
            );
            if (sunwayIndex < 0 || sunwayIndex + 2 >= legs.length) {
              return false;
            }
            final transfer = legs[sunwayIndex + 1];
            final kjl = legs[sunwayIndex + 2];
            return transfer['mode'] == 'WALK' &&
                transfer['isTransferWalk'] == true &&
                (transfer['to'] as Map?)?['name'] == 'USJ 7' &&
                kjl['routeShortName']?.toString().toUpperCase() == 'KJL';
          }),
          isTrue,
          reason: 'Sunway Line should offer a direct transfer to KJL at USJ 7.',
        );
      }
    }
  });
}
