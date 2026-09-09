import 'package:flutter/material.dart';
import '../models/itinerary.dart';
import '../utils/formatters.dart';

class ItinerarySheet extends StatelessWidget {
  const ItinerarySheet({
    super.key,
    required this.itinerary,
    this.weatherReminder,
    required this.guidanceCard,
    required this.onDismiss,
    required this.onFindApps,
    required this.onShowLegIncidents,
  });

  final Itinerary itinerary;
  final String? weatherReminder;
  final Widget guidanceCard;
  final VoidCallback onDismiss;
  final VoidCallback onFindApps;
  final ValueChanged<ItineraryLeg> onShowLegIncidents;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.25,
      minChildSize: 0.15,
      maxChildSize: 0.6,
      builder: (BuildContext context, ScrollController scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 10,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ListView.builder(
            controller: scrollController,
            itemCount: itinerary.legs.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                // Header Summary Card
                return Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Total Travel Time: ${formatDuration(itinerary.duration)}',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close itinerary',
                            icon: const Icon(Icons.close),
                            onPressed: onDismiss,
                          ),
                        ],
                      ),
                      if (itinerary.fareAmount != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${itinerary.fareLabel ?? 'Estimated fare'}: ${fareLabel(itinerary)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      if (itinerary.fallbackMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          itinerary.fallbackMessage!,
                          style: TextStyle(color: Colors.orange[800]),
                        ),
                      ],
                      if (weatherReminder != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.umbrella_outlined,
                                color: Colors.blue,
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: Text(weatherReminder!)),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      guidanceCard,
                    ],
                  ),
                );
              }

              final leg = itinerary.legs[index - 1];
              final isWalk = leg.mode.toUpperCase() == 'WALK';
              final isHail = leg.mode.toUpperCase() == 'HAIL';

              if (isWalk) {
                final walkwayLabel = leg.isSheltered ? 'Covered walkway' : 'Open walkway';
                return ListTile(
                  leading: Icon(
                    Icons.umbrella_outlined,
                    color: leg.isSheltered ? Colors.teal : Colors.grey,
                  ),
                  title: Text(
                    '${leg.isNearestStationAccess ? 'Walk via nearest pedestrian road to:' : leg.isTransferWalk ? 'Transfer via pedestrian route to' : 'Walk to'} ${leg.toPlace?.name ?? 'the next stop'}',
                  ),
                  subtitle: Text(
                    '$walkwayLabel • ${leg.isNearestStationAccess ? 'Street route • ' : ''}${leg.fromPlace != null ? 'From ${leg.fromPlace!.name} • ' : ''}${formatTime(leg.startTime)} - ${formatTime(leg.endTime)}',
                  ),
                );
              }

              if (isHail) {
                return ListTile(
                  leading: const Icon(Icons.local_taxi, color: Colors.orange),
                  title: Text(
                    leg.routeShortName ?? 'E-hailing estimate',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    '${formatTime(leg.startTime)} - ${formatTime(leg.endTime)} • ${itinerary.fareAmount == null ? 'Direct distance estimate' : fareLabel(itinerary)} planning estimate (excludes surge and tolls)\nPayment: ${leg.paymentMethod ?? 'Pay in the e-hailing app'}',
                  ),
                  trailing: TextButton.icon(
                    onPressed: onFindApps,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Find apps'),
                  ),
                );
              }

              return ExpansionTile(
                leading: const Icon(Icons.directions_bus, color: Colors.green),
                title: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    Text(
                      leg.routeShortName?.trim().isNotEmpty == true
                          ? leg.routeShortName!
                          : 'Bus',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '→ ${leg.headsign ?? 'Direction'}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (leg.incidentReports.isNotEmpty)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'View recent reports',
                        icon: const Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.orange,
                        ),
                        onPressed: () => onShowLegIncidents(leg),
                      ),
                  ],
                ),
                subtitle: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text('Board at ${leg.fromPlace?.name ?? 'the boarding stop'}'),
                    Text('• Alight at ${leg.toPlace?.name ?? 'your destination'}'),
                    Text('Depart ${formatTime(leg.startTime)} • Arrive ${formatTime(leg.endTime)}'),
                    if (leg.paymentMethod != null)
                      Text('• Payment: ${leg.paymentMethod}'),
                    if (leg.liveBusEstimate != null)
                      Text(
                        'Live arrival: ${leg.liveBusEstimate!.minutesRemaining}${leg.liveBusEstimate!.trafficAdjusted ? ' • Traffic adjusted' : ''}',
                        style: const TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
                children: [
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.trip_origin, color: Colors.green),
                    title: Text('Board at ${leg.fromPlace?.name ?? 'the boarding stop'}'),
                  ),
                  if (leg.intermediateStops.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(72, 0, 16, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('No intermediate stops provided.'),
                      ),
                    ),
                  ...leg.intermediateStops.asMap().entries.map((entry) {
                    final index = entry.key;
                    final stop = entry.value;
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 14,
                        child: Text('${index + 1}'),
                      ),
                      title: Text(stop.name),
                    );
                  }),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.flag, color: Colors.red),
                    title: Text('Alight at ${leg.toPlace?.name ?? 'your destination'}'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}