import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/models/transit.dart';
import 'package:jomride/widgets/incident_report_sheet.dart';

void main() {
  testWidgets('rail incident form submits its category and comment', (
    tester,
  ) async {
    final result = Completer<IncidentReportSubmission?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result.complete(
                  await showModalBottomSheet<IncidentReportSubmission>(
                    context: context,
                    builder: (_) => const IncidentTypeSelectionSheet(
                      isBusStop: false,
                      stopName: 'USJ 7',
                    ),
                  ),
                );
              },
              child: const Text('Open report'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open report'));
    await tester.pumpAndSettle();
    expect(find.text('Report a rail incident'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Train delayed at platform');
    await tester.ensureVisible(find.text('Service disruption'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Service disruption'));
    await tester.pumpAndSettle();

    final submission = await result.future;
    expect(submission?.type, IncidentType.disruption);
    expect(submission?.comment, 'Train delayed at platform');
  });

  testWidgets('bus incident form renders when no route is available', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: IncidentTypeSelectionSheet(
            isBusStop: true,
            stopName: 'South Quay',
          ),
        ),
      ),
    );

    expect(find.text('Report bus service'), findsOneWidget);
    expect(
      find.text('Bus has not arrived for over 10 minutes'),
      findsOneWidget,
    );
  });
}
