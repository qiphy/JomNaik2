import 'package:flutter/material.dart';
import '../../models/transit.dart';

class BusRouteSelectionSheet extends StatelessWidget {
  const BusRouteSelectionSheet({
    super.key,
    required this.routes,
  });

  final List<String> routes;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Which bus is affected?',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            ...routes.map(
              (route) => ListTile(
                leading: const Icon(Icons.directions_bus),
                title: Text('Bus $route'),
                onTap: () => Navigator.of(context).pop(route),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class IncidentTypeSelectionSheet extends StatelessWidget {
  const IncidentTypeSelectionSheet({
    super.key,
    required this.isBusStop,
    required this.stopName,
    required this.distance,
    this.affectedRoute,
  });

  final bool isBusStop;
  final String stopName;
  final double distance;
  final String? affectedRoute;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isBusStop
                  ? 'Report bus ${affectedRoute!}'
                  : 'Report a rail incident',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text('Reporting for $stopName • ${distance.round()} m away'),
            const SizedBox(height: 12),
            ...IncidentType.values
                .where((type) => type.isBus == isBusStop)
                .map(
                  (type) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(type.icon, color: Colors.red.shade700),
                    title: Text(type.label),
                    subtitle: Text(type.description),
                    onTap: () => Navigator.of(context).pop(type),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}