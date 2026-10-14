import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/widgets/live_guidance_card.dart';

void main() {
  testWidgets('incident notice keeps review-alternatives action available', (
    tester,
  ) async {
    var reviewedAlternatives = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveGuidanceCard(
            isActive: true,
            hasCurrentStep: true,
            currentStep: 2,
            totalSteps: 4,
            message:
                'Continue to USJ 7\nIncident reported near USJ 7. One lower-risk alternative available.',
            showBoardedAction: false,
            isReplanning: false,
            isCompleted: false,
            completedTrips: 0,
            onStart: () {},
            onBoarded: () {},
            onReplan: () => reviewedAlternatives = true,
            onStop: () {},
            replanLabel: 'Review alternatives',
          ),
        ),
      ),
    );

    expect(find.textContaining('Incident reported near USJ 7'), findsOneWidget);
    await tester.tap(find.text('Review alternatives'));
    expect(reviewedAlternatives, isTrue);
  });
}
