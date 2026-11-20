import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/models/transit.dart';
import 'package:jomride/widgets/incident_report_sheet.dart';

/// A phone's screen size, system insets and soft keyboard height.
class _Phone {
  const _Phone(
    this.name,
    this.size, {
    required this.top,
    required this.bottom,
    required this.keyboard,
  });

  final String name;
  final Size size;
  final double top;
  final double bottom;
  final double keyboard;
}

const _phones = <_Phone>[
  _Phone('iPhone 15 Pro', Size(393, 852), top: 59, bottom: 34, keyboard: 336),
  _Phone('Android 360x800', Size(360, 800), top: 36, bottom: 24, keyboard: 300),
  _Phone(
    'small Android 360x640',
    Size(360, 640),
    top: 24,
    bottom: 0,
    keyboard: 270,
  ),
];

void _setInsets(WidgetTester tester, _Phone phone, {required bool keyboard}) {
  final keyboardHeight = keyboard ? phone.keyboard : 0.0;
  tester.view
    ..physicalSize = phone.size
    ..devicePixelRatio = 1
    ..viewPadding = FakeViewPadding(top: phone.top, bottom: phone.bottom)
    ..padding = FakeViewPadding(
      top: phone.top,
      bottom: math.max(0, phone.bottom - keyboardHeight),
    )
    ..viewInsets = FakeViewPadding(bottom: keyboardHeight);
}

/// Opens the sheet the way the map screen does, via [showIncidentTypeSheet].
Future<Completer<IncidentReportSubmission?>> _openSheet(
  WidgetTester tester,
) async {
  final result = Completer<IncidentReportSubmission?>();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result.complete(
                  await showIncidentTypeSheet(
                    context,
                    isBusStop: false,
                    stopName: 'USJ 7',
                  ),
                );
              },
              child: const Text('Open report'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open report'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  // Before the sheet was scroll-controlled, its scrollable area collapsed to
  // 10-70dp whenever the keyboard opened, hiding the comment field and every
  // category row.
  for (final phone in _phones) {
    testWidgets(
      'comment field stays visible with the keyboard open on ${phone.name}',
      (tester) async {
        addTearDown(tester.view.reset);
        _setInsets(tester, phone, keyboard: false);
        await _openSheet(tester);

        await tester.tap(find.byType(TextField));
        await tester.pump();
        _setInsets(tester, phone, keyboard: true);
        await tester.pumpAndSettle();

        final viewport = tester.getRect(find.byType(SingleChildScrollView));
        final field = tester.getRect(find.byType(TextField));
        expect(
          field.top,
          greaterThanOrEqualTo(viewport.top - 0.5),
          reason: 'top of the comment field is scrolled out of view',
        );
        expect(
          field.bottom,
          lessThanOrEqualTo(viewport.bottom + 0.5),
          reason: 'bottom of the comment field is hidden behind the keyboard',
        );
        expect(
          viewport.height,
          greaterThanOrEqualTo(200),
          reason: 'room for the comment field plus at least one category row',
        );
        expect(
          tester.getRect(find.byType(BottomSheet)).top,
          greaterThanOrEqualTo(phone.top - 0.5),
          reason: 'the sheet must not extend under the status bar',
        );
      },
    );
  }

  testWidgets(
    'typed comment is submitted with the chosen category while the keyboard '
    'is open',
    (tester) async {
      addTearDown(tester.view.reset);
      final phone = _phones.last;
      _setInsets(tester, phone, keyboard: false);
      final result = await _openSheet(tester);

      await tester.enterText(find.byType(TextField), 'Train held at platform');
      _setInsets(tester, phone, keyboard: true);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Service disruption'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Service disruption'));
      await tester.pumpAndSettle();

      // Fail immediately if the tap missed, rather than awaiting forever.
      expect(
        result.isCompleted,
        isTrue,
        reason: 'tapping a category row should submit the report',
      );
      final submission = await result.future;
      expect(submission?.type, IncidentType.disruption);
      expect(submission?.comment, 'Train held at platform');
    },
  );
}
