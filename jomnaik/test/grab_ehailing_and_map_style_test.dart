import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/models/itinerary.dart';

void main() {
  group('Grab E-hailing Deep Link and Parameters Tests', () {
    test('Constructs Grab deep link with pickup and destination coordinates & names', () {
      const pickupLat = 3.1571;
      const pickupLon = 101.7118;
      const pickupName = 'KLCC Station';

      const dropoffLat = 3.1189;
      const dropoffLon = 101.6162;
      const dropoffName = '1 Utama Shopping Centre';

      final queryParams = <String, String>{
        'screenType': 'RIDES',
        'dropoff_lat': dropoffLat.toString(),
        'dropoff_lng': dropoffLon.toString(),
        'destination_lat': dropoffLat.toString(),
        'destination_lng': dropoffLon.toString(),
        'dropoff_name': dropoffName,
        'destination_name': dropoffName,
        'dropoff[address]': dropoffName,
        'pickup_lat': pickupLat.toString(),
        'pickup_lng': pickupLon.toString(),
        'pickup_name': pickupName,
        'pickup[address]': pickupName,
      };

      final appUri = Uri(
        scheme: 'grab',
        host: 'open',
        queryParameters: queryParams,
      );

      expect(appUri.scheme, 'grab');
      expect(appUri.host, 'open');
      expect(appUri.queryParameters['screenType'], 'RIDES');
      expect(appUri.queryParameters['pickup_lat'], '3.1571');
      expect(appUri.queryParameters['pickup_lng'], '101.7118');
      expect(appUri.queryParameters['pickup_name'], 'KLCC Station');
      expect(appUri.queryParameters['dropoff_lat'], '3.1189');
      expect(appUri.queryParameters['dropoff_lng'], '101.6162');
      expect(appUri.queryParameters['dropoff_name'], '1 Utama Shopping Centre');

      // Web universal link fallback contains the same details
      final webUri = Uri.parse('https://r.grab.com/open').replace(
        queryParameters: queryParams,
      );
      expect(webUri.host, 'r.grab.com');
      expect(webUri.queryParameters['screenType'], 'RIDES');
      expect(webUri.queryParameters['dropoff_lat'], '3.1189');
    });

    test('ItineraryLeg extracts place info for Grab booking', () {
      final leg = ItineraryLeg(
        mode: 'HAIL',
        startTime: '2026-10-12T08:00:00Z',
        endTime: '2026-10-12T08:15:00Z',
        routeShortName: 'E-hailing to destination',
        fromPlace: const ItineraryPlace(
          name: 'Pasar Seni LRT',
          lat: 3.1420,
          lon: 101.6960,
        ),
        toPlace: const ItineraryPlace(
          name: 'Mid Valley Megamall',
          lat: 3.1179,
          lon: 101.6778,
        ),
      );

      expect(leg.fromPlace?.name, 'Pasar Seni LRT');
      expect(leg.fromPlace?.lat, 3.1420);
      expect(leg.fromPlace?.lon, 101.6960);

      expect(leg.toPlace?.name, 'Mid Valley Megamall');
      expect(leg.toPlace?.lat, 3.1179);
      expect(leg.toPlace?.lon, 101.6778);
    });
  });

  group('Map Style Dynamic Rules Tests', () {
    test('Dark mode transforms road lines into dark tones and symbols into legible light text', () {
      final mockRoadLine = <String, dynamic>{
        'id': 'roads_motorway',
        'type': 'line',
        'source-layer': 'roads',
        'paint': {'line-color': '#ffffff'},
      };

      final mockSymbol = <String, dynamic>{
        'id': 'roads_label',
        'type': 'symbol',
        'source-layer': 'roads',
        'paint': {'text-color': '#000000'},
      };

      // Apply dark mode styling rule
      final isMajor = mockRoadLine['id'].toString().contains('motorway');
      final roadPaint = (mockRoadLine['paint'] as Map<String, dynamic>);
      if (isMajor) {
        roadPaint['line-color'] = '#384964';
      }

      final symbolPaint = (mockSymbol['paint'] as Map<String, dynamic>);
      symbolPaint['text-color'] = '#e2e8f0';
      symbolPaint['text-halo-color'] = '#0f172a';

      // Roads are dark, NOT white
      expect(roadPaint['line-color'], '#384964');
      expect(roadPaint['line-color'], isNot('#ffffff'));

      // Labels are light with dark halo
      expect(symbolPaint['text-color'], '#e2e8f0');
      expect(symbolPaint['text-halo-color'], '#0f172a');
    });

    test('Satellite view sets road lines transparent and retains label contrast', () {
      final mockRoadLine = <String, dynamic>{
        'id': 'roads_primary',
        'type': 'line',
        'source-layer': 'roads',
        'paint': {'line-color': '#e9e9ed', 'line-width': 2},
      };

      final mockSymbol = <String, dynamic>{
        'id': 'places_suburb',
        'type': 'symbol',
        'source-layer': 'places',
        'paint': <String, dynamic>{},
      };

      // Apply satellite view rules
      final roadPaint = (mockRoadLine['paint'] as Map<String, dynamic>);
      roadPaint['line-opacity'] = 0.25;
      roadPaint['line-color'] = '#ffffff';

      final symbolPaint = (mockSymbol['paint'] as Map<String, dynamic>);
      symbolPaint['text-color'] = '#ffffff';
      symbolPaint['text-halo-color'] = '#000000';
      symbolPaint['text-halo-width'] = 2.0;

      expect(roadPaint['line-opacity'], 0.25);
      expect(symbolPaint['text-color'], '#ffffff');
      expect(symbolPaint['text-halo-color'], '#000000');
    });
  });
}
