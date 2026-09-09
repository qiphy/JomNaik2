import 'package:flutter/material.dart';
import '../../models/itinerary.dart';
import '../../utils/formatters.dart';

class RouteChoicesSheet extends StatelessWidget {
  const RouteChoicesSheet({
    super.key,
    required this.itineraries,
    required this.onSelectItinerary,
  });

  final List<Map<String, dynamic>> itineraries;
  final ValueChanged<Map<String, dynamic>> onSelectItinerary;

  List<Map<String, dynamic>> _itineraryLegs(Map<String, dynamic> itinerary) {
    final rawLegs = itinerary['legs'];
    return rawLegs is List
        ? rawLegs.whereType<Map>().map(Map<String, dynamic>.from).toList()
        : const [];
  }

  String _routeOptionTitle(Map<String, dynamic> itinerary) {
    switch (itinerary['routeCategory']?.toString()) {
      case 'rail':
        return 'Mostly rail';
      case 'bus':
        return 'Mostly bus';
      case 'ehailing':
        return 'E-hailing';
    }
    final modes = _itineraryLegs(itinerary)
        .map((leg) => leg['mode']?.toString().toUpperCase())
        .toSet();
    if (modes.contains('HAIL')) return 'E-hailing';
    final hasBus = modes.contains('BUS');
    final hasRail = modes.any(
      (mode) => mode == 'RAIL' || mode == 'SUBWAY' || mode == 'TRAM',
    );
    if (hasBus && hasRail) return 'Bus & rail';
    if (hasRail) return 'Rail';
    if (hasBus) return 'Bus';
    return 'Walking';
  }

  IconData _routeOptionIcon(Map<String, dynamic> itinerary) {
    switch (_routeOptionTitle(itinerary)) {
      case 'E-hailing':
        return Icons.local_taxi;
      case 'Bus':
        return Icons.directions_bus;
      case 'Rail':
        return Icons.train;
      case 'Bus & rail':
        return Icons.directions_transit;
      default:
        return Icons.directions_walk;
    }
  }

  String _routeOptionSummary(Map<String, dynamic> itinerary) {
    final services = _itineraryLegs(itinerary)
        .where((leg) => !{'WALK', 'HAIL'}.contains(leg['mode']?.toString().toUpperCase()))
        .map((leg) => leg['routeShortName']?.toString())
        .whereType<String>()
        .where((name) => name.isNotEmpty)
        .toList();
    final sheltered = _itineraryLegs(itinerary).any(
      (leg) =>
          leg['mode']?.toString().toUpperCase() == 'WALK' &&
          leg['isSheltered'] == true,
    );
    final summary = services.isEmpty ? 'Direct journey estimate' : services.join(' → ');
    final congestion = itinerary['congestion'];
    final stationActivity = congestion is Map ? congestion['stationActivity'] : null;
    final hasBusyStation = stationActivity is List &&
        stationActivity.any((station) => station is Map && station['level'] == 'high');
    final signals = <String>[
      if (sheltered) 'Sheltered walkways',
      if (hasBusyStation) 'Busy station reported',
    ];
    return signals.isEmpty ? summary : '$summary • ${signals.join(' • ')}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Choose a route',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...itineraries.map((itinerary) {
              final option = Itinerary.fromJson(itinerary);
              return Card(
                child: ListTile(
                  leading: Icon(_routeOptionIcon(itinerary)),
                  title: Text(_routeOptionTitle(itinerary)),
                  subtitle: Text(_routeOptionSummary(itinerary)),
                  trailing: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(formatDuration(option.duration)),
                      if (fareLabel(option).isNotEmpty)
                        Text(
                          fareLabel(option),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                    ],
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    onSelectItinerary(itinerary);
                  },
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}