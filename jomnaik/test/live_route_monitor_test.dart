import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jomride/utils/live_route_monitor.dart';

void main() {
  const route = [
    [101.0, 3.0],
    [101.01, 3.0],
  ];
  final baseTime = DateTime(2026, 10, 14, 12);

  group('RouteDeviationDetector', () {
    test('requires repeated accurate walking fixes outside the route', () {
      final detector = RouteDeviationDetector();

      expect(
        detector.observe(
          latitude: 3.002,
          longitude: 101.005,
          accuracyMeters: 8,
          speedMetersPerSecond: 1.2,
          timestamp: baseTime,
          isWalking: true,
          routeCoordinates: route,
        ),
        isFalse,
      );
      expect(
        detector.observe(
          latitude: 3.002,
          longitude: 101.005,
          accuracyMeters: 8,
          speedMetersPerSecond: 1.2,
          timestamp: baseTime.add(const Duration(seconds: 30)),
          isWalking: true,
          routeCoordinates: route,
        ),
        isTrue,
      );
    });

    test('ignores GPS drift, poor accuracy, stationary and transit fixes', () {
      final detector = RouteDeviationDetector();

      expect(
        detector.observe(
          latitude: 3.0004,
          longitude: 101.005,
          accuracyMeters: 20,
          speedMetersPerSecond: 1,
          timestamp: baseTime,
          isWalking: true,
          routeCoordinates: route,
        ),
        isFalse,
      );
      expect(
        detector.observe(
          latitude: 3.002,
          longitude: 101.005,
          accuracyMeters: 90,
          speedMetersPerSecond: 1,
          timestamp: baseTime.add(const Duration(seconds: 30)),
          isWalking: true,
          routeCoordinates: route,
        ),
        isFalse,
      );
      expect(
        detector.observe(
          latitude: 3.002,
          longitude: 101.005,
          accuracyMeters: 8,
          speedMetersPerSecond: 0,
          timestamp: baseTime.add(const Duration(seconds: 60)),
          isWalking: true,
          routeCoordinates: route,
        ),
        isFalse,
      );
      expect(
        detector.observe(
          latitude: 3.002,
          longitude: 101.005,
          accuracyMeters: 8,
          speedMetersPerSecond: 1,
          timestamp: baseTime.add(const Duration(seconds: 90)),
          isWalking: false,
          routeCoordinates: route,
        ),
        isFalse,
      );
    });

    test('does not interpret a location jump as a sustained deviation', () {
      final detector = RouteDeviationDetector();

      expect(
        detector.observe(
          latitude: 3.002,
          longitude: 101.005,
          accuracyMeters: 8,
          speedMetersPerSecond: 1,
          timestamp: baseTime,
          isWalking: true,
          routeCoordinates: route,
        ),
        isFalse,
      );
      expect(
        detector.observe(
          latitude: 3.005,
          longitude: 101.005,
          accuracyMeters: 8,
          speedMetersPerSecond: 1,
          timestamp: baseTime.add(const Duration(seconds: 30)),
          isWalking: true,
          routeCoordinates: route,
        ),
        isFalse,
      );
    });
  });

  test('incident poller prevents duplicate timers and stops cleanly', () async {
    final requestGate = Completer<void>();
    var polls = 0;
    final poller = GuidanceIncidentPoller(
      interval: const Duration(milliseconds: 5),
      onCheck: () async {
        polls++;
        await requestGate.future;
      },
    );

    poller.start();
    poller.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(polls, 1);
    poller.stop();
    requestGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(polls, 1);
  });
}
