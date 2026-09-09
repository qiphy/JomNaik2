import 'package:flutter/material.dart';
import 'itinerary.dart';
import 'search.dart';

class TransitStation {
  const TransitStation({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
  });

  static TransitStation? fromGeoJson(Map feature) {
    final properties = feature['properties'];
    final geometry = feature['geometry'];
    if (properties is! Map || geometry is! Map) return null;
    if (properties['transit_type']?.toString() != 'rail') return null;
    final coordinates = geometry['coordinates'];
    if (coordinates is! List || coordinates.length < 2) return null;
    final lon = coordinates[0];
    final lat = coordinates[1];
    if (lon is! num || lat is! num || properties['id'] == null) return null;
    return TransitStation(
      id: properties['id'].toString(),
      name: properties['name']?.toString() ?? 'Rail station',
      lat: lat.toDouble(),
      lon: lon.toDouble(),
    );
  }

  final String id;
  final String name;
  final double lat;
  final double lon;
}

class TransitStop {
  const TransitStop({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.transitType,
    required this.routes,
  });

  static TransitStop? fromGeoJson(Map feature) {
    final properties = feature['properties'];
    final geometry = feature['geometry'];
    if (properties is! Map || geometry is! Map) return null;
    final coordinates = geometry['coordinates'];
    if (coordinates is! List || coordinates.length < 2) return null;
    final lon = coordinates[0];
    final lat = coordinates[1];
    if (lon is! num || lat is! num || properties['id'] == null) return null;
    return TransitStop(
      id: properties['id'].toString(),
      name: properties['name']?.toString() ?? 'Transit stop',
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      transitType: properties['transit_type']?.toString() ?? 'bus',
      routes: properties['routes']?.toString() ?? '',
    );
  }

  PlaceSearchResult asPlaceSearchResult() => PlaceSearchResult(
        name: name,
        address: 'Selected transit stop',
        lat: lat,
        lon: lon,
        stopId: id,
      );

  final String id;
  final String name;
  final double lat;
  final double lon;
  final String transitType;
  final String routes;
}

class StopDeparture {
  const StopDeparture({
    required this.route,
    required this.time,
    required this.timestamp,
    required this.isEstimated,
    required this.direction,
  });

  factory StopDeparture.fromJson(Map<String, dynamic> json) {
    return StopDeparture(
      route: json['route']?.toString() ?? 'Transit service',
      time: json['time']?.toString() ?? '--:--',
      timestamp: json['timestamp'] is num
          ? (json['timestamp'] as num).toInt()
          : 0,
      isEstimated: json['is_estimated'] == true,
      direction:
          json['terminal']?.toString() ?? json['direction']?.toString() ?? '',
    );
  }

  final String route;
  final String time;
  final int timestamp;
  final bool isEstimated;
  final String direction;

  String get displayDirection {
    var destination = direction.trim();
    final lowerCase = destination.toLowerCase();
    if (lowerCase.startsWith('from ')) {
      final toIndex = lowerCase.indexOf(' to ');
      if (toIndex >= 0) destination = destination.substring(toIndex + 4).trim();
    }
    if (destination.toLowerCase().startsWith('to ')) {
      destination = destination.substring(3).trim();
    }
    return destination.isEmpty ? '' : 'To $destination';
  }

  String get minutesRemaining {
    if (timestamp <= 0) return 'Arriving soon';
    final secondsRemaining = DateTime.fromMillisecondsSinceEpoch(
      timestamp,
    ).difference(DateTime.now()).inSeconds;
    if (secondsRemaining <= 60) return '< 1 min';
    return '${(secondsRemaining / 60).ceil()} min away';
  }
}

class TrafficCongestion {
  const TrafficCongestion({
    required this.level,
    required this.roadLevel,
    required this.currentSpeedKph,
    required this.freeFlowSpeedKph,
    required this.delayPercent,
    this.observedUsers,
    this.capacity,
    this.stationLevel,
  });

  factory TrafficCongestion.fromJson(Map<String, dynamic> json) {
    return TrafficCongestion(
      level: json['level']?.toString() ?? 'unavailable',
      roadLevel:
          json['roadLevel']?.toString() ??
          json['level']?.toString() ??
          'unavailable',
      currentSpeedKph: (json['currentSpeedKph'] as num?)?.toDouble() ?? 0,
      freeFlowSpeedKph: (json['freeFlowSpeedKph'] as num?)?.toDouble() ?? 0,
      delayPercent: (json['delayPercent'] as num?)?.toDouble(),
      observedUsers:
          json['stationPresence'] is Map &&
              (json['stationPresence'] as Map)['observedUsers'] is num
          ? ((json['stationPresence'] as Map)['observedUsers'] as num).toInt()
          : null,
      capacity:
          json['stationPresence'] is Map &&
              (json['stationPresence'] as Map)['capacity'] is num
          ? ((json['stationPresence'] as Map)['capacity'] as num).toInt()
          : null,
      stationLevel: json['stationPresence'] is Map
          ? (json['stationPresence'] as Map)['level']?.toString()
          : null,
    );
  }

  final String level;
  final String roadLevel;
  final double currentSpeedKph;
  final double freeFlowSpeedKph;
  final double? delayPercent;
  final int? observedUsers;
  final int? capacity;
  final String? stationLevel;

  String get label {
    if (roadLevel == 'road_closed') return 'TomTom traffic: nearby road closed';
    final roadStatus = switch (roadLevel) {
      'heavy' => 'Heavy traffic',
      'moderate' => 'Moderate traffic',
      'low' => 'Light traffic',
      _ => 'Traffic unavailable',
    };
    final delay = delayPercent == null
        ? ''
        : ' • ${delayPercent!.round()}% slower';
    final presence = observedUsers == null
        ? ''
        : capacity == null
        ? ' • $observedUsers recent station users'
        : ' • Station ${stationLevel ?? 'occupancy'}: $observedUsers/$capacity';
    return 'Congestion Status: $roadStatus • ${currentSpeedKph.round()} km/h$delay$presence';
  }
}

class StationIncident {
  const StationIncident({required this.type, required this.count, this.route});

  factory StationIncident.fromJson(Map<String, dynamic> json) {
    return StationIncident(
      type: json['type']?.toString() ?? 'disruption',
      count: json['count'] is num ? (json['count'] as num).toInt() : 1,
      route: json['route']?.toString(),
    );
  }

  final String type;
  final int count;
  final String? route;

  String get label => formatIncidentLabel(type, route);
}

enum IncidentType {
  stuckTrain(
    'Stuck train for over 5 minutes',
    'A train has been stationary longer than expected.',
    Icons.train,
    false,
  ),
  crowding(
    'Crowding',
    'The platform, station or vehicle is unusually crowded.',
    Icons.groups,
    false,
  ),
  disruption(
    'Service disruption',
    'There is a delay, closure or other service issue.',
    Icons.warning_amber_rounded,
    false,
  ),
  safety(
    'Safety or accessibility issue',
    'Report a safety concern or an accessibility obstruction.',
    Icons.accessible,
    false,
  ),
  busNotArrived(
    'Bus has not arrived for over 10 minutes',
    'Report an overdue bus for the selected route.',
    Icons.schedule,
    true,
  ),
  busCrowding(
    'Bus crowding',
    'The selected bus is unusually crowded.',
    Icons.groups,
    true,
  ),
  busBreakdown(
    'Bus breakdown or service issue',
    'The selected bus is not operating normally.',
    Icons.build_circle_outlined,
    true,
  ),
  busSafety(
    'Bus safety or accessibility issue',
    'Report a safety concern or accessibility obstruction.',
    Icons.accessible,
    true,
  );

  const IncidentType(this.label, this.description, this.icon, this.isBus);

  final String label;
  final String description;
  final IconData icon;
  final bool isBus;
}