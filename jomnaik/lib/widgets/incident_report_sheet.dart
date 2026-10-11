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

class IncidentReportSubmission {
  const IncidentReportSubmission({
    required this.type,
    this.comment,
  });

  final IncidentType type;
  final String? comment;
}

class IncidentTypeSelectionSheet extends StatefulWidget {
  const IncidentTypeSelectionSheet({
    super.key,
    required this.isBusStop,
    required this.stopName,
    this.distance,
    this.affectedRoute,
  });

  final bool isBusStop;
  final String stopName;
  final double? distance;
  final String? affectedRoute;

  @override
  State<IncidentTypeSelectionSheet> createState() =>
      _IncidentTypeSelectionSheetState();
}

class _IncidentTypeSelectionSheetState extends State<IncidentTypeSelectionSheet> {
  final _commentController = TextEditingController();

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.isBusStop
                    ? 'Report bus ${widget.affectedRoute!}'
                    : 'Report a rail incident',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                widget.distance != null
                    ? 'Reporting for ${widget.stopName} • ${widget.distance!.round()} m away'
                    : 'Reporting for ${widget.stopName}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _commentController,
                decoration: InputDecoration(
                  labelText: 'Comments / details (optional)',
                  hintText: widget.isBusStop
                      ? 'e.g., Bus diverted via alternative route, delayed 10m'
                      : 'e.g., Train holding at station, technical issue',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Text(
                'Select incident category to submit:',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 6),
              ...IncidentType.values
                  .where((type) => type.isBus == widget.isBusStop)
                  .map(
                    (type) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(type.icon, color: Colors.red.shade700),
                      ),
                      title: Text(
                        type.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(type.description),
                      onTap: () {
                        final comment = _commentController.text.trim();
                        Navigator.of(context).pop(
                          IncidentReportSubmission(
                            type: type,
                            comment: comment.isEmpty ? null : comment,
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