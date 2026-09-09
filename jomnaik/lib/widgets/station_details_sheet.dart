import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/transit.dart';

class StationDetailsSheet extends StatefulWidget {
  const StationDetailsSheet({
    super.key,
    required this.stopId,
    required this.stopName,
    required this.routes,
    required this.transitType,
    this.stop,
    required this.onGetDirections,
    required this.fetchDepartures,
    required this.fetchCongestion,
    required this.fetchIncidents,
  });

  final String stopId;
  final String stopName;
  final String routes;
  final String transitType;
  final TransitStop? stop;
  final VoidCallback onGetDirections;
  final Future<List<StopDeparture>> Function() fetchDepartures;
  final Future<TrafficCongestion?> Function() fetchCongestion;
  final Future<List<StationIncident>> Function() fetchIncidents;

  @override
  State<StationDetailsSheet> createState() => _StationDetailsSheetState();
}

class _StationDetailsSheetState extends State<StationDetailsSheet> {
  late Future<List<StopDeparture>> _departureFuture;
  late Future<TrafficCongestion?> _congestionFuture;
  late Future<List<StationIncident>> _incidentsFuture;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadData();
    // GTFS-Realtime vehicle positions are refreshed by the backend's
    // 20-second cache. Poll while this stop sheet is visible so live
    // estimates update without requiring the user to close and reopen it.
    _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) {
        setState(() {
          _departureFuture = widget.fetchDepartures();
          _congestionFuture = widget.fetchCongestion();
        });
      }
    });
  }

  void _loadData() {
    _departureFuture = widget.fetchDepartures();
    _congestionFuture = widget.fetchCongestion();
    _incidentsFuture = widget.fetchIncidents();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Widget _buildCongestionIndicator(TrafficCongestion congestion) {
    final color = switch (congestion.level) {
      'road_closed' || 'heavy' => Colors.red,
      'moderate' => Colors.orange,
      _ => Colors.green,
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, color: color, size: 12),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              congestion.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.stopName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '${widget.transitType == 'rail' ? 'Rail station' : 'Bus stop'} routes',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: widget.stop == null ? null : widget.onGetDirections,
                  icon: const Icon(Icons.directions),
                  label: const Text('Directions'),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: widget.routes
                      .split(', ')
                      .map((route) => Chip(label: Text(route)))
                      .toList(),
                ),
                const SizedBox(height: 24),
                FutureBuilder<List<StationIncident>>(
                  future: _incidentsFuture,
                  builder: (context, snapshot) {
                    final currentIncidents = snapshot.data ?? const [];
                    if (currentIncidents.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 20),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                color: Colors.orange,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Recent reports',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ...currentIncidents.map(
                            (incident) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '• ${incident.label}${incident.count > 1 ? ' (${incident.count})' : ''}',
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                FutureBuilder<TrafficCongestion?>(
                  future: _congestionFuture,
                  builder: (context, snapshot) {
                    final congestion = snapshot.data;
                    return congestion == null
                        ? const SizedBox.shrink()
                        : _buildCongestionIndicator(congestion);
                  },
                ),
                Text(
                  'Next departures',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                FutureBuilder<List<StopDeparture>>(
                  future: _departureFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text('Departure times are unavailable.'),
                            ),
                            TextButton.icon(
                              onPressed: () => setState(() => _loadData()),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry'),
                            ),
                          ],
                        ),
                      );
                    }

                    final nextDepartures = snapshot.data ?? const [];
                    if (nextDepartures.isEmpty) {
                      return const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text('No upcoming scheduled departures.'),
                          ),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        ...nextDepartures.map(
                          (departure) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.schedule),
                            title: Text(
                              departure.displayDirection.isNotEmpty
                                  ? departure.displayDirection
                                  : departure.route,
                            ),
                            subtitle: Text(
                              [
                                if (departure.displayDirection.isNotEmpty)
                                  departure.route,
                                departure.isEstimated
                                    ? 'Live vehicle estimate'
                                    : 'Scheduled time',
                              ].join(' • '),
                            ),
                            trailing: departure.isEstimated
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.blue.shade50,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          departure.minutesRemaining,
                                          style: TextStyle(
                                            color: Colors.blue.shade800,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                : Text(
                                    departure.time,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}