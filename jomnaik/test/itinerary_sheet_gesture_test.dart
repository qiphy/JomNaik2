import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/models/itinerary.dart';
import 'package:jomride/widgets/itinerary_sheet.dart';

void main() {
  final sampleItinerary = Itinerary(
    duration: 1800,
    legs: [],
  );

  testWidgets('ItinerarySheet gestures: touching card signals active, touching above card passes through', (tester) async {
    bool mapTapped = false;
    bool isScrollingCard = false;
    double? sheetExtent;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => mapTapped = true,
                child: Container(
                  color: Colors.blue,
                  child: const Center(child: Text('Map Area')),
                ),
              ),
              ItinerarySheet(
                itinerary: sampleItinerary,
                initialExtent: 0.3,
                guidanceCard: const SizedBox(),
                onDismiss: () {},
                onFindApps: () {},
                onCardInteractionChanged: (val) {
                  isScrollingCard = val;
                },
                onExtentChanged: (extent) {
                  sheetExtent = extent;
                },
              ),
            ],
          ),
        ),
      ),
    );

    // 1. Touch above the card (y = 100) -> should tap the map and NOT set isScrollingCard
    await tester.tapAt(const Offset(200, 100));
    expect(mapTapped, isTrue);
    expect(isScrollingCard, isFalse);

    // 2. Touch on the card (y = 550) -> should set isScrollingCard to true
    final gesture = await tester.startGesture(const Offset(200, 550));
    expect(isScrollingCard, isTrue);

    // 3. Release touch on the card -> should set isScrollingCard to false
    await gesture.up();
    expect(isScrollingCard, isFalse);

    await tester.dragFrom(const Offset(200, 550), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(sheetExtent, greaterThan(0.3));
  });
}
