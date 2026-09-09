import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/itinerary.dart';
import '../services/routing_service.dart';

class JourneyGuidanceController extends ChangeNotifier {
  JourneyGuidanceController({
    required this.routingService,
    required this.onMessage,
    required this.onJourneyCompleted,
  });

  final RoutingService routingService;
  final void Function(String) onMessage;
  final Future<void> Function(Itinerary) onJourneyCompleted;

  Itinerary? _itinerary;
  bool _isActive = false;
  int _guidedLegIndex = 0;
  bool _hasBoardedTransit = false;
  bool _isReplanning = false;
  bool _hasCompleted = false;
  String? _message;
  double? _distanceMeters;
  Position? _lastPosition;

  // --- Getters ---
  Itinerary? get itinerary => _itinerary;
  bool get isActive => _isActive;
  int get guidedLegIndex => _guidedLegIndex;
  bool get hasBoardedTransit => _hasBoardedTransit;
  bool get isReplanning => _isReplanning;
  bool get hasCompleted => _hasCompleted;
  String? get message => _message;
  double? get distanceMeters => _distanceMeters;

  void setItinerary(Itinerary? itinerary) {
    _itinerary = itinerary;
    _isActive = false;
    _hasCompleted = false;
    _guidedLegIndex = 0;
    _hasBoardedTransit = false;
    _message = null;
    _distanceMeters = null;
    notifyListeners();
  }

  Future<void> startGuidance(Position? currentPosition) async {
    if (_itinerary == null || _itinerary!.legs.isEmpty) return;

    if (_isDirectEhailingItinerary(_itinerary!)) {
      onMessage('E-hailing is booked and tracked in your chosen app.');
      return;
    }

    if (currentPosition == null) {
      onMessage('Location is required to start live journey guidance.');
      return;
    }

    _isActive = true;
    _hasCompleted = false;
    _guidedLegIndex = 0;
    _hasBoardedTransit = false;
    _message = 'Finding your first step…';
    notifyListeners();

    updatePosition(currentPosition);
  }

  void stopGuidance() {
    _isActive = false;
    _hasBoardedTransit = false;
    _message = 'Live guidance stopped.';
    _distanceMeters = null;
    notifyListeners();
  }

  void updatePosition(Position position) {
    _lastPosition = position;
    if (!_isActive || _itinerary == null) return;
    if (_guidedLegIndex >= _itinerary!.legs.length) return;

    final leg = _itinerary!.legs[_guidedLegIndex];
    final target = _guidanceTarget(leg);

    if (target?.lat == null || target?.lon == null) {
      _message = 'Follow the itinerary details for this step.';
      _distanceMeters = null;
      notifyListeners();
      return;
    }

    final distance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      target!.lat!,
      target.lon!,
    );

    final arrivalRadius = _isTransitLeg(leg) ? 90.0 : 55.0;

    if (distance <= arrivalRadius) {
      if (_isTransitLeg(leg) && !_hasBoardedTransit) {
        _distanceMeters = distance;
        _message = 'At ${target.name}. Board ${leg.routeShortName ?? 'the service'} toward ${leg.headsign ?? leg.toPlace?.name ?? 'your destination'}.';
        notifyListeners();
        return;
      }
      _completeCurrentLeg();
      return;
    }

    final action = _isTransitLeg(leg) && !_hasBoardedTransit
        ? 'Go to ${target.name}'
        : leg.mode.toUpperCase() == 'HAIL'
            ? 'Ride to ${target.name}'
            : 'Continue to ${target.name}';

    _distanceMeters = distance;
    _message = '$action • ${_formatDistance(distance)} remaining';
    notifyListeners();
  }

  void markTransitBoarded() {
    if (_itinerary == null || _guidedLegIndex >= _itinerary!.legs.length) return;
    
    final leg = _itinerary!.legs[_guidedLegIndex];
    if (!_isTransitLeg(leg)) return;

    _hasBoardedTransit = true;
    _message = 'On board ${leg.routeShortName ?? 'the service'}. Alight at ${leg.toPlace?.name ?? 'the next stop'}.';
    _distanceMeters = null;
    notifyListeners();

    if (_lastPosition != null) updatePosition(_lastPosition!);
  }

  void _completeCurrentLeg() {
    if (_itinerary == null) return;
    final nextIndex = _guidedLegIndex + 1;

    if (nextIndex >= _itinerary!.legs.length) {
      _guidedLegIndex = nextIndex;
      _isActive = false;
      _hasCompleted = true;
      _hasBoardedTransit = false;
      _distanceMeters = 0;
      _message = 'You have arrived at your destination.';
      notifyListeners();
      
      onJourneyCompleted(_itinerary!);
      return;
    }

    _guidedLegIndex = nextIndex;
    _hasBoardedTransit = false;
    _distanceMeters = null;
    _message = 'Next step ready.';
    notifyListeners();

    if (_lastPosition != null) updatePosition(_lastPosition!);
  }

  Future<void> replanJourney() async {
    if (_isReplanning || _lastPosition == null || _itinerary == null) return;

    final destination = _itinerary!.legs.isNotEmpty
        ? _itinerary!.legs.last.toPlace
        : null;

    if (destination?.lat == null || destination?.lon == null) {
      onMessage('The destination has no map coordinates to replan from.');
      return;
    }

    _isReplanning = true;
    notifyListeners();

    try {
      final routeData = await routingService.getRoute(
        fromLat: _lastPosition!.latitude,
        fromLon: _lastPosition!.longitude,
        toLat: destination!.lat!,
        toLon: destination.lon!,
        onMessage: onMessage,
      );

      final itineraries = routeData?['itineraries'];
      final first = itineraries is List &&
              itineraries.isNotEmpty &&
              itineraries.first is Map
          ? Map<String, dynamic>.from(itineraries.first as Map)
          : null;

      if (first != null) {
        setItinerary(Itinerary.fromJson(first));
        await startGuidance(_lastPosition);
      }
    } finally {
      _isReplanning = false;
      notifyListeners();
    }
  }

  // --- Helpers ---
  bool _isTransitLeg(ItineraryLeg leg) {
    final mode = leg.mode.toUpperCase();
    return mode != 'WALK' && mode != 'HAIL';
  }

  bool _isDirectEhailingItinerary(Itinerary itinerary) =>
      itinerary.legs.isNotEmpty &&
      itinerary.legs.every((leg) => leg.mode.toUpperCase() == 'HAIL');

  ItineraryPlace? _guidanceTarget(ItineraryLeg leg) =>
      _isTransitLeg(leg) && !_hasBoardedTransit ? leg.fromPlace : leg.toPlace;

  String _formatDistance(double meters) => meters >= 1000
      ? '${(meters / 1000).toStringAsFixed(1)} km'
      : '${meters.round()} m';
}