import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/offline_raptor_router.dart';
import 'package:jomride/screens/profile_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall methodCall) async => '.',
      );

  group('User Requirements Tests', () {
    test('KTMB trains and routes are active in offline raptor router', () async {
      final router = OfflineRaptorRouter();
      // Batu Caves (3.2378, 101.6812) to KL Sentral (3.1342, 101.6861)
      final result = await router.plan(
        fromLat: 3.2378,
        fromLon: 101.6812,
        toLat: 3.1342,
        toLon: 101.6861,
        fromStopId: '50600',
        toStopId: '19100',
        departure: DateTime(2026, 10, 13, 8, 0),
      );

      expect(result, isNotNull);
      final itineraries = (result!['itineraries'] as List)
          .cast<Map<String, dynamic>>();
      expect(itineraries, isNotEmpty);

      // Verify at least one itinerary uses the KTMB Seremban Line
      final usesKtmb = itineraries.any((it) {
        final legs = (it['legs'] as List).cast<Map<String, dynamic>>();
        return legs.any(
          (leg) =>
              leg['routeShortName'].toString().toLowerCase().contains(
                'seremban',
              ) ||
              leg['routeShortName'].toString().toLowerCase().contains('ktm') ||
              leg['routeShortName'].toString().toLowerCase().contains(
                'port klang',
              ),
        );
      });
      expect(
        usesKtmb,
        isTrue,
        reason:
            'Route from Batu Caves to KL Sentral must utilize KTMB rail service.',
      );
    });

    testWidgets(
      'Profile page provides feedback form button with Microsoft Form link',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProfilePage(
                isSupabaseConfigured: false,
                onStationLocationTrackingChanged: (_) {},
              ),
            ),
          ),
        );

        expect(find.text('Give feedback'), findsOneWidget);
      },
    );

    testWidgets('signed-in profile scrolls to the sign-out control', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SignedInProfile(
              user: User.fromJson({
                'id': 'test-user',
                'app_metadata': <String, dynamic>{},
                'user_metadata': <String, dynamic>{},
                'aud': 'authenticated',
                'created_at': '2026-10-15T00:00:00.000Z',
                'email': 'test@example.com',
              })!,
              onStationLocationTrackingChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Sign out'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(find.text('Sign out'), findsOneWidget);
    });
  });
}
