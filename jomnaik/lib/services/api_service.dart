import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/transit.dart';
import '../models/search.dart';
import '../backend_client.dart';

class _TimedCache<T> {
  _TimedCache(this.value) : loadedAt = DateTime.now();
  final T value;
  final DateTime loadedAt;
}

class ApiService {
  ApiService({
    required this.httpClient,
    required this.backendBaseUrl,
  });

  final http.Client httpClient;
  final String backendBaseUrl;

  final Map<String, _TimedCache<List<StopDeparture>>> _departureCache = {};
  final Map<String, _TimedCache<List<StationIncident>>> _incidentCache = {};
  final Map<String, _TimedCache<TrafficCongestion?>> _trafficCache = {};

  Future<List<StopDeparture>> fetchNextDepartures(String stopId) async {
    final cached = _departureCache[stopId];
    if (cached != null &&
        DateTime.now().difference(cached.loadedAt) < const Duration(seconds: 15)) {
      return cached.value;
    }
    
    final uri = Uri.parse(
      '$backendBaseUrl/api/gtfs/stops/${Uri.encodeComponent(stopId)}/departures',
    ).replace(queryParameters: const {'limit': '6'});
    
    final response = await httpClient
        .get(uri, headers: await backendHeaders())
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw StateError('Could not load departures.');
    }

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic> || data['departures'] is! List) {
      throw const FormatException('Invalid departure response.');
    }

    final departures = (data['departures'] as List<dynamic>)
        .whereType<Map>()
        .map((d) => StopDeparture.fromJson(Map<String, dynamic>.from(d)))
        .toList();
        
    _departureCache[stopId] = _TimedCache(departures);
    return departures;
  }

  Future<List<StationIncident>> fetchStopIncidents(String stopId) async {
    final cached = _incidentCache[stopId];
    if (cached != null &&
        DateTime.now().difference(cached.loadedAt) < const Duration(seconds: 30)) {
      return cached.value;
    }
    const incidents = <StationIncident>[];
    _incidentCache[stopId] = _TimedCache(incidents);
    return incidents;
  }

  Future<TrafficCongestion?> fetchTrafficCongestion(
    String stationId,
    double latitude,
    double longitude,
  ) async {
    final cacheKey =
        '$stationId:${latitude.toStringAsFixed(4)},${longitude.toStringAsFixed(4)}';
    final cached = _trafficCache[cacheKey];
    
    if (cached != null &&
        DateTime.now().difference(cached.loadedAt) < const Duration(minutes: 1)) {
      return cached.value;
    }
    
    try {
      final uri = Uri.parse('$backendBaseUrl/api/traffic/congestion').replace(
        queryParameters: {
          'lat': latitude.toStringAsFixed(6),
          'lon': longitude.toStringAsFixed(6),
          'station_id': stationId,
        },
      );
      final response = await httpClient
          .get(uri, headers: await backendHeaders())
          .timeout(const Duration(seconds: 10));
          
      if (response.statusCode != 200) return null;
      
      final data = jsonDecode(response.body);
      if (data is! Map) return null;
      
      final congestion = TrafficCongestion.fromJson(Map<String, dynamic>.from(data));
      _trafficCache[cacheKey] = _TimedCache(congestion);
      return congestion;
    } catch (_) {
      return null;
    }
  }

  Future<void> submitIncident({
    required String stopId,
    required String stopName,
    required double stopLat,
    required double stopLon,
    required String reportType,
    required bool isBusStop,
    String? affectedRoute,
  }) async {
    final response = await httpClient.post(
      Uri.parse('$backendBaseUrl/api/incidents'),
      headers: await backendHeaders(json: true),
      body: jsonEncode({
        'station_id': stopId,
        'station_name': stopName,
        'station_lat': stopLat,
        'station_lon': stopLon,
        'report_type': reportType,
        'target_type': isBusStop ? 'bus' : 'station',
        'service_route': affectedRoute,
        'reported_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    if (response.statusCode != 202) {
      throw StateError('Incident was rejected');
    }
  }

  Future<void> logStationPresence(TransitStop stop) async {
    try {
      final response = await httpClient.post(
        Uri.parse('$backendBaseUrl/api/station-presence'),
        headers: await backendHeaders(json: true),
        body: jsonEncode({
          'station_id': stop.id,
          'station_name': stop.name,
          'observed_at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      if (response.statusCode != 202) {
        throw StateError('Presence was rejected');
      }
    } catch (_) {
      // Optional logging should fail silently
    }
  }

  Future<Map<String, dynamic>?> fetchStopsGeoJson() async {
    try {
      final response = await httpClient
          .get(
            Uri.parse('$backendBaseUrl/api/gtfs/stops'),
            headers: await backendHeaders(),
          )
          .timeout(const Duration(seconds: 10));
          
      if (response.statusCode != 200) return null;
      final document = jsonDecode(response.body);
      if (document is! Map || document['stops'] is! List) return null;

      final features = <Map<String, dynamic>>[];
      for (final item in document['stops'] as List) {
        if (item is! Map ||
            item['id'] == null ||
            item['name'] == null ||
            item['lat'] is! num ||
            item['lon'] is! num) {
          continue;
        }
        features.add({
          'type': 'Feature',
          'properties': {
            'id': item['id'].toString(),
            'name': item['name'].toString(),
            'transit_type': item['type'] == 'bus' ? 'bus' : 'rail',
            'routes': item['operator']?.toString() ?? '',
          },
          'geometry': {
            'type': 'Point',
            'coordinates': [
              (item['lon'] as num).toDouble(),
              (item['lat'] as num).toDouble(),
            ],
          },
        });
      }
      return {'type': 'FeatureCollection', 'features': features};
    } catch (error) {
      debugPrint('FastAPI stop catalogue unavailable: $error');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>?> fetchStationPerimeters() async {
    try {
      final response = await httpClient
          .get(
            Uri.parse('$backendBaseUrl/api/gtfs/station-access'),
            headers: await backendHeaders(),
          )
          .timeout(const Duration(seconds: 12));
          
      if (response.statusCode != 200) return null;
      final document = jsonDecode(response.body);
      if (document is! Map || document['stations'] is! Map) return null;

      final features = <Map<String, dynamic>>[];
      for (final entry in (document['stations'] as Map).entries) {
        final station = entry.value;
        if (station is! Map || station['perimeter'] is! Map) continue;
        final perimeter = station['perimeter'] as Map;
        if (perimeter['type'] != 'MultiPolygon' ||
            perimeter['coordinates'] is! List) {
          continue;
        }
        features.add({
          'type': 'Feature',
          'properties': {'id': entry.key.toString()},
          'geometry': perimeter,
        });
      }
      return features;
    } catch (error) {
      debugPrint('Station perimeter data unavailable: $error');
      return null;
    }
  }

Future<List<PlaceSearchResult>?> searchPlaces(String query) async {
    try {
      // Hit OpenStreetMap's Nominatim API directly
      final uri = Uri.parse('https://nominatim.openstreetmap.org/search').replace(
        queryParameters: {
          'q': query,
          'format': 'jsonv2',
          'limit': '10',
          'countrycodes': 'my', // Silently restricts results to Malaysia for better accuracy
        },
      );

      final response = await httpClient
          .get(
            uri,
            headers: {
              // Nominatim strictly requires a User-Agent header
              'User-Agent': 'JomNaik/1.0 (Transit App)', 
            },
          )
          .timeout(const Duration(seconds: 8));
          
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is List) {
          return data
              .whereType<Map>()
              .map((place) {
                // Map the OSM JSON fields into the format your model expects
                final rawName = place['name']?.toString();
                final displayName = place['display_name']?.toString() ?? 'Unknown place';
                
                final mappedJson = {
                  'name': rawName != null && rawName.isNotEmpty 
                      ? rawName 
                      : displayName.split(',').first,
                  'address': displayName,
                  'lat': double.tryParse(place['lat']?.toString() ?? '0'),
                  'lon': double.tryParse(place['lon']?.toString() ?? '0'),
                };
                
                return PlaceSearchResult.fromJson(mappedJson);
              })
              .where((place) => place.lat != 0 || place.lon != 0)
              .toList();
        }
      }
    } catch (error) {
      debugPrint('OSM place search unavailable: $error');
    }
    return null;
  }

  Future<Map<String, dynamic>?> fetchWeather(double lat, double lon, int requestVersion) async {
    try {
      final headers = await backendHeaders();
      headers['Cache-Control'] = 'no-cache';
      final response = await httpClient
          .get(
            Uri.parse('$backendBaseUrl/api/weather/klang-valley').replace(
              queryParameters: {
                'lat': lat.toStringAsFixed(6),
                'lon': lon.toStringAsFixed(6),
                'request': requestVersion.toString(),
              },
            ),
            headers: headers,
          )
          .timeout(const Duration(seconds: 15));
          
      if (response.statusCode != 200) return null;
      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.contains('application/json')) return null;
      
      return jsonDecode(response.body) as Map<String, dynamic>?;
    } catch (error) {
      debugPrint('Weather request failed: $error');
      return null;
    }
  }
}