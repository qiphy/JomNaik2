import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/widgets/route_choices_sheet.dart';

void main() {
  testWidgets('route summary includes every walk and transit leg in order', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RouteChoicesSheet(
            itineraries: [
              {
                'duration': 3600,
                'legs': [
                  {
                    'mode': 'WALK',
                    'startTime': '2026-10-14T10:00:00',
                    'endTime': '2026-10-14T10:05:00',
                  },
                  {
                    'mode': 'SUBWAY',
                    'routeShortName': 'KJL',
                    'startTime': '2026-10-14T10:05:00',
                    'endTime': '2026-10-14T10:25:00',
                  },
                  {
                    'mode': 'WALK',
                    'isTransferWalk': true,
                    'startTime': '2026-10-14T10:25:00',
                    'endTime': '2026-10-14T10:30:00',
                  },
                  {
                    'mode': 'TRAM',
                    'routeShortName': 'BRT',
                    'startTime': '2026-10-14T10:30:00',
                    'endTime': '2026-10-14T10:45:00',
                  },
                  {
                    'mode': 'WALK',
                    'startTime': '2026-10-14T10:45:00',
                    'endTime': '2026-10-14T10:50:00',
                  },
                ],
              },
            ],
            onSelectItinerary: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Walk → KJL → BRT → Walk'), findsOneWidget);
  });
}
