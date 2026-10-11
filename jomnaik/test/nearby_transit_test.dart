import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:jomride/models/transit.dart';

void main() {
  group('Nearby Transit and Incident Reporting Tests', () {
    test('TransitStop accurately parses rail station and bus stop GeoJSON', () {
      final railFeature = {
        'properties': {
          'id': 'rapid-kl-rail:KJ15',
          'name': 'KLCC',
          'transit_type': 'rail',
          'routes': 'KJ',
        },
        'geometry': {
          'coordinates': [101.7118, 3.1593],
        },
      };

      final busFeature = {
        'properties': {
          'id': 'rapid-kl-bus:KL1821',
          'name': 'Pasar Seni (Platform A1 - A2)',
          'transit_type': 'bus',
          'routes': '580, 780',
        },
        'geometry': {
          'coordinates': [101.6960, 3.1420],
        },
      };

      final railStop = TransitStop.fromGeoJson(railFeature);
      expect(railStop, isNotNull);
      expect(railStop!.id, 'rapid-kl-rail:KJ15');
      expect(railStop.name, 'KLCC');
      expect(railStop.transitType, 'rail');
      expect(railStop.routes, 'KJ');

      final busStop = TransitStop.fromGeoJson(busFeature);
      expect(busStop, isNotNull);
      expect(busStop!.id, 'rapid-kl-bus:KL1821');
      expect(busStop.name, 'Pasar Seni (Platform A1 - A2)');
      expect(busStop.transitType, 'bus');
      expect(busStop.routes, '580, 780');
    });

    test('Nearest transit point lookup finds closest stop among rail stations and bus stops', () {
      final stops = <String, TransitStop>{
        'rapid-kl-rail:KJ15': const TransitStop(
          id: 'rapid-kl-rail:KJ15',
          name: 'KLCC LRT',
          lat: 3.1593,
          lon: 101.7118,
          transitType: 'rail',
          routes: 'KJ',
        ),
        'rapid-kl-bus:KL94': const TransitStop(
          id: 'rapid-kl-bus:KL94',
          name: 'KLCC (Utara) Bus Stop',
          lat: 3.1585,
          lon: 101.7120,
          transitType: 'bus',
          routes: '300, 303',
        ),
        'rapid-kl-rail:MR6': const TransitStop(
          id: 'rapid-kl-rail:MR6',
          name: 'Bukit Bintang Monorail',
          lat: 3.1466,
          lon: 101.7115,
          transitType: 'rail',
          routes: 'MR',
        ),
      };

      // Location right next to the bus stop (3.1584, 101.7120)
      const userLat = 3.1584;
      const userLon = 101.7120;

      final nearestStop = stops.values.reduce((closest, candidate) {
        final closestDist = Geolocator.distanceBetween(
          userLat,
          userLon,
          closest.lat,
          closest.lon,
        );
        final candidateDist = Geolocator.distanceBetween(
          userLat,
          userLon,
          candidate.lat,
          candidate.lon,
        );
        return candidateDist < closestDist ? candidate : closest;
      });

      expect(nearestStop.id, 'rapid-kl-bus:KL94');
      expect(nearestStop.transitType, 'bus');
      expect(nearestStop.name, 'KLCC (Utara) Bus Stop');

      final distance = Geolocator.distanceBetween(
        userLat,
        userLon,
        nearestStop.lat,
        nearestStop.lon,
      );
      // Ensure distance is within 100m reporting proximity threshold
      expect(distance <= 100, isTrue);
    });

    test('100m proximity check prevents incident reporting when too far', () {
      final stop = const TransitStop(
        id: 'rapid-kl-rail:KJ15',
        name: 'KLCC LRT',
        lat: 3.1593,
        lon: 101.7118,
        transitType: 'rail',
        routes: 'KJ',
      );

      // User is ~500m away
      final distance = Geolocator.distanceBetween(
        3.1550,
        101.7118,
        stop.lat,
        stop.lon,
      );

      expect(distance > 100, isTrue);
    });
  });
}
