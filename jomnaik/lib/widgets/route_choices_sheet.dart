import 'package:flutter/material.dart';
import '../../models/itinerary.dart';
import '../../utils/formatters.dart';

class RouteChoicesSheet extends StatelessWidget {
  const RouteChoicesSheet({
    super.key,
    required this.itineraries,
    required this.onSelectItinerary,
    this.routesUpdated = false,
  });

  final List<Map<String, dynamic>> itineraries;
  final ValueChanged<Map<String, dynamic>> onSelectItinerary;
  final bool routesUpdated;

  List<Map<String, dynamic>> _itineraryLegs(Map<String, dynamic> itinerary) {
    final rawLegs = itinerary['legs'];
    return rawLegs is List
        ? rawLegs.whereType<Map>().map(Map<String, dynamic>.from).toList()
        : const [];
  }

  String _routeOptionTitle(Map<String, dynamic> itinerary) {
    final category = itinerary['routeCategory']?.toString().toLowerCase();
    switch (category) {
      case 'ehailing':
        return 'E-hailing';
      case 'hybrid':
        return 'Hybrid';
      case 'walking':
      case 'walk':
        return 'Walking';
    }

    final legs = _itineraryLegs(itinerary);
    final modes = legs
        .map((leg) => leg['mode']?.toString().toUpperCase())
        .toSet();
    final hasHailing = modes.contains('HAIL');
    final hasBus = modes.contains('BUS');
    final hasRail = modes.any(
      (mode) => mode == 'RAIL' || mode == 'SUBWAY' || mode == 'TRAM',
    );
    if (hasHailing && (hasBus || hasRail)) return 'Hybrid';
    if (hasHailing) return 'E-hailing';
    if (hasBus && hasRail) {
      double legSeconds(Map<String, dynamic> leg) {
        final duration = leg['duration'];
        if (duration is num && duration > 0) return duration.toDouble();
        final start = DateTime.tryParse(leg['startTime']?.toString() ?? '');
        final end = DateTime.tryParse(leg['endTime']?.toString() ?? '');
        return start != null && end != null && end.isAfter(start)
            ? end.difference(start).inSeconds.toDouble()
            : 0;
      }

      final busSeconds = legs
          .where((leg) => leg['mode']?.toString().toUpperCase() == 'BUS')
          .fold<double>(0, (total, leg) => total + legSeconds(leg));
      final railSeconds = legs
          .where(
            (leg) => {
              'RAIL',
              'SUBWAY',
              'TRAM',
            }.contains(leg['mode']?.toString().toUpperCase()),
          )
          .fold<double>(0, (total, leg) => total + legSeconds(leg));
      return busSeconds > railSeconds ? 'Mostly bus' : 'Mostly rail';
    }
    if (hasRail) return 'Mostly rail';
    if (hasBus) return 'Mostly bus';
    if (category == 'rail') return 'Mostly rail';
    if (category == 'bus') return 'Mostly bus';
    return 'Walking';
  }

  IconData _routeOptionIcon(Map<String, dynamic> itinerary) {
    switch (_routeOptionTitle(itinerary)) {
      case 'E-hailing':
        return Icons.local_taxi;
      case 'Hybrid':
        return Icons.alt_route;
      case 'Mostly bus':
        return Icons.directions_bus;
      case 'Mostly rail':
        return Icons.train;
      default:
        return Icons.directions_walk;
    }
  }

  String _routeOptionSummary(Map<String, dynamic> itinerary) {
    final steps = _itineraryLegs(itinerary)
        .where(
          (leg) =>
              leg['mode']?.toString().toUpperCase() != 'WALK' ||
              leg['isTransferWalk'] != true,
        )
        .map((leg) {
          final mode = leg['mode']?.toString().toUpperCase();
          if (mode == 'WALK') return 'Walk';
          if (mode == 'HAIL') return 'E-hailing';
          return leg['routeShortName']?.toString() ?? mode;
        })
        .whereType<String>()
        .where((step) => step.isNotEmpty)
        .toList();
    final sheltered = _itineraryLegs(itinerary).any(
      (leg) =>
          leg['mode']?.toString().toUpperCase() == 'WALK' &&
          leg['isSheltered'] == true,
    );
    final summary = steps.isEmpty
        ? 'Direct journey estimate'
        : steps.join(' → ');
    final congestion = itinerary['congestion'];
    final stationActivity = congestion is Map
        ? congestion['stationActivity']
        : null;
    final hasBusyStation =
        stationActivity is List &&
        stationActivity.any(
          (station) => station is Map && station['level'] == 'high',
        );
    final signals = <String>[
      if (sheltered) 'Sheltered walkways',
      if (hasBusyStation) 'Busy station reported',
    ];
    return signals.isEmpty ? summary : '$summary • ${signals.join(' • ')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final routeOptions = itineraries;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;
    final hasTransit = routeOptions.any((it) {
      final rawLegs = it['legs'];
      if (rawLegs is! List) return false;
      return rawLegs.any((leg) {
        if (leg is! Map) return false;
        final mode = leg['mode']?.toString().toUpperCase();
        return mode != null && mode != 'WALK' && mode != 'HAIL';
      });
    });

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Choose a route',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${routeOptions.length} options available',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              if (routesUpdated) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.update,
                        size: 18,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Routes updated with the latest live bus data.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (!hasTransit)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiaryContainer.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: theme.colorScheme.tertiary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.schedule,
                        color: theme.colorScheme.tertiary,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Public transit is not running at this departure time. Showing available alternatives like e-hailing and walking.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onTertiaryContainer,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  physics: const BouncingScrollPhysics(),
                  itemCount: routeOptions.length,
                  itemBuilder: (context, index) {
                    final itinerary = routeOptions[index];
                    final option = Itinerary.fromJson(itinerary);
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      elevation: 1,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer
                                .withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            _routeOptionIcon(itinerary),
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        title: Row(
                          children: [
                            Text(
                              _routeOptionTitle(itinerary),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (option.legs.any(
                              (leg) => leg.incidentReports.isNotEmpty,
                            )) ...[
                              const SizedBox(width: 6),
                              Tooltip(
                                message: 'Service alerts reported',
                                child: Icon(
                                  Icons.warning_amber_rounded,
                                  color: Colors.amber.shade800,
                                  size: 18,
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(_routeOptionSummary(itinerary)),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              formatDuration(option.duration),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (fareLabel(option).isNotEmpty)
                              Text(
                                fareLabel(option),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ],
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          onSelectItinerary(itinerary);
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
