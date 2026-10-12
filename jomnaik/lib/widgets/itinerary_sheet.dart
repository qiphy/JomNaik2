import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../models/itinerary.dart';
import '../utils/formatters.dart';

class ItinerarySheet extends StatefulWidget {
  const ItinerarySheet({
    super.key,
    required this.itinerary,
    this.initialExtent = 0.40,
    this.weatherReminder,
    required this.guidanceCard,
    required this.onDismiss,
    required this.onFindApps,
    this.onOpenGrab,
    this.onUserInteracted,
    this.onCardInteractionChanged,
    this.onExpandedChanged,
  });

  final Itinerary itinerary;
  final double initialExtent;
  final String? weatherReminder;
  final Widget guidanceCard;
  final VoidCallback onDismiss;
  final VoidCallback onFindApps;
  final void Function(ItineraryLeg leg)? onOpenGrab;
  final VoidCallback? onUserInteracted;
  final ValueChanged<bool>? onCardInteractionChanged;
  final ValueChanged<bool>? onExpandedChanged;

  @override
  State<ItinerarySheet> createState() => _ItinerarySheetState();
}

class _ItinerarySheetState extends State<ItinerarySheet> {
  late final DraggableScrollableController _sheetController;
  static const double _minExtent = 0.10;
  static const double _maxExtent = 0.95;

  @override
  void initState() {
    super.initState();
    _sheetController = DraggableScrollableController();
  }

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  void _toggleExpand() {
    if (!_sheetController.isAttached) return;
    final current = _sheetController.size;
    if (current < 0.25) {
      _sheetController.animateTo(
        widget.initialExtent,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else if (current < 0.70) {
      _sheetController.animateTo(
        _maxExtent,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      _sheetController.animateTo(
        _minExtent,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: widget.initialExtent,
      minChildSize: _minExtent,
      maxChildSize: _maxExtent,
      builder: (BuildContext context, ScrollController scrollController) {
        return NotificationListener<DraggableScrollableNotification>(
          onNotification: (notification) {
            final isExpanded = notification.extent >= 0.65;
            widget.onExpandedChanged?.call(isExpanded);
            if ((notification.extent - widget.initialExtent).abs() > 0.005) {
              widget.onUserInteracted?.call();
            }
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification ||
                  notification is UserScrollNotification) {
                widget.onCardInteractionChanged?.call(true);
                if (notification is ScrollStartNotification &&
                    notification.dragDetails != null) {
                  widget.onUserInteracted?.call();
                }
              } else if (notification is ScrollEndNotification) {
                widget.onCardInteractionChanged?.call(false);
              }
              return false;
            },
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => widget.onCardInteractionChanged?.call(true),
              onPointerUp: (_) => widget.onCardInteractionChanged?.call(false),
              onPointerCancel: (_) =>
                  widget.onCardInteractionChanged?.call(false),
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  widget.onCardInteractionChanged?.call(true);
                }
              },
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(22),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 16,
                      spreadRadius: 2,
                      offset: const Offset(0, -3),
                    ),
                  ],
                ),
                child: ListView.builder(
                  controller: scrollController,
                  padding: EdgeInsets.zero,
                  physics: const ClampingScrollPhysics(),
                  itemCount: widget.itinerary.legs.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _toggleExpand,
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                alignment: Alignment.center,
                                child: Container(
                                  width: 48,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: colorScheme.outlineVariant,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Total Travel Time: ${formatDuration(widget.itinerary.duration)}',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Close itinerary',
                                  icon: const Icon(Icons.close),
                                  onPressed: widget.onDismiss,
                                ),
                              ],
                            ),
                            if (widget.itinerary.fareAmount != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '${widget.itinerary.fareLabel ?? 'Estimated fare'}: ${fareLabel(widget.itinerary)}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: colorScheme.primary,
                                  ),
                                ),
                              ),
                            if (widget.weatherReminder != null) ...[
                              const SizedBox(height: 8),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: colorScheme.primaryContainer
                                      .withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.umbrella_outlined,
                                      color: colorScheme.primary,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(widget.weatherReminder!),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            widget.guidanceCard,
                          ],
                        ),
                      );
                    }

                    final leg = widget.itinerary.legs[index - 1];
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
                          color: colorScheme.surfaceContainerHighest.withValues(
                            alpha: 0.5,
                          ),
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
                                  '${formatTime(leg.startTime)} - ${formatTime(leg.endTime)} • ${fareLabel(widget.itinerary).isEmpty ? 'Direct distance estimate' : fareLabel(widget.itinerary)} (RM1–RM3/km)',
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
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FilledButton.icon(
                                onPressed: () {
                                  if (widget.onOpenGrab != null) {
                                    widget.onOpenGrab!(leg);
                                  } else {
                                    widget.onFindApps();
                                  }
                                },
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFF00B14F),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                ),
                                icon: const Icon(Icons.local_taxi, size: 16),
                                label: const Text('Grab'),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.more_vert, size: 20),
                                tooltip: 'More e-hailing options',
                                onPressed: widget.onFindApps,
                              ),
                            ],
                          ),
                          onTap: () {
                            if (widget.onOpenGrab != null) {
                              widget.onOpenGrab!(leg);
                            } else {
                              widget.onFindApps();
                            }
                          },
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
                            leg.terminalDirection,
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
                          Text(
                            'Board at ${leg.fromPlace?.name ?? 'the boarding stop'}',
                          ),
                          Text(
                            '• Alight at ${leg.toPlace?.name ?? 'your destination'}',
                          ),
                          Text(
                            'Depart ${formatTime(leg.startTime)} • Arrive ${formatTime(leg.endTime)}',
                          ),
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
                          leading: const Icon(Icons.flag, color: Colors.red),
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
