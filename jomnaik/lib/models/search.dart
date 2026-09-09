class PlaceSearchResult {
  const PlaceSearchResult({
    required this.name,
    required this.address,
    required this.lat,
    required this.lon,
    this.stopId,
  });

  factory PlaceSearchResult.fromJson(Map<String, dynamic> json) {
    return PlaceSearchResult(
      name: json['name']?.toString() ?? 'Selected location',
      address: json['address']?.toString() ?? '',
      lat: json['lat'] is num ? (json['lat'] as num).toDouble() : 0,
      lon: json['lon'] is num ? (json['lon'] as num).toDouble() : 0,
      stopId: json['stop_id']?.toString(),
    );
  }

  final String name;
  final String address;
  final double lat;
  final double lon;
  final String? stopId;
}