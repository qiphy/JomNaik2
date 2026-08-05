import 'package:flutter/material.dart';

class LiveGuidanceCard extends StatelessWidget {
  const LiveGuidanceCard({
    super.key,
    required this.isActive,
    required this.hasCurrentStep,
    required this.currentStep,
    required this.totalSteps,
    required this.message,
    required this.showBoardedAction,
    required this.isReplanning,
    required this.isCompleted,
    required this.completedTrips,
    required this.onStart,
    required this.onBoarded,
    required this.onReplan,
    required this.onStop,
  });

  final bool isActive;
  final bool hasCurrentStep;
  final int currentStep;
  final int totalSteps;
  final String message;
  final bool showBoardedAction;
  final bool isReplanning;
  final bool isCompleted;
  final int completedTrips;
  final VoidCallback onStart;
  final VoidCallback onBoarded;
  final VoidCallback onReplan;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Card(
    color: isActive ? const Color(0xFFE8F2FF) : null,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isCompleted
                    ? Icons.check_circle_outline
                    : isActive
                    ? Icons.navigation
                    : Icons.navigation_outlined,
                color: Colors.blue[800],
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isCompleted
                      ? 'Trip completed'
                      : isActive
                      ? hasCurrentStep
                            ? 'Live guidance • Step $currentStep of $totalSteps'
                            : 'Live guidance complete'
                      : 'Live journey guidance',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(message),
          if (isCompleted && completedTrips > 0) ...[
            const SizedBox(height: 4),
            Text(
              '$completedTrips completed ${completedTrips == 1 ? 'trip' : 'trips'} saved on this device.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!isActive && !isCompleted)
                FilledButton.icon(
                  onPressed: onStart,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start guidance'),
                ),
              if (isActive && showBoardedAction)
                FilledButton.icon(
                  onPressed: onBoarded,
                  icon: const Icon(Icons.directions_bus),
                  label: const Text('I have boarded'),
                ),
              if (isActive)
                OutlinedButton.icon(
                  onPressed: isReplanning ? null : onReplan,
                  icon: isReplanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.alt_route),
                  label: const Text('Replan from here'),
                ),
              if (isActive)
                TextButton(onPressed: onStop, child: const Text('Stop')),
            ],
          ),
        ],
      ),
    ),
  );
}
