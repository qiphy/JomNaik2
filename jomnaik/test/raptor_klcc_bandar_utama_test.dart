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

  test('KLCC to Bandar Utama multiple locations test', () async {
    final router = OfflineRaptorRouter();
    
    final origins = [
      ('KLCC Station', 3.158935, 101.713287),
      ('Suria KLCC / Twin Towers', 3.1579, 101.7116),
      ('KLCC Nominatim (City Centre)', 3.1559503, 101.7145746),
      ('KLCC Park East', 3.1550, 101.7160),
      ('Persiaran KLCC', 3.15712, 101.71834),
    ];

    final destinations = [
      ('Bandar Utama MRT', 3.14671, 101.618599),
      ('Bandar Utama Town (Nominatim)', 3.1432113, 101.6113803),
      ('1 Utama Shopping Centre', 3.1478, 101.6156),
    ];

    for (final orig in origins) {
      for (final dest in destinations) {
        print('\n=============================================');
        print('ROUTING: ${orig.$1} -> ${dest.$1}');
        final result = await router.plan(
          fromLat: orig.$2,
          fromLon: orig.$3,
          toLat: dest.$2,
          toLon: dest.$3,
          departure: DateTime(2026, 10, 12, 12, 0),
        );

        if (result == null) {
          print('  NO ROUTE FOUND!');
          continue;
        }

        final itineraries = result['itineraries'] as List;
        print('Found ${itineraries.length} itineraries. Top itinerary:');
        if (itineraries.isNotEmpty) {
          final it = itineraries.first as Map<String, dynamic>;
          print('Top route duration: ${(it['duration'] as num) / 60} min, walking: ${(it['walkingSeconds'] as num?)?.toDouble() ?? 0}s');
          final legs = it['legs'] as List? ?? [];
          for (final leg in legs) {
            final mode = leg['mode'];
            final route = leg['routeShortName'] ?? leg['route'] ?? leg['line'];
            final from = leg['from']?['name'] ?? leg['from'];
            final to = leg['to']?['name'] ?? leg['to'];
            print('  -> $mode ($route) from $from to $to');
          }
        }
      }
    }
  });
}
