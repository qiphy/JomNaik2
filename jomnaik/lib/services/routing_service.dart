import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../offline_raptor_router.dart';
import '../backend_client.dart';

class RoutingService {
  final http.Client httpClient;
  final String backendBaseUrl;
  final OfflineRaptorRouter offlineRouter;

  RoutingService({
    required this.httpClient,
    required this.backendBaseUrl,
    required this.offlineRouter,
  });

  /// Main multimodal routing entry point.
  ///
  /// The service attempts to obtain:
  ///
  /// 1. Public transport from the FastAPI/OTP backend
  /// 2. Offline public transport from RAPTOR if the backend fails
  /// 3. Walking
  /// 4. E-hailing
  ///
  /// Importantly, walking and e-hailing are NOT fallbacks anymore.
  /// They are evaluated alongside public transport whenever possible.
  Future<Map<String, dynamic>?> getRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    String? fromStopId,
    String? toStopId,
    bool preferBrt = false,
    required void Function(String) onMessage,
  }) async {
    final departure = DateTime.now();

    Map<String, dynamic>? transitRoute;
    bool usedOfflineTransit = false;

    // ------------------------------------------------------------
    // 1. Try online public transport routing
    // ------------------------------------------------------------

    try {
      transitRoute = await _getOnlineTransitRoute(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        fromStopId: fromStopId,
        toStopId: toStopId,
        preferBrt: preferBrt,
        departure: departure,
      );

      if (transitRoute != null) {
        debugPrint('Online transit routing succeeded.');
      }
    } on TimeoutException {
      debugPrint('Online transit routing timed out.');
    } on http.ClientException catch (error) {
      debugPrint('Online transit network error: $error');
    } on FormatException catch (error) {
      debugPrint('Online transit JSON error: $error');
    } catch (error) {
      debugPrint('Online transit routing error: $error');
    }

    // ------------------------------------------------------------
    // 2. If online transit failed, try offline RAPTOR
    // ------------------------------------------------------------

    if (transitRoute == null) {
      try {
        transitRoute = await _getOfflineTransitRoute(
          fromLat: fromLat,
          fromLon: fromLon,
          toLat: toLat,
          toLon: toLon,
          fromStopId: fromStopId,
          toStopId: toStopId,
        );

        if (transitRoute != null) {
          usedOfflineTransit = true;
          debugPrint('Offline RAPTOR routing succeeded.');
        }
      } catch (error) {
        debugPrint('Offline RAPTOR routing error: $error');
      }
    }

    // ------------------------------------------------------------
    // 3. Generate independent alternative modes
    //
    // These are ALWAYS considered, even when transit succeeds.
    // ------------------------------------------------------------

    final alternatives = await _getAlternativeModes(
      fromLat: fromLat,
      fromLon: fromLon,
      toLat: toLat,
      toLon: toLon,
      departure: departure,
    );

    // ------------------------------------------------------------
    // 4. Combine everything
    // ------------------------------------------------------------

    final combinedItineraries = <Map<String, dynamic>>[];

    if (transitRoute != null) {
      final transitItineraries = _extractItineraries(transitRoute);

      for (final itinerary in transitItineraries) {
        if (itinerary is Map) {
          final normalized = Map<String, dynamic>.from(itinerary);

          normalized.putIfAbsent(
            'routeCategory',
            () => 'transit',
          );

          normalized.putIfAbsent(
            'routingSource',
            () => usedOfflineTransit ? 'offline_raptor' : 'backend',
          );

          combinedItineraries.add(normalized);
        }
      }
    }

    combinedItineraries.addAll(alternatives);

    if (combinedItineraries.isEmpty) {
      onMessage('No routes could be found for this journey.');
      return null;
    }

    // ------------------------------------------------------------
    // 5. Rank itineraries
    //
    // Do NOT simply make e-hailing the fallback.
    //
    // Transit is slightly preferred when journey times are similar,
    // while significantly faster alternatives are allowed to rank
    // higher.
    // ------------------------------------------------------------

    final ranked = _rankItineraries(combinedItineraries);

    final hasTransit = ranked.any(
      (itinerary) => itinerary['routeCategory'] == 'transit',
    );

    final hasEhailing = ranked.any(
      (itinerary) => itinerary['routeCategory'] == 'ehailing',
    );

    final hasWalking = ranked.any(
      (itinerary) => itinerary['routeCategory'] == 'walk',
    );

    if (usedOfflineTransit) {
      onMessage(
        'Using offline timetable routing. Live transit updates are unavailable.',
      );
    } else if (!hasTransit) {
      onMessage(
        'No public transport route found. Showing alternative travel options.',
      );
    } else if (hasEhailing || hasWalking) {
      onMessage(
        'Multiple travel options found. Compare public transport, walking, and e-hailing.',
      );
    }

    return {
      'itineraries': ranked,
      'offlineRouting': usedOfflineTransit,
      'multimodal': true,
      'availableModes': {
        'transit': hasTransit,
        'walk': hasWalking,
        'ehailing': hasEhailing,
      },
    };
  }

  // ==================================================================
  // ONLINE TRANSIT
  // ==================================================================

  Future<Map<String, dynamic>?> _getOnlineTransitRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    String? fromStopId,
    String? toStopId,
    required bool preferBrt,
    required DateTime departure,
  }) async {
    final requestBody = <String, dynamic>{
      'from_lat': fromLat,
      'from_lon': fromLon,
      'to_lat': toLat,
      'to_lon': toLon,
      'prefer_brt': preferBrt,
      'departure_date':
          '${departure.year.toString().padLeft(4, '0')}-'
          '${departure.month.toString().padLeft(2, '0')}-'
          '${departure.day.toString().padLeft(2, '0')}',
      'departure_time':
          '${departure.hour.toString().padLeft(2, '0')}:'
          '${departure.minute.toString().padLeft(2, '0')}:'
          '${departure.second.toString().padLeft(2, '0')}',
    };

    if (fromStopId != null) {
      requestBody['from_stop_id'] = fromStopId;
    }

    if (toStopId != null) {
      requestBody['to_stop_id'] = toStopId;
    }

    final response = await httpClient
        .post(
          Uri.parse('$backendBaseUrl/api/route'),
          headers: await backendHeaders(json: true),
          body: jsonEncode(requestBody),
        )
        .timeout(const Duration(seconds: 70));

    if (response.statusCode != 200) {
      debugPrint(
        'Route API returned ${response.statusCode}: ${response.body}',
      );
      return null;
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Route service returned a non-object response.',
      );
    }

    if (decoded['itineraries'] is! List) {
      throw const FormatException(
        'Route service response does not contain itineraries.',
      );
    }

    final itineraries = decoded['itineraries'] as List;

    if (itineraries.isEmpty) {
      debugPrint('Online transit routing returned zero itineraries.');
      return null;
    }

    return decoded;
  }

  // ==================================================================
  // OFFLINE TRANSIT
  // ==================================================================

  Future<Map<String, dynamic>?> _getOfflineTransitRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    String? fromStopId,
    String? toStopId,
  }) async {
    try {
      final result = await offlineRouter.plan(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        fromStopId: fromStopId,
        toStopId: toStopId,
      );

      if (result == null || result['itineraries'] is! List) {
        return null;
      }

      final itineraries = result['itineraries'] as List;

      if (itineraries.isEmpty) {
        return null;
      }

      final validItineraries = <Map<String, dynamic>>[];

      for (final raw in itineraries) {
        if (raw is! Map) {
          continue;
        }

        final itinerary = Map<String, dynamic>.from(raw);

        final duration =
            (itinerary['duration'] as num?)?.toDouble() ?? 0.0;

        // Ignore obviously broken RAPTOR results such as an overnight
        // wait caused by timetable/date issues.
        if (duration <= 0 || duration > 9000) {
          debugPrint(
            'Ignoring offline transit itinerary with duration '
            '${(duration / 3600).toStringAsFixed(1)} hours.',
          );
          continue;
        }

        itinerary['routeCategory'] = 'transit';
        itinerary['routingSource'] = 'offline_raptor';
        itinerary['offlineRouting'] = true;

        validItineraries.add(itinerary);
      }

      if (validItineraries.isEmpty) {
        return null;
      }

      return {
        ...result,
        'itineraries': validItineraries,
        'offlineRouting': true,
      };
    } catch (error) {
      debugPrint('Offline RAPTOR error: $error');
      return null;
    }
  }

  // ==================================================================
  // ALTERNATIVE MODES
  // ==================================================================

  Future<List<Map<String, dynamic>>> _getAlternativeModes({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    required DateTime departure,
  }) async {
    final results = await Future.wait([
      _generateWalkingRoute(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        departure: departure,
      ),
      _generateEHailingRoute(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        departure: departure,
      ),
    ]);

    return results
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  // ==================================================================
  // WALKING
  // ==================================================================

  Future<Map<String, dynamic>?> _generateWalkingRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    required DateTime departure,
  }) async {
    final distanceMeters = Geolocator.distanceBetween(
      fromLat,
      fromLon,
      toLat,
      toLon,
    );

    // Walking becomes impractical beyond this distance.
    const maxWalkingDistance = 5000.0;

    if (distanceMeters > maxWalkingDistance) {
      return null;
    }

    const walkingSpeedMetersPerSecond = 1.2;

    final walkSeconds =
        (distanceMeters / walkingSpeedMetersPerSecond).round();

    final endTime = departure.add(
      Duration(seconds: walkSeconds),
    );

    return {
      'duration': walkSeconds,
      'routeCategory': 'walk',
      'routingSource': 'geodesic_estimate',
      'distance': distanceMeters,
      'estimated': true,
      'fallbackMessage': 'Walking option',
      'legs': [
        {
          'mode': 'WALK',
          'startTime': departure.toIso8601String(),
          'endTime': endTime.toIso8601String(),
          'duration': walkSeconds,
          'distance': distanceMeters,
          'from': {
            'name': 'Start Location',
            'lat': fromLat,
            'lon': fromLon,
          },
          'to': {
            'name': 'Destination',
            'lat': toLat,
            'lon': toLon,
          },
          'legGeometry': {
            'points': _encodePolyline([
              [fromLat, fromLon],
              [toLat, toLon],
            ]),
            'precision': 5,
          },
        },
      ],
    };
  }

  // ==================================================================
  // E-HAILING
  // ==================================================================

  Future<Map<String, dynamic>?> _generateEHailingRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    required DateTime departure,
  }) async {
    final straightLineDistance = Geolocator.distanceBetween(
      fromLat,
      fromLon,
      toLat,
      toLon,
    );

    // Don't offer a car for effectively zero-distance journeys.
    if (straightLineDistance <= 50) {
      return null;
    }

    const pickupSeconds = 300;

    double driveSeconds;
    double roadDistance;
    String geometry;
    bool estimated;

    try {
      final osrmUrl = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '$fromLon,$fromLat;$toLon,$toLat'
        '?overview=simplified&geometries=polyline',
      );

      final response = await httpClient
          .get(osrmUrl)
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        throw Exception(
          'OSRM returned ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body);

      if (data is! Map ||
          data['routes'] is! List ||
          (data['routes'] as List).isEmpty) {
        throw Exception('OSRM returned no routes.');
      }

      final route = (data['routes'] as List).first;

      if (route is! Map) {
        throw Exception('Invalid OSRM route.');
      }

      driveSeconds =
          (route['duration'] as num?)?.toDouble() ?? 0;

      roadDistance =
          (route['distance'] as num?)?.toDouble() ?? 0;

      geometry =
          route['geometry'] as String? ??
          _encodePolyline([
            [fromLat, fromLon],
            [toLat, toLon],
          ]);

      if (driveSeconds <= 0) {
        throw Exception('OSRM returned invalid duration.');
      }

      estimated = false;
    } catch (error) {
      debugPrint('OSRM e-hailing routing unavailable: $error');

      // Offline/degraded estimate.
      //
      // We deliberately use a modest road-network detour factor rather
      // than treating straight-line distance as actual road distance.
      const roadDetourFactor = 1.3;
      const fallbackDrivingSpeed = 30.0 / 3.6;

      roadDistance = straightLineDistance * roadDetourFactor;

      driveSeconds =
          roadDistance / fallbackDrivingSpeed;

      geometry = _encodePolyline([
        [fromLat, fromLon],
        [toLat, toLon],
      ]);

      estimated = true;
    }

    final totalSeconds =
        pickupSeconds + driveSeconds.round();

    final endTime = departure.add(
      Duration(seconds: totalSeconds),
    );

    return {
      'duration': totalSeconds,
      'routeCategory': 'ehailing',
      'routingSource': estimated
          ? 'estimated'
          : 'osrm',
      'estimated': estimated,
      'pickupDuration': pickupSeconds,
      'drivingDuration': driveSeconds.round(),
      'distance': roadDistance,
      'fallbackMessage': estimated
          ? 'Estimated e-hailing journey. Road routing is temporarily unavailable.'
          : 'E-hailing option',
      'legs': [
        {
          'mode': 'HAIL',
          'startTime': departure.toIso8601String(),
          'endTime': endTime.toIso8601String(),
          'duration': totalSeconds,
          'pickupDuration': pickupSeconds,
          'drivingDuration': driveSeconds.round(),
          'distance': roadDistance,
          'from': {
            'name': 'Start Location',
            'lat': fromLat,
            'lon': fromLon,
          },
          'to': {
            'name': 'Destination',
            'lat': toLat,
            'lon': toLon,
          },
          'legGeometry': {
            'points': geometry,
            'precision': 5,
          },
        },
      ],
    };
  }

  // ==================================================================
  // ITINERARY RANKING
  // ==================================================================

  List<Map<String, dynamic>> _rankItineraries(
    List<Map<String, dynamic>> itineraries,
  ) {
    final result = List<Map<String, dynamic>>.from(itineraries);

    result.sort((a, b) {
      final durationA =
          (a['duration'] as num?)?.toDouble() ??
          double.infinity;

      final durationB =
          (b['duration'] as num?)?.toDouble() ??
          double.infinity;

      final categoryA =
          a['routeCategory']?.toString() ?? '';

      final categoryB =
          b['routeCategory']?.toString() ?? '';

      // Primary factor: journey time.
      //
      // However, public transport receives a small preference when
      // journey times are reasonably close.
      final scoreA = _routingScore(
        duration: durationA,
        category: categoryA,
      );

      final scoreB = _routingScore(
        duration: durationB,
        category: categoryB,
      );

      return scoreA.compareTo(scoreB);
    });

    // Mark the first itinerary as the recommended option.
    for (var i = 0; i < result.length; i++) {
      result[i]['recommended'] = i == 0;
    }

    return result;
  }

  double _routingScore({
    required double duration,
    required String category,
  }) {
    double score = duration;

    // Give transit a modest advantage over e-hailing/walking when
    // journey times are similar.
    //
    // This does NOT make transit automatically win.
    //
    // Example:
    // Transit:   40 min -> score ~38
    // E-hailing: 20 min -> score ~20
    //
    // E-hailing still wins because it is substantially faster.
    if (category == 'transit') {
      score -= 120;
    }

    return score;
  }

  // ==================================================================
  // HELPERS
  // ==================================================================

  List<dynamic> _extractItineraries(
    Map<String, dynamic> route,
  ) {
    final raw = route['itineraries'];

    if (raw is List) {
      return raw;
    }

    return const [];
  }

  /// Encodes a list of [latitude, longitude] points using Google's
  /// encoded polyline algorithm.
  String _encodePolyline(
    List<List<double>> points, {
    int precision = 5,
  }) {
    final result = StringBuffer();

    final factor = math.pow(
      10,
      precision,
    ).toInt();

    var lastLat = 0;
    var lastLon = 0;

    for (final point in points) {
      final lat = (point[0] * factor).round();
      final lon = (point[1] * factor).round();

      _encodeChunk(
        lat - lastLat,
        result,
      );

      _encodeChunk(
        lon - lastLon,
        result,
      );

      lastLat = lat;
      lastLon = lon;
    }

    return result.toString();
  }

  void _encodeChunk(
    int value,
    StringBuffer result,
  ) {
    var v = value < 0
        ? ~(value << 1)
        : (value << 1);

    while (v >= 0x20) {
      result.writeCharCode(
        (0x20 | (v & 0x1f)) + 63,
      );

      v >>= 5;
    }

    result.writeCharCode(
      v + 63,
    );
  }
}