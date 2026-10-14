import 'dart:async';
import 'dart:math' as math;

class GuidanceIncidentPoller {
  GuidanceIncidentPoller({
    required this.onCheck,
    this.interval = const Duration(minutes: 2),
  });

  final Future<void> Function() onCheck;
  final Duration interval;

  Timer? _timer;
  bool _isPolling = false;

  void start() {
    if (_timer?.isActive == true) return;
    _timer = Timer.periodic(interval, (_) => unawaited(_check()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _check() async {
    if (_isPolling) return;
    _isPolling = true;
    try {
      await onCheck();
    } catch (_) {
      // The owner handles location errors; timer callbacks must not escape.
    } finally {
      _isPolling = false;
    }
  }
}

class RouteDeviationDetector {
  RouteDeviationDetector({
    this.minimumDistanceMeters = 100,
    this.maximumAccuracyMeters = 60,
    this.requiredReadings = 2,
  });

  final double minimumDistanceMeters;
  final double maximumAccuracyMeters;
  final int requiredReadings;

  int _offRouteReadings = 0;
  double? _previousLatitude;
  double? _previousLongitude;
  DateTime? _previousTimestamp;

  void reset() {
    _offRouteReadings = 0;
    _previousLatitude = null;
    _previousLongitude = null;
    _previousTimestamp = null;
  }

  bool observe({
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required double speedMetersPerSecond,
    required DateTime timestamp,
    required bool isWalking,
    required List<List<double>> routeCoordinates,
  }) {
    if (!isWalking ||
        !accuracyMeters.isFinite ||
        accuracyMeters < 0 ||
        accuracyMeters > maximumAccuracyMeters ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        routeCoordinates.length < 2) {
      _clearReadings();
      return false;
    }

    final previousTimestamp = _previousTimestamp;
    if (previousTimestamp != null) {
      final elapsedSeconds = timestamp.difference(previousTimestamp).inSeconds;
      if (elapsedSeconds <= 0 || elapsedSeconds > 120) {
        _clearReadings();
      } else {
        final previousLatitude = _previousLatitude!;
        final previousLongitude = _previousLongitude!;
        final traveledMeters = _distance(
          previousLatitude,
          previousLongitude,
          latitude,
          longitude,
        );
        if (traveledMeters > math.max(100, elapsedSeconds * 8)) {
          _clearReadings();
          _remember(latitude, longitude, timestamp);
          return false;
        }
        if (speedMetersPerSecond >= 0 &&
            speedMetersPerSecond < 0.8 &&
            traveledMeters < 15) {
          _offRouteReadings = 0;
          _remember(latitude, longitude, timestamp);
          return false;
        }
      }
    } else if (speedMetersPerSecond >= 0 && speedMetersPerSecond < 0.8) {
      _remember(latitude, longitude, timestamp);
      return false;
    }

    _remember(latitude, longitude, timestamp);
    final distanceFromRoute = _distanceFromRoute(
      latitude,
      longitude,
      routeCoordinates,
    );
    final threshold = math.max(minimumDistanceMeters, accuracyMeters * 2);
    if (distanceFromRoute <= threshold) {
      _offRouteReadings = 0;
      return false;
    }

    _offRouteReadings++;
    if (_offRouteReadings < requiredReadings) return false;
    _offRouteReadings = 0;
    return true;
  }

  void _clearReadings() {
    _offRouteReadings = 0;
    _previousLatitude = null;
    _previousLongitude = null;
    _previousTimestamp = null;
  }

  void _remember(double latitude, double longitude, DateTime timestamp) {
    _previousLatitude = latitude;
    _previousLongitude = longitude;
    _previousTimestamp = timestamp;
  }

  double _distanceFromRoute(
    double latitude,
    double longitude,
    List<List<double>> coordinates,
  ) {
    var nearest = double.infinity;
    for (var index = 1; index < coordinates.length; index++) {
      final previous = coordinates[index - 1];
      final current = coordinates[index];
      if (previous.length < 2 || current.length < 2) continue;
      final distance = _distanceToSegment(
        latitude,
        longitude,
        previous[1],
        previous[0],
        current[1],
        current[0],
      );
      if (distance < nearest) nearest = distance;
    }
    return nearest;
  }

  double _distanceToSegment(
    double pointLatitude,
    double pointLongitude,
    double startLatitude,
    double startLongitude,
    double endLatitude,
    double endLongitude,
  ) {
    const metersPerDegree = 111320.0;
    final latitudeScale = math.cos(pointLatitude * math.pi / 180);
    final startX =
        (startLongitude - pointLongitude) * metersPerDegree * latitudeScale;
    final startY = (startLatitude - pointLatitude) * metersPerDegree;
    final endX =
        (endLongitude - pointLongitude) * metersPerDegree * latitudeScale;
    final endY = (endLatitude - pointLatitude) * metersPerDegree;
    final segmentX = endX - startX;
    final segmentY = endY - startY;
    final segmentLengthSquared = segmentX * segmentX + segmentY * segmentY;
    if (segmentLengthSquared == 0) {
      return math.sqrt(startX * startX + startY * startY);
    }
    final projection =
        ((-startX * segmentX) + (-startY * segmentY)) / segmentLengthSquared;
    final clampedProjection = projection.clamp(0.0, 1.0);
    final nearestX = startX + clampedProjection * segmentX;
    final nearestY = startY + clampedProjection * segmentY;
    return math.sqrt(nearestX * nearestX + nearestY * nearestY);
  }

  double _distance(
    double fromLatitude,
    double fromLongitude,
    double toLatitude,
    double toLongitude,
  ) {
    const earthRadiusMeters = 6371000.0;
    final latitudeDelta = (toLatitude - fromLatitude) * math.pi / 180;
    final longitudeDelta = (toLongitude - fromLongitude) * math.pi / 180;
    final value =
        math.sin(latitudeDelta / 2) * math.sin(latitudeDelta / 2) +
        math.cos(fromLatitude * math.pi / 180) *
            math.cos(toLatitude * math.pi / 180) *
            math.sin(longitudeDelta / 2) *
            math.sin(longitudeDelta / 2);
    return earthRadiusMeters *
        2 *
        math.atan2(math.sqrt(value), math.sqrt(1 - value));
  }
}
