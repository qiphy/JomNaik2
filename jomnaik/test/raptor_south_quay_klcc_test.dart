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

  test('South Quay to KLCC routing includes BRT transit without forcing e-hailing', () async {
    const fromLat = 3.0617;
    const fromLon = 101.5969;
    const toLat = 3.1579;
    const toLon = 101.7116;
    final departure = DateTime(2026, 10, 12, 14, 0);

    final result = await OfflineRaptorRouter().plan(
      fromLat: fromLat,
      fromLon: fromLon,
      toLat: toLat,
      toLon: toLon,
      departure: departure,
    );

    expect(result, isNotNull);
    final itineraries = (result!['itineraries'] as List).cast<Map<String, dynamic>>();
    expect(itineraries, isNotEmpty);

    final hasBrt = itineraries.any((it) {
      final legs = (it['legs'] as List).cast<Map<String, dynamic>>();
      return legs.any(
        (leg) =>
            leg['routeShortName']?.toString().toUpperCase().contains('BRT') == true ||
            leg['routeShortName']?.toString().toUpperCase().contains('SUNWAY LINE') == true,
      );
    });
    expect(hasBrt, isTrue, reason: 'BRT journey connecting at USJ 7 should be present.');
  });

  test('Off-road South Quay keeps direct BRT access as an alternative', () async {
    // Exact off-road coordinates from user screenshot (inside Sunway GEO / South Quay parcel)
    const fromLat = 3.061938;
    const fromLon = 101.595626;
    const toLat = 3.072; // SS 18
    const toLon = 101.588;
    final departure = DateTime(2026, 10, 12, 14, 0);

    final result = await OfflineRaptorRouter().plan(
      fromLat: fromLat,
      fromLon: fromLon,
      toLat: toLat,
      toLon: toLon,
      departure: departure,
    );

    expect(result, isNotNull);
    final itineraries = (result!['itineraries'] as List).cast<Map<String, dynamic>>();
    expect(itineraries, isNotEmpty);

    final brtItinerary = itineraries.firstWhere((itinerary) {
      final candidateLegs = (itinerary['legs'] as List)
          .cast<Map<String, dynamic>>();
      if (candidateLegs.length < 2 ||
          candidateLegs.first['isDirectPedestrian'] != true) {
        return false;
      }
      final route = candidateLegs[1]['routeShortName']
          .toString()
          .toUpperCase();
      return route.contains('BRT') || route.contains('SUNWAY LINE');
    }, orElse: () => <String, dynamic>{});
    expect(brtItinerary, isNotEmpty);

    final legs = (brtItinerary['legs'] as List).cast<Map<String, dynamic>>();
    final firstLeg = legs.first;
    expect(firstLeg['mode'], equals('WALK'));
    expect(firstLeg['isDirectPedestrian'], isTrue);
    expect(firstLeg['legGeometry'], isNotNull);
    final coords = (firstLeg['legGeometry']['coordinates'] as List).cast<List<dynamic>>();
    expect(coords.length, greaterThanOrEqualTo(2));
    // Direct geometry between user location and station
    expect(coords.first[0], closeTo(fromLon, 0.001));
    expect(coords.first[1], closeTo(fromLat, 0.001));

    // Next leg is BRT
    final secondLeg = legs[1];
    expect(
      secondLeg['routeShortName'].toString().toUpperCase(),
      anyOf(contains('BRT'), contains('SUNWAY LINE')),
    );
    final brtGeometry = secondLeg['legGeometry'] as Map;
    final brtCoordinates = brtGeometry['coordinates'] as List;
    expect(
      brtCoordinates.length,
      greaterThan(2),
      reason: 'BRT geometry should follow its GTFS alignment, not just its stops.',
    );
  });

  test('BRT shape lookup replaces endpoint-only online geometry', () async {
    final geometry = await OfflineRaptorRouter().brtGeometryForLeg(
      routeShortName: 'SUNWAY LINE',
      fromLat: 3.055246,
      fromLon: 101.591972,
      toLat: 3.082856,
      toLon: 101.612238,
    );

    expect(geometry.length, greaterThan(2));
  });

  test('South Quay to SS 18 keeps the walkable USJ 7 rail stop in search', () async {
    final result = await OfflineRaptorRouter().plan(
      fromLat: 3.061938,
      fromLon: 101.595626,
      toLat: 3.072,
      toLon: 101.588,
      departure: DateTime(2026, 10, 12, 14),
    );

    expect(result, isNotNull);
    final itineraries = (result!['itineraries'] as List)
        .cast<Map<String, dynamic>>();
    expect(itineraries, isNotEmpty);

    final legs = (itineraries.first['legs'] as List)
        .cast<Map<String, dynamic>>();
    final firstTransitLeg = legs.firstWhere(
      (leg) => leg['mode'] != 'WALK' && leg['mode'] != 'HAIL',
    );
    expect(
      firstTransitLeg['routeShortName'],
      equals('KJL'),
      reason: 'The best route should walk to USJ 7 and take KJL to SS 18.',
    );
    expect((firstTransitLeg['from'] as Map)['name'], equals('USJ 7'));
    expect((firstTransitLeg['to'] as Map)['name'], equals('SS 18'));
  });

  test('Sunway Line dynamically assigns terminus based on passenger direction', () async {
    // 1. Eastbound: South Quay -> Setia Jaya
    final eastboundResult = await OfflineRaptorRouter().plan(
      fromLat: 3.0617,
      fromLon: 101.5969,
      toLat: 3.0828,
      toLon: 101.6123,
      departure: DateTime(2026, 10, 12, 14, 0),
    );
    expect(eastboundResult, isNotNull);
    final ebItins = (eastboundResult!['itineraries'] as List).cast<Map<String, dynamic>>();
    expect(ebItins, isNotEmpty);
    final ebBrtLegMap = (ebItins.first['legs'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((leg) => !_isStreetMode(leg['mode']?.toString() ?? ''));
    expect(ebBrtLegMap['terminus'], equals('Setia Jaya'));
    final ebLegModel = ItineraryLeg.fromJson(ebBrtLegMap);
    expect(ebLegModel.terminus, equals('Setia Jaya'));
    expect(ebLegModel.terminalDirection, equals('to Setia Jaya'));

    // 2. Westbound: Setia Jaya -> South Quay / USJ 7
    final westboundResult = await OfflineRaptorRouter().plan(
      fromLat: 3.0828,
      fromLon: 101.6123,
      toLat: 3.0617,
      toLon: 101.5969,
      departure: DateTime(2026, 10, 12, 14, 0),
    );
    expect(westboundResult, isNotNull);
    final wbItins = (westboundResult!['itineraries'] as List).cast<Map<String, dynamic>>();
    expect(wbItins, isNotEmpty);
    final wbBrtLegMap = (wbItins.first['legs'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((leg) => !_isStreetMode(leg['mode']?.toString() ?? ''));
    expect(wbBrtLegMap['terminus'], equals('USJ 7'));
    final wbLegModel = ItineraryLeg.fromJson(wbBrtLegMap);
    expect(wbLegModel.terminus, equals('USJ 7'));
    expect(wbLegModel.terminalDirection, equals('to USJ 7'));
  });
}

bool _isStreetMode(String mode) {
  final upper = mode.toUpperCase();
  return upper == 'WALK' || upper == 'CAR' || upper == 'HAIL';
}
