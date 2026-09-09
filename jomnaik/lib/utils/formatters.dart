import '../models/itinerary.dart';

String formatDuration(num seconds) {
  final totalMinutes = (seconds / 60).round();
  final hours = totalMinutes ~/ 60;
  final minutes = totalMinutes % 60;
  if (hours == 0) return '$minutes min';
  if (minutes == 0) return '${hours}h';
  return '${hours}h ${minutes}m';
}

String fareLabel(Itinerary itinerary) {
  final fare = itinerary.fareAmount;
  return fare == null ? '' : 'RM${fare.toStringAsFixed(2)}';
}

String formatTime(String rawTimestamp) {
  if (rawTimestamp.isEmpty) return '--:--';

  final int? milliseconds = int.tryParse(rawTimestamp);
  final DateTime? parsedTime = milliseconds == null
      ? DateTime.tryParse(rawTimestamp)
      : DateTime.fromMillisecondsSinceEpoch(milliseconds);
  if (parsedTime == null) return '--:--';

  final localTime = parsedTime.toLocal();

  final int hour = localTime.hour == 0
      ? 12
      : (localTime.hour > 12 ? localTime.hour - 12 : localTime.hour);
  final String minute = localTime.minute.toString().padLeft(2, '0');
  final String period = localTime.hour >= 12 ? 'PM' : 'AM';

  return '$hour:$minute $period';
}

/// Decodes a Google Encoded Polyline string into a list of [longitude, latitude] pairs for MapLibre.
List<List<double>> decodeEncodedPolyline(String encoded) {
  final List<List<double>> poly = [];
  int index = 0, len = encoded.length;
  int lat = 0, lng = 0;

  while (index < len) {
    int b, shift = 0, result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lat += dlat;

    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lng += dlng;

    // MapLibre uses [longitude, latitude] order
    poly.add([lng / 1E5, lat / 1E5]);
  }
  return poly;
}