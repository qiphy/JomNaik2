import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/models/itinerary.dart';

void main() {
  test('rail itineraries sort ahead of non-rail itineraries', () {
    final rail = {
      'legs': [
        {'mode': 'WALK'},
        {'mode': 'SUBWAY'},
      ],
    };
    final bus = {
      'legs': [
        {'mode': 'BUS'},
      ],
    };
    final mixed = {
      'legs': [
        {'mode': 'SUBWAY'},
        {'mode': 'BUS'},
      ],
    };

    expect(compareRailPriority(rail, bus), -1);
    expect(compareRailPriority(rail, mixed), -1);
    expect(compareRailPriority(mixed, rail), 1);
    expect(compareRailPriority(bus, rail), 1);
    expect(compareRailPriority(bus, bus), 0);
  });
}
