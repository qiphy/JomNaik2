import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../models/itinerary.dart';
import '../utils/formatters.dart';

class ItinerarySheet extends StatelessWidget {
  const ItinerarySheet({
    super.key,
    required this.itinerary,
    this.initialExtent = 0.25,
    this.weatherReminder,
    required this.guidanceCard,
    required this.onDismiss,
    required this.onFindApps,
    this.onUserInteracted,
    this.onCardInteractionChanged,
  });

  final Itinerary itinerary;
  final double initialExtent;
  final String? weatherReminder;
  final Widget guidanceCard;
  final VoidCallback onDismiss;
  final VoidCallback onFindApps;
  final VoidCallback? onUserInteracted;
  final ValueChanged<bool>? onCardInteractionChanged;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: initialExtent,
      minChildSize: 0.25,
      maxChildSize: 1.0,
      builder: (BuildContext context, ScrollController scrollController) {
        return NotificationListener<DraggableScrollableNotification>(
          onNotification: (notification) {
            if ((notification.extent - initialExtent).abs() > 0.005) {
              onUserInteracted?.call();
            }
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification ||
                  notification is UserScrollNotification) {
                onCardInteractionChanged?.call(true);
                if (notification is ScrollStartNotification &&
                    notification.dragDetails != null) {
                  onUserInteracted?.call();
                }
              } else if (notification is ScrollEndNotification) {
                onCardInteractionChanged?.call(false);
              }
              return false;
            },
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => onCardInteractionChanged?.call(true),
              onPointerUp: (_) => onCardInteractionChanged?.call(false),
              onPointerCancel: (_) => onCardInteractionChanged?.call(false),
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  onCardInteractionChanged?.call(true);
                }
              },
              child: Container(
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
                  padding: EdgeInsets.zero,
                  itemCount: itinerary.legs.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
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
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
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
                                    Expanded(
                                      child: Text(weatherReminder!),
                                    ),
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
                      final walkwayLabel = leg.isSheltered
                          ? 'Covered walkway'
                          : 'Open walkway';
                      final walkPrefix = leg.isNearestStationAccess
                          ? 'Walk via nearest pedestrian road to:'
                          : leg.isTransferWalk
                          ? 'Transfer via pedestrian route to'
                          : 'Walk to';
                      return ListTile(
                        leading: Icon(
                          Icons.umbrella_outlined,
                          color: leg.isSheltered ? Colors.teal : Colors.grey,
                        ),
                        title: Text(
                          '$walkPrefix ${leg.toPlace?.name ?? 'the next stop'}',
                        ),
                        subtitle: Text(
                          '$walkwayLabel • ${leg.isNearestStationAccess ? 'Street route • ' : ''}${leg.fromPlace != null ? 'From ${leg.fromPlace!.name} • ' : ''}${formatTime(leg.startTime)} - ${formatTime(leg.endTime)}',
                        ),
                      );
                    }

                    if (isHail) {
                      final colorScheme = Theme.of(context).colorScheme;
                      return Container(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.3),
                          ),
                        ),
                        child: ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.local_taxi,
                              color: Colors.orange,
                              size: 24,
                            ),
                          ),
                          title: Text(
                            leg.routeShortName ?? 'E-hailing estimate',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${formatTime(leg.startTime)} - ${formatTime(leg.endTime)} • ${fareLabel(itinerary).isEmpty ? 'Direct distance estimate' : fareLabel(itinerary)} (RM1–RM3/km)',
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Car route • ${leg.paymentMethod ?? 'Pay in the e-hailing app'}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          trailing: FilledButton.tonalIcon(
                            onPressed: onFindApps,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            icon: const Icon(Icons.open_in_new, size: 16),
                            label: const Text('Use E-hailing'),
                          ),
                          onTap: onFindApps,
                        ),
                      );
                    }

                    return ExpansionTile(
                      leading: const Icon(
                        Icons.directions_bus,
                        color: Colors.green,
                      ),
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
                            const Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.orange,
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
                          leading: const Icon(
                            Icons.trip_origin,
                            color: Colors.green,
                          ),
                          title: Text(
                            'Board at ${leg.fromPlace?.name ?? 'the boarding stop'}',
                          ),
                        ),
                        if (leg.incidentReports.isNotEmpty)
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.orange,
                            ),
                            title: Text(
                              incidentStatusLabel(leg.incidentReports.length),
                            ),
                            subtitle: Text(
                              '${leg.incidentReports.length} report${leg.incidentReports.length == 1 ? '' : 's'} • ${leg.incidentReports.map((incident) => incident.stationName).toSet().join(', ')}',
                            ),
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
                          leading: const Icon(
                            Icons.flag,
                            color: Colors.red,
                          ),
                          title: Text(
                            'Alight at ${leg.toPlace?.name ?? 'your destination'}',
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}