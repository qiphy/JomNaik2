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

  test('SAL transfers to KJL at Glenmarie and continues to Subang Jaya', () async {
    final result = await OfflineRaptorRouter().plan(
      fromLat: 3.082222,
      fromLon: 101.561944,
      fromStopId: 'rapid-kl-rail:SA9',
      toLat: 3.08466,
      toLon: 101.588127,
      toStopId: 'rapid-kl-rail:KJ28',
      departure: DateTime(2026, 10, 12, 6, 40),
    );

    expect(result, isNotNull);
    final itineraries = (result!['itineraries'] as List)
        .cast<Map<String, dynamic>>();
    expect(itineraries, isNotEmpty);

    expect(
      itineraries.any((itinerary) {
        final legs = (itinerary['legs'] as List).cast<Map<String, dynamic>>();
        final salIndex = legs.indexWhere(
          (leg) =>
            leg['routeShortName']?.toString().toUpperCase() == 'SAL' &&
            (leg['from'] as Map?)?['stopId'] == 'rapid-kl-rail:SA9' &&
            (leg['to'] as Map?)?['stopId'] == 'rapid-kl-rail:SA7',
        );
        if (salIndex < 0 || salIndex + 2 >= legs.length) return false;
        final transfer = legs[salIndex + 1];
        final kjl = legs[salIndex + 2];
        return transfer['mode'] == 'WALK' &&
            transfer['isTransferWalk'] == true &&
          (transfer['from'] as Map?)?['stopId'] == 'rapid-kl-rail:SA7' &&
          (transfer['to'] as Map?)?['stopId'] == 'rapid-kl-rail:KJ27' &&
          kjl['routeShortName']?.toString().toUpperCase() == 'KJL' &&
          (kjl['to'] as Map?)?['stopId'] == 'rapid-kl-rail:KJ28';
      }),
      isTrue,
      reason: 'SAL and KJL should connect through the Glenmarie interchange.',
    );
  });
}