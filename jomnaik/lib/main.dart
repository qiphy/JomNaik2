import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:math' show Point;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'backend_client.dart';
import 'map_tiles_source.dart';
import 'widgets/live_guidance_card.dart';
import 'offline_raptor_router.dart';
import 'widgets/privacy_policy_screen.dart';

const _configuredGtfsBackendBaseUrl = String.fromEnvironment(
  'GTFS_BACKEND_URL',
);
// Kept for compatibility with existing build commands.
const _legacyConfiguredBackendBaseUrl = String.fromEnvironment('BACKEND_URL');
const _supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://wbxsihlvfsafpcqfblng.supabase.co',
);
const _supabasePublishableKey = String.fromEnvironment(
  'SUPABASE_PUBLISHABLE_KEY',
  defaultValue:
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndieHNpaGx2ZnNhZnBjcWZibG5nIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQyNjE5ODIsImV4cCI6MjA5OTgzNzk4Mn0.kJ9rlyB0rTrx1hEvCvLteAKgHQheGEDbFspVaXN9OK4',
);
const _privacyPolicyVersion = '2026-08-04-v3';
const _privacyPolicyEffectiveDate = '4 August 2026';
const _privacyPolicyConsentKey = 'privacy_policy_consent_version';
const _privacyPolicyAcceptedAtKey = 'privacy_policy_accepted_at';
const _completedJourneysKey = 'completed_journeys_v1';
const _completedJourneyLimit = 20;
const _privacyStorage = FlutterSecureStorage();

bool get _isSupabaseConfigured =>
    _supabaseUrl.isNotEmpty && _supabasePublishableKey.isNotEmpty;

String get _backendBaseUrl {
  if (_configuredGtfsBackendBaseUrl.isNotEmpty) {
    return _configuredGtfsBackendBaseUrl;
  }
  if (_legacyConfiguredBackendBaseUrl.isNotEmpty) {
    return _legacyConfiguredBackendBaseUrl;
  }

  // A physical device needs the computer's LAN address, supplied through
  // GTFS_BACKEND_URL. These defaults cover the local web and Android emulator
  // development workflows without pointing the client at the unusable 0.0.0.0.
  if (kIsWeb) return 'http://localhost:8000';
  if (defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:8000';
  }
  return 'http://127.0.0.1:8000';
}

Future<void> _savePrivacyConsent() async {
  await _privacyStorage.write(
    key: _privacyPolicyConsentKey,
    value: _privacyPolicyVersion,
  );
  await _privacyStorage.write(
    key: _privacyPolicyAcceptedAtKey,
    value: DateTime.now().toUtc().toIso8601String(),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_isSupabaseConfigured) {
    await Supabase.initialize(
      url: _supabaseUrl,
      publishableKey: _supabasePublishableKey,
    );
  }
  runApp(const JomNaikApp());
}

class JomNaikApp extends StatelessWidget {
  const JomNaikApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(title: 'JomNaik Map', home: _StartupScreen());
  }
}

class _StartupScreen extends StatefulWidget {
  const _StartupScreen();

  @override
  State<_StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<_StartupScreen> {
  Timer? _startupTimer;

  @override
  void initState() {
    super.initState();
    _startupTimer = Timer(const Duration(milliseconds: 1600), () {
      unawaited(_continueAfterSplash());
    });
  }

  Future<void> _continueAfterSplash() async {
    final acceptedVersion = await _privacyStorage.read(
      key: _privacyPolicyConsentKey,
    );
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => acceptedVersion == _privacyPolicyVersion
            ? const MapView()
            : PrivacyPolicyScreen(
                effectiveDate: _privacyPolicyEffectiveDate,
                onSaveConsent: _savePrivacyConsent,
                homeBuilder: (_) => const MapView(),
              ),
      ),
    );
  }

  @override
  void dispose() {
    _startupTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [Image.asset('assets/logo.png', width: 220, height: 220)],
        ),
      ),
    );
  }
}

class MapView extends StatefulWidget {
  const MapView({super.key});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  static const _currentRegion = 'Klang Valley';
  // Bounds read from assets/tiles/klang_valley.pmtiles. Keep route requests
  // within the offline map coverage rather than showing a blank map area.
  static const _tileSouth = 2.700000;
  static const _tileNorth = 3.450000;
  static const _tileWest = 101.200000;
  static const _tileEast = 101.950000;
  MapLibreMapController? _mapController;
  // MapLibre owns a native platform view. A stale asynchronous map setup can
  // otherwise try to update a controller after the view has been detached
  // (for example after a full rebuild or changing tabs).
  int _mapGeneration = 0;
  final http.Client _httpClient = http.Client();
  String? _dynamicStyleString;
  Itinerary? _currentItinerary;
  final _offlineRaptorRouter = OfflineRaptorRouter();
  bool _isJourneyGuidanceActive = false;
  int _guidedLegIndex = 0;
  bool _hasBoardedGuidedTransit = false;
  bool _isGuidanceReplanning = false;
  bool _hasCompletedCurrentJourney = false;
  int _completedJourneyCount = 0;
  String? _guidanceMessage;
  double? _guidanceDistanceMeters;
  StreamSubscription<Position>? _locationSubscription;
  Circle? _userLocationMarker;
  Circle? _userLocationHalo;
  Circle? _selectedPlaceMarker;
  Future<void> _locationMarkerUpdate = Future.value();
  Position? _lastKnownPosition;
  bool _isOutsideSupportedZone = false;
  bool _hasCenteredInitialLocation = false;
  StreamSubscription<AuthState>? _authSubscription;
  bool _stationLocationTrackingEnabled = false;
  bool _isStationChoicePromptOpen = false;
  String? _nearbyStationClusterKey;
  String? _confirmedNearbyStopId;
  String? _stationPresenceCandidateId;
  String? _loggedStationPresenceId;
  int _stationPresenceObservations = 0;
  final _placeSearchController = TextEditingController();
  final _placeSearchFocusNode = FocusNode();
  Timer? _placeSearchDebounce;
  Timer? _weatherDebounce;
  String? _weatherTemperature;
  String? _weatherCondition;
  LatLng? _weatherCentre;
  CameraPosition? _lastCameraPosition;
  int _weatherRequestVersion = 0;
  int _itineraryRenderGeneration = 0;
  List<PlaceSearchResult> _placeSearchResults = const [];
  PlaceSearchResult? _selectedPlace;
  bool _isSearchingPlaces = false;
  int _placeSearchRequestId = 0;
  DateTime? _lastLocationWorkAt;
  bool _routeRequestInFlight = false;
  final Map<String, _TimedCache<List<StopDeparture>>> _departureCache = {};
  final Map<String, _TimedCache<List<StationIncident>>> _incidentCache = {};
  final Map<String, _TimedCache<_TrafficCongestion?>> _trafficCache = {};
  bool _isSearchOpen = false;
  final Set<String> _submittedIncidentKeys = <String>{};
  List<_TransitStation> _railStations = const [];
  Map<String, _TransitStop> _transitStopsById = const {};
  _TransitStation? _nearestStation;
  int _selectedTab = 0;

  bool get _canReportIncident =>
      _isSupabaseConfigured &&
      Supabase.instance.client.auth.currentUser != null &&
      Supabase.instance.client.auth.currentSession != null;

  @override
  void initState() {
    super.initState();
    unawaited(_offlineRaptorRouter.refreshFromBackend(_backendBaseUrl));
    _prepareMapData();
    unawaited(_loadCompletedJourneyCount());
    if (_isSupabaseConfigured) {
      _syncStationLocationTrackingPreference();
      _authSubscription = Supabase.instance.client.auth.onAuthStateChange
          .listen((_) => _syncStationLocationTrackingPreference());
    }
  }

  Future<void> _loadCompletedJourneyCount() async {
    try {
      final saved = await _privacyStorage.read(key: _completedJourneysKey);
      final decoded = saved == null ? null : jsonDecode(saved);
      final count = decoded is List ? decoded.length : 0;
      if (mounted) setState(() => _completedJourneyCount = count);
    } catch (_) {
      // Journey history is a convenience feature; guidance must still work
      // when secure local storage is unavailable.
    }
  }

  Future<void> _recordCompletedJourney(Itinerary itinerary) async {
    try {
      final saved = await _privacyStorage.read(key: _completedJourneysKey);
      final decoded = saved == null ? null : jsonDecode(saved);
      final journeys = decoded is List
          ? decoded.whereType<Map>().map(Map<String, dynamic>.from).toList()
          : <Map<String, dynamic>>[];
      journeys.insert(0, {
        'completedAt': DateTime.now().toUtc().toIso8601String(),
        'destination': itinerary.legs.last.toPlace?.name ?? 'Destination',
        'durationSeconds': itinerary.duration,
        'modes': itinerary.legs.map((leg) => leg.mode).toSet().toList(),
      });
      if (journeys.length > _completedJourneyLimit) {
        journeys.removeRange(_completedJourneyLimit, journeys.length);
      }
      await _privacyStorage.write(
        key: _completedJourneysKey,
        value: jsonEncode(journeys),
      );
      if (mounted) setState(() => _completedJourneyCount = journeys.length);
    } catch (_) {
      // Do not make arrival confirmation depend on a local history write.
    }
  }

  @override
  void dispose() {
    _mapGeneration++;
    _mapController = null;
    _locationSubscription?.cancel();
    _authSubscription?.cancel();
    _placeSearchDebounce?.cancel();
    _weatherDebounce?.cancel();
    _placeSearchFocusNode.dispose();
    _placeSearchController.dispose();
    _httpClient.close();
    super.dispose();
  }

  void _syncStationLocationTrackingPreference() {
    final enabled =
        Supabase
            .instance
            .client
            .auth
            .currentUser
            ?.userMetadata?['station_location_tracking'] ==
        true;
    if (!enabled) _resetStationPresenceTracking();
    if (mounted) {
      setState(() => _stationLocationTrackingEnabled = enabled);
    } else {
      _stationLocationTrackingEnabled = enabled;
    }
  }

  void _setStationLocationTrackingEnabled(bool enabled) {
    setState(() {
      _stationLocationTrackingEnabled = enabled;
      if (!enabled) _resetStationPresenceTracking();
    });
  }

  void _resetStationPresenceTracking() {
    _nearbyStationClusterKey = null;
    _confirmedNearbyStopId = null;
    _stationPresenceCandidateId = null;
    _loggedStationPresenceId = null;
    _stationPresenceObservations = 0;
  }

  void _selectTab(int index) {
    setState(() {
      _selectedTab = index;
      if (index != 0) _isSearchOpen = false;
    });
    if (index == 0 && _lastKnownPosition != null) {
      unawaited(_askForNearbyStationChoice(_lastKnownPosition!));
    }
  }

  Future<void> _prepareMapData() async {
    final styleData = jsonDecode(
      await rootBundle.loadString('assets/style/protomaps_light.json'),
    );
    if (styleData is! Map<String, dynamic>) {
      throw const FormatException('Map style must be a JSON object.');
    }

    final sources = styleData['sources'];
    if (sources is! Map<String, dynamic> ||
        sources['protomaps'] is! Map<String, dynamic>) {
      throw const FormatException(
        'Map style does not define a protomaps source.',
      );
    }
    (sources['protomaps'] as Map<String, dynamic>)['url'] =
        await mapTilesSourceUrl();

    if (!mounted) return;
    setState(() => _dynamicStyleString = jsonEncode(styleData));
  }

  bool _isSupportedCoordinate(double latitude, double longitude) =>
      latitude >= _tileSouth &&
      latitude <= _tileNorth &&
      longitude >= _tileWest &&
      longitude <= _tileEast;

  void _showUnsupportedZone() {
    if (!mounted) return;
    setState(() => _isOutsideSupportedZone = true);
  }

  void _scheduleWeather(CameraPosition position) {
    final centre = position.target;
    final previous = _weatherCentre;
    if (previous != null &&
        Geolocator.distanceBetween(
              previous.latitude,
              previous.longitude,
              centre.latitude,
              centre.longitude,
            ) <
            100) {
      return;
    }
    _weatherDebounce?.cancel();
    final requestVersion = ++_weatherRequestVersion;
    _weatherDebounce = Timer(const Duration(milliseconds: 700), () async {
      try {
        debugPrint(
          'Weather request for ${centre.latitude.toStringAsFixed(6)},${centre.longitude.toStringAsFixed(6)}',
        );
        final headers = await backendHeaders();
        headers['Cache-Control'] = 'no-cache';
        final response = await _httpClient
            .get(
              Uri.parse('$_backendBaseUrl/api/weather/klang-valley').replace(
                queryParameters: {
                  'lat': centre.latitude.toStringAsFixed(6),
                  'lon': centre.longitude.toStringAsFixed(6),
                  // Ensure intermediary caches treat each settled camera
                  // position as a new weather observation.
                  'request': requestVersion.toString(),
                },
              ),
              headers: headers,
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          debugPrint(
            'Weather API error (${response.statusCode}): ${response.body}',
          );
          return;
        }
        final contentType = response.headers['content-type'] ?? '';
        if (!contentType.contains('application/json')) {
          debugPrint('Weather API returned non-JSON content: $contentType');
          return;
        }
        final data = jsonDecode(response.body);
        if (data is Map &&
            data['current_temp'] is num &&
            mounted &&
            requestVersion == _weatherRequestVersion) {
          setState(() {
            _weatherCentre = centre;
            _weatherTemperature =
                '${(data['current_temp'] as num).toStringAsFixed(1)}°';
            _weatherCondition = data['forecast']?.toString();
          });
        } else {
          debugPrint('Weather API returned an invalid weather payload.');
        }
      } catch (error) {
        debugPrint('Weather request failed: $error');
      }
    });
  }

  void _onCameraMove(CameraPosition position) {
    _lastCameraPosition = position;
    // Native MapLibre can omit onCameraIdle after a gesture. The existing
    // debounce in _scheduleWeather makes this safe to call for every camera
    // update: only the final settled map centre triggers an HTTP request.
    _scheduleWeather(position);
  }

  void _onCameraIdle() {
    final position = _lastCameraPosition;
    if (position != null) _scheduleWeather(position);
  }

  Future<void> _searchPlaces() async {
    final query = _placeSearchController.text.trim();
    if (query.length < 2) {
      setState(() {
        _placeSearchResults = const [];
        _isSearchingPlaces = false;
      });
      return;
    }
    final requestId = ++_placeSearchRequestId;
    setState(() {
      _isSearchingPlaces = true;
    });
    try {
      final results = await _findPlaces(query);
      if (!mounted || requestId != _placeSearchRequestId) return;
      setState(() => _placeSearchResults = results);
    } on TimeoutException {
      _showMessage('Location search timed out.');
    } catch (_) {
      _showMessage('Could not find locations right now.');
    } finally {
      if (mounted && requestId == _placeSearchRequestId) {
        setState(() => _isSearchingPlaces = false);
      }
    }
  }

  void _onPlaceSearchChanged(String value) {
    _placeSearchDebounce?.cancel();
    final query = value.trim();
    if (query.length < 2) {
      _placeSearchRequestId++;
      if (_selectedPlace != null ||
          _placeSearchResults.isNotEmpty ||
          _isSearchingPlaces) {
        setState(() {
          _selectedPlace = null;
          _placeSearchResults = const [];
          _isSearchingPlaces = false;
        });
        unawaited(_clearSelectedPlaceMarker());
      }
      return;
    }
    // Do not rebuild the app bar on every keystroke. Recreating an app-bar
    // text field while the IME is composing can drop recently typed text.
    if (_selectedPlace != null || _placeSearchResults.isNotEmpty) {
      setState(() {
        _selectedPlace = null;
        _placeSearchResults = const [];
      });
      unawaited(_clearSelectedPlaceMarker());
    }
    _placeSearchDebounce = Timer(
      const Duration(milliseconds: 350),
      _searchPlaces,
    );
  }

  void _togglePlaceSearch() {
    final willOpen = !_isSearchOpen;
    setState(() {
      _isSearchOpen = willOpen;
      if (!willOpen) {
        _placeSearchDebounce?.cancel();
        _placeSearchRequestId++;
        _placeSearchController.clear();
        _selectedPlace = null;
        _placeSearchResults = const [];
        _isSearchingPlaces = false;
        unawaited(_clearSelectedPlaceMarker());
      }
    });
    if (willOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _placeSearchFocusNode.requestFocus();
      });
    } else {
      _placeSearchFocusNode.unfocus();
    }
  }

  Future<void> _clearSelectedPlaceMarker() async {
    final marker = _selectedPlaceMarker;
    final controller = _mapController;
    _selectedPlaceMarker = null;
    if (marker != null && controller != null) {
      await controller.removeCircle(marker);
    }
  }

  Future<List<PlaceSearchResult>> _findPlaces(String query) async {
    try {
      final response = await _httpClient
          .get(
            Uri.parse(
              '$_backendBaseUrl/api/places/search?q=${Uri.encodeQueryComponent(query)}',
            ),
            headers: await backendHeaders(),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final document = jsonDecode(response.body);
        final places = document is Map ? document['places'] : null;
        if (places is List) {
          return places
              .whereType<Map>()
              .map(
                (place) => PlaceSearchResult.fromJson(
                  Map<String, dynamic>.from(place),
                ),
              )
              .where((place) => place.lat != 0 || place.lon != 0)
              .toList();
        }
      }
    } catch (error) {
      debugPrint('Full place search unavailable: $error');
    }

    // Keep transit-stop search functional while MOTIS is still starting.
    final normalizedQuery = query.toLowerCase();
    return _transitStopsById.values
        .where((stop) => stop.name.toLowerCase().contains(normalizedQuery))
        .take(12)
        .map((stop) => stop.asPlaceSearchResult())
        .toList();
  }

  Future<PlaceSearchResult> _reverseGeocodePlace(LatLng coordinate) async {
    return PlaceSearchResult(
      name: 'Selected map location',
      address:
          '${coordinate.latitude.toStringAsFixed(5)}, ${coordinate.longitude.toStringAsFixed(5)}',
      lat: coordinate.latitude,
      lon: coordinate.longitude,
    );
  }

  Future<void> _showLongPressedLocation(LatLng coordinate) async {
    if (!_isSupportedCoordinate(coordinate.latitude, coordinate.longitude)) {
      _showUnsupportedZone();
      return;
    }
    try {
      final place = await _reverseGeocodePlace(coordinate);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(place.name, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(place.address),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    _getDirectionsToPlace(place);
                  },
                  icon: const Icon(Icons.directions),
                  label: const Text('Directions'),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted) _showMessage('Could not look up that map location.');
    }
  }

  Future<void> _selectPlace(PlaceSearchResult place) async {
    if (!_isSupportedCoordinate(place.lat, place.lon)) {
      _showUnsupportedZone();
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _selectedPlace = place;
      _placeSearchResults = const [];
      _placeSearchController.text = place.name;
    });
    final controller = _mapController;
    if (controller != null) {
      if (_selectedPlaceMarker != null) {
        await controller.removeCircle(_selectedPlaceMarker!);
      }
      _selectedPlaceMarker = await controller.addCircle(
        CircleOptions(
          geometry: LatLng(place.lat, place.lon),
          circleRadius: 10,
          circleColor: '#E53935',
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 3,
        ),
      );
    }
    await controller?.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(place.lat, place.lon), 15),
    );
  }

  Future<void> _getDirectionsToSelectedPlace() async {
    final destination = _selectedPlace;
    if (destination == null) return;
    await _getDirectionsToPlace(destination);
  }

  Future<void> _getDirectionsToPlace(PlaceSearchResult destination) async {
    if (!_isSupportedCoordinate(destination.lat, destination.lon)) {
      _showUnsupportedZone();
      return;
    }
    if (_lastKnownPosition == null) await _startLocationTracking();
    if (!mounted) return;
    final origin = _lastKnownPosition;
    final selectedStart = origin == null ? await _askForStartLocation() : null;
    if (origin == null && selectedStart == null) return;
    final originLat = origin?.latitude ?? selectedStart!.lat;
    final originLon = origin?.longitude ?? selectedStart!.lon;
    if (!_isSupportedCoordinate(originLat, originLon)) {
      _showUnsupportedZone();
      return;
    }
    final routeData = await _requestRoute(
      fromLat: originLat,
      fromLon: originLon,
      toLat: destination.lat,
      toLon: destination.lon,
      fromStopId: origin == null ? selectedStart!.stopId : null,
      toStopId: destination.stopId,
    );
    await _showRouteChoices(routeData);
  }

  Future<PlaceSearchResult?> _askForStartLocation() async {
    final controller = TextEditingController();
    var results = <PlaceSearchResult>[];
    var isSearching = false;

    final selected = await showModalBottomSheet<PlaceSearchResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> search() async {
            final query = controller.text.trim();
            if (query.length < 2) return;
            setSheetState(() => isSearching = true);
            try {
              final places = await _findPlaces(query);
              setSheetState(() => results = places);
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Could not find locations right now.'),
                  ),
                );
              }
            } finally {
              if (context.mounted) setSheetState(() => isSearching = false);
            }
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                8,
                20,
                24 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Where are you starting from?',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => search(),
                    decoration: InputDecoration(
                      hintText: 'Search for a start location',
                      prefixIcon: const Icon(Icons.my_location),
                      suffixIcon: isSearching
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.search),
                              onPressed: search,
                            ),
                    ),
                  ),
                  if (results.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          final place = results[index];
                          return ListTile(
                            title: Text(place.name),
                            subtitle: Text(
                              place.address,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => Navigator.of(context).pop(place),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
    controller.dispose();
    return selected;
  }

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
    final modes = _itineraryLegs(
      itinerary,
    ).map((leg) => leg['mode']?.toString().toUpperCase()).toSet();
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
        .where(
          (leg) =>
              !{'WALK', 'HAIL'}.contains(leg['mode']?.toString().toUpperCase()),
        )
        .map((leg) => leg['routeShortName']?.toString())
        .whereType<String>()
        .where((name) => name.isNotEmpty)
        .toList();
    final sheltered = _itineraryLegs(itinerary).any(
      (leg) =>
          leg['mode']?.toString().toUpperCase() == 'WALK' &&
          leg['isSheltered'] == true,
    );
    final summary = services.isEmpty
        ? 'Direct journey estimate'
        : services.join(' → ');
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

  String _fareLabel(Itinerary itinerary) {
    final fare = itinerary.fareAmount;
    return fare == null ? '' : 'RM${fare.toStringAsFixed(2)}';
  }

  String _formatDuration(num seconds) {
    final totalMinutes = (seconds / 60).round();
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours == 0) return '$minutes min';
    if (minutes == 0) return '${hours}h';
    return '${hours}h ${minutes}m';
  }

  Future<void> _showRouteChoices(Map<String, dynamic>? routeData) async {
    if (routeData == null || routeData['itineraries'] is! List) return;
    final itineraries = (routeData['itineraries'] as List<dynamic>)
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    // Duration can exclude waiting time in a timetable view. Prefer the
    // earliest usable public-transport departure rather than a journey that
    // starts later. Keep the complete e-hailing fallback after transit.
    itineraries.sort((left, right) {
      final leftIsFullHail = left['routeCategory']?.toString() == 'ehailing';
      final rightIsFullHail = right['routeCategory']?.toString() == 'ehailing';
      if (leftIsFullHail != rightIsFullHail) return leftIsFullHail ? 1 : -1;
      DateTime departure(Map<String, dynamic> itinerary) {
        final legs = _itineraryLegs(itinerary);
        final value = legs.isEmpty ? null : legs.first['startTime'];
        return value is String
            ? DateTime.tryParse(value)?.toLocal() ?? DateTime(9999)
            : DateTime(9999);
      }

      final departureComparison = departure(left).compareTo(departure(right));
      if (departureComparison != 0) return departureComparison;
      final leftDuration =
          (left['duration'] as num?)?.toDouble() ?? double.infinity;
      final rightDuration =
          (right['duration'] as num?)?.toDouble() ?? double.infinity;
      final durationComparison = leftDuration.compareTo(rightDuration);
      if (durationComparison != 0) return durationComparison;
      final leftScore =
          ((left['ranking'] as Map?)?['score'] as num?)?.toDouble() ??
          double.infinity;
      final rightScore =
          ((right['ranking'] as Map?)?['score'] as num?)?.toDouble() ??
          double.infinity;
      return leftScore.compareTo(rightScore);
    });
    if (itineraries.isEmpty || !mounted) {
      _showMessage('No routes found for this location.');
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
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
                        Text(_formatDuration(option.duration)),
                        if (_fareLabel(option).isNotEmpty)
                          Text(
                            _fareLabel(option),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                      ],
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      _applyItinerary(itinerary);
                    },
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _applyItinerary(Map<String, dynamic> itinerary) async {
    FocusScope.of(context).unfocus();
    _placeSearchDebounce?.cancel();
    if (mounted) {
      setState(() {
        _isSearchOpen = false;
        _placeSearchRequestId++;
        _placeSearchController.clear();
        _selectedPlace = null;
        _placeSearchResults = const [];
        _isSearchingPlaces = false;
      });
      unawaited(_clearSelectedPlaceMarker());
    }
    final legs = _itineraryLegs(itinerary);
    final renderGeneration = ++_itineraryRenderGeneration;
    if (!mounted) return;
    // Open the details immediately. Map rendering is asynchronous and should
    // never make a valid itinerary appear to have failed to load.
    setState(() {
      _currentItinerary = Itinerary.fromJson(itinerary);
      _isJourneyGuidanceActive = false;
      _hasCompletedCurrentJourney = false;
      _guidedLegIndex = 0;
      _hasBoardedGuidedTransit = false;
      _guidanceMessage = null;
      _guidanceDistanceMeters = null;
    });
    unawaited(_renderItinerary(legs, renderGeneration));
  }

  Future<void> _startJourneyGuidance() async {
    if (_currentItinerary == null || _currentItinerary!.legs.isEmpty) return;
    if (_isDirectEhailingItinerary(_currentItinerary!)) {
      _showMessage(
        'E-hailing is booked and tracked in your chosen e-hailing app.',
      );
      return;
    }
    if (_lastKnownPosition == null) await _startLocationTracking();
    final position = _lastKnownPosition;
    if (position == null) {
      _showMessage('Location is required to start live journey guidance.');
      return;
    }
    setState(() {
      _isJourneyGuidanceActive = true;
      _hasCompletedCurrentJourney = false;
      _guidedLegIndex = 0;
      _hasBoardedGuidedTransit = false;
      _guidanceMessage = 'Finding your first step…';
    });
    _updateJourneyGuidance(position);
  }

  void _stopJourneyGuidance() {
    if (!mounted) return;
    setState(() {
      _isJourneyGuidanceActive = false;
      _hasBoardedGuidedTransit = false;
      _guidanceMessage = 'Live guidance stopped.';
      _guidanceDistanceMeters = null;
    });
  }

  bool _isTransitLeg(ItineraryLeg leg) {
    final mode = leg.mode.toUpperCase();
    return mode != 'WALK' && mode != 'HAIL';
  }

  /// A full e-hailing alternative is handed off to an external booking app.
  /// First-mile e-hailing followed by public transport still supports
  /// JomNaik's guidance for its transit portion.
  bool _isDirectEhailingItinerary(Itinerary itinerary) =>
      itinerary.legs.isNotEmpty &&
      itinerary.legs.every((leg) => leg.mode.toUpperCase() == 'HAIL');

  ItineraryPlace? _guidanceTarget(ItineraryLeg leg) =>
      _isTransitLeg(leg) && !_hasBoardedGuidedTransit
      ? leg.fromPlace
      : leg.toPlace;

  void _updateJourneyGuidance(Position position) {
    final itinerary = _currentItinerary;
    if (!_isJourneyGuidanceActive || itinerary == null || !mounted) return;
    if (_guidedLegIndex >= itinerary.legs.length) return;
    final leg = itinerary.legs[_guidedLegIndex];
    final target = _guidanceTarget(leg);
    if (target?.lat == null || target?.lon == null) {
      setState(() {
        _guidanceMessage = 'Follow the itinerary details for this step.';
        _guidanceDistanceMeters = null;
      });
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
      if (_isTransitLeg(leg) && !_hasBoardedGuidedTransit) {
        setState(() {
          _guidanceDistanceMeters = distance;
          _guidanceMessage =
              'At ${target.name}. Board ${leg.routeShortName ?? 'the service'} toward ${leg.headsign ?? leg.toPlace?.name ?? 'your destination'}.';
        });
        return;
      }
      _completeGuidedLeg();
      return;
    }
    final action = _isTransitLeg(leg) && !_hasBoardedGuidedTransit
        ? 'Go to ${target.name}'
        : leg.mode.toUpperCase() == 'HAIL'
        ? 'Ride to ${target.name}'
        : 'Continue to ${target.name}';
    setState(() {
      _guidanceDistanceMeters = distance;
      _guidanceMessage = '$action • ${_formatDistance(distance)} remaining';
    });
  }

  void _markGuidedTransitBoarded() {
    final itinerary = _currentItinerary;
    if (itinerary == null || _guidedLegIndex >= itinerary.legs.length) return;
    final leg = itinerary.legs[_guidedLegIndex];
    if (!_isTransitLeg(leg)) return;
    setState(() {
      _hasBoardedGuidedTransit = true;
      _guidanceMessage =
          'On board ${leg.routeShortName ?? 'the service'}. Alight at ${leg.toPlace?.name ?? 'the next stop'}.';
      _guidanceDistanceMeters = null;
    });
    final position = _lastKnownPosition;
    if (position != null) _updateJourneyGuidance(position);
  }

  void _completeGuidedLeg() {
    final itinerary = _currentItinerary;
    if (itinerary == null) return;
    final nextIndex = _guidedLegIndex + 1;
    if (nextIndex >= itinerary.legs.length) {
      setState(() {
        _guidedLegIndex = nextIndex;
        _isJourneyGuidanceActive = false;
        _hasCompletedCurrentJourney = true;
        _hasBoardedGuidedTransit = false;
        _guidanceDistanceMeters = 0;
        _guidanceMessage = 'You have arrived at your destination.';
      });
      unawaited(_recordCompletedJourney(itinerary));
      return;
    }
    setState(() {
      _guidedLegIndex = nextIndex;
      _hasBoardedGuidedTransit = false;
      _guidanceDistanceMeters = null;
      _guidanceMessage = 'Next step ready.';
    });
    final position = _lastKnownPosition;
    if (position != null) _updateJourneyGuidance(position);
  }

  Future<void> _replanGuidedJourney() async {
    if (_isGuidanceReplanning || _lastKnownPosition == null) return;
    final itinerary = _currentItinerary;
    final destination = itinerary?.legs.isNotEmpty == true
        ? itinerary!.legs.last.toPlace
        : null;
    if (destination?.lat == null || destination?.lon == null) {
      _showMessage('The destination has no map coordinates to replan from.');
      return;
    }
    setState(() => _isGuidanceReplanning = true);
    try {
      final routeData = await _requestRoute(
        fromLat: _lastKnownPosition!.latitude,
        fromLon: _lastKnownPosition!.longitude,
        toLat: destination!.lat!,
        toLon: destination.lon!,
      );
      final itineraries = routeData?['itineraries'];
      final first =
          itineraries is List &&
              itineraries.isNotEmpty &&
              itineraries.first is Map
          ? Map<String, dynamic>.from(itineraries.first as Map)
          : null;
      if (first == null) return;
      await _applyItinerary(first);
      if (mounted) await _startJourneyGuidance();
    } finally {
      if (mounted) setState(() => _isGuidanceReplanning = false);
    }
  }

  String _formatDistance(double meters) => meters >= 1000
      ? '${(meters / 1000).toStringAsFixed(1)} km'
      : '${meters.round()} m';

  String? _weatherItineraryReminder(Itinerary itinerary) {
    final condition = _weatherCondition?.toLowerCase();
    if (condition == null || condition.isEmpty) return null;
    final wetWeather = [
      'rain',
      'shower',
      'drizzle',
      'thunder',
      'storm',
    ].any(condition.contains);
    if (!wetWeather) return null;
    final openWalks = itinerary.legs
        .where((leg) => leg.mode.toUpperCase() == 'WALK' && !leg.isSheltered)
        .length;
    final coveredWalks = itinerary.legs
        .where((leg) => leg.mode.toUpperCase() == 'WALK' && leg.isSheltered)
        .length;
    if (openWalks > 0) {
      return 'Rain conditions nearby: bring an umbrella. This journey includes '
          '$openWalks open walking ${openWalks == 1 ? 'section' : 'sections'}; '
          'use covered paths where available.';
    }
    if (coveredWalks > 0) {
      return 'Rain conditions nearby: bring an umbrella and prefer the covered '
          '${coveredWalks == 1 ? 'walkway' : 'walkways'} in this itinerary.';
    }
    return 'Rain conditions nearby: bring an umbrella for station access and transfers.';
  }

  Widget _buildJourneyGuidanceCard() {
    final itinerary = _currentItinerary;
    if (itinerary == null ||
        itinerary.legs.isEmpty ||
        _isDirectEhailingItinerary(itinerary)) {
      return const SizedBox.shrink();
    }
    final hasCurrentLeg = _guidedLegIndex < itinerary.legs.length;
    final leg = hasCurrentLeg ? itinerary.legs[_guidedLegIndex] : null;
    final atBoardingStop =
        _isJourneyGuidanceActive &&
        leg != null &&
        _isTransitLeg(leg) &&
        !_hasBoardedGuidedTransit &&
        (_guidanceDistanceMeters ?? double.infinity) <= 90;
    return LiveGuidanceCard(
      isActive: _isJourneyGuidanceActive,
      hasCurrentStep: hasCurrentLeg,
      currentStep: _guidedLegIndex + 1,
      totalSteps: itinerary.legs.length,
      message:
          _guidanceMessage ??
          'Use your live location to advance each journey step.',
      showBoardedAction: atBoardingStop,
      isReplanning: _isGuidanceReplanning,
      isCompleted: _hasCompletedCurrentJourney,
      completedTrips: _completedJourneyCount,
      onStart: _startJourneyGuidance,
      onBoarded: _markGuidedTransitBoarded,
      onReplan: _replanGuidedJourney,
      onStop: _stopJourneyGuidance,
    );
  }

  bool _isCurrentItineraryRender(int generation) =>
      mounted && generation == _itineraryRenderGeneration;

  Future<void> _renderItinerary(
    List<Map<String, dynamic>> legs,
    int renderGeneration,
  ) async {
    // The itinerary details must remain usable even if MapLibre is briefly
    // rebuilding its native view. Rendering the line is an enhancement, not
    // a reason to discard an otherwise valid route.
    try {
      await _drawItinerary(legs, renderGeneration);
      if (!_isCurrentItineraryRender(renderGeneration)) return;
      await _hideRailLinesForItinerary();
    } catch (error) {
      debugPrint('Could not render itinerary geometry: $error');
    }
  }

  Future<void> _dismissItinerary() async {
    _itineraryRenderGeneration++;
    setState(() {
      _currentItinerary = null;
      _isJourneyGuidanceActive = false;
      _hasBoardedGuidedTransit = false;
      _guidanceMessage = null;
      _guidanceDistanceMeters = null;
    });
    // Each style operation can fail independently when a route has no walk
    // or transit layer. Do not let one missing layer skip restoration of the
    // offline rail layer.
    try {
      await _mapController?.removeLayer('route_transit_layer');
    } catch (_) {}
    try {
      await _mapController?.removeLayer('route_walk_layer');
    } catch (_) {}
    try {
      await _mapController?.removeSource('route_transit_source');
    } catch (_) {}
    try {
      await _mapController?.removeSource('route_walk_source');
    } catch (_) {}
    try {
      // All bundled rail features carry a route_id. This explicitly restores
      // the complete offline rail layer after the itinerary is closed.
      await _mapController?.setFilter('offline_rail_lines_layer', [
        'has',
        'route_id',
      ]);
    } catch (_) {
      // The map may be rebuilding; its on-created setup will restore it.
    }
  }

  Future<void> _hideRailLinesForItinerary() async {
    await _mapController?.setFilter('offline_rail_lines_layer', [
      '==',
      ['get', 'route_id'],
      '__hidden_while_itinerary_is_open__',
    ]);
  }

  Future<Map<String, dynamic>?> _requestRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    String? fromStopId,
    String? toStopId,
    bool preferBrt = false,
  }) async {
    if (_routeRequestInFlight) return null;
    _routeRequestInFlight = true;
    try {
      final departure = DateTime.now();
      final requestBody = <String, dynamic>{
        'from_lat': fromLat,
        'from_lon': fromLon,
        'to_lat': toLat,
        'to_lon': toLon,
        'prefer_brt': preferBrt,
        'departure_date':
            '${departure.year.toString().padLeft(4, '0')}-${departure.month.toString().padLeft(2, '0')}-${departure.day.toString().padLeft(2, '0')}',
        'departure_time':
            '${departure.hour.toString().padLeft(2, '0')}:${departure.minute.toString().padLeft(2, '0')}:${departure.second.toString().padLeft(2, '0')}',
      };
      if (fromStopId != null) requestBody['from_stop_id'] = fromStopId;
      if (toStopId != null) requestBody['to_stop_id'] = toStopId;
      final response = await _httpClient
          .post(
            Uri.parse('$_backendBaseUrl/api/route'),
            headers: await backendHeaders(json: true),
            body: jsonEncode(requestBody),
          )
          .timeout(const Duration(seconds: 70));

      if (response.statusCode != 200) {
        debugPrint('Route API error: ${response.body}');
        return _offlineRoute(
          fromLat: fromLat,
          fromLon: fromLon,
          toLat: toLat,
          toLon: toLon,
          fromStopId: fromStopId,
          toStopId: toStopId,
        );
      }

      final responseData = jsonDecode(response.body);
      if (responseData is! Map<String, dynamic> ||
          responseData['itineraries'] is! List) {
        _showMessage('The route service returned an invalid response.');
        debugPrint('Invalid route response: ${response.body}');
        return null;
      }

      final itineraries = responseData['itineraries'] as List<dynamic>;
      if (itineraries.isEmpty) {
        final fallbackMessage = responseData['fallbackMessage'];
        _showMessage(
          fallbackMessage is String && fallbackMessage.isNotEmpty
              ? fallbackMessage
              : 'No nearby transit stop is available for this location.',
        );
        return null;
      }

      final firstItinerary = itineraries.first;
      if (firstItinerary is! Map || firstItinerary['legs'] is! List) {
        _showMessage('The route service returned an invalid itinerary.');
        return null;
      }

      return responseData;
    } on FormatException catch (error) {
      _showMessage('The route service returned invalid JSON.');
      debugPrint('Invalid route JSON: $error');
      return null;
    } on http.ClientException catch (error) {
      debugPrint('Route network error: $error');
      return _offlineRoute(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        fromStopId: fromStopId,
        toStopId: toStopId,
      );
    } on TimeoutException {
      return _offlineRoute(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        fromStopId: fromStopId,
        toStopId: toStopId,
      );
    } catch (error) {
      _showMessage('Could not calculate the route.');
      debugPrint('Route error: $error');
      return null;
    } finally {
      _routeRequestInFlight = false;
    }
  }

  Future<Map<String, dynamic>?> _offlineRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    String? fromStopId,
    String? toStopId,
  }) async {
    try {
      final result = await _offlineRaptorRouter.plan(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        fromStopId: fromStopId,
        toStopId: toStopId,
      );
      if (result != null) {
        _showMessage(
          'Using offline timetable routing. Live updates are unavailable.',
        );
        return result;
      }
    } catch (error) {
      debugPrint('Offline RAPTOR route error: $error');
    }
    _showMessage(
      'No offline timetable route is available for these locations.',
    );
    return null;
  }

  Future<void> _drawItinerary(
    List<Map<String, dynamic>> legs,
    int renderGeneration,
  ) async {
    // 1. Clear any old routing layers and sources to keep the canvas clean
    try {
      await _mapController?.removeLayer("route_transit_layer");
      await _mapController?.removeLayer("route_walk_layer");
      await _mapController?.removeSource("route_transit_source");
      await _mapController?.removeSource("route_walk_source");
    } catch (e) {
      // Layers didn't exist yet, safe to ignore
    }

    final walkFeatures = <Map<String, dynamic>>[];
    final transitFeatures = <Map<String, dynamic>>[];
    final routeCoordinates = <List<double>>[];
    bool hasGeometry = false;

    // 2. Loop through legs and separate geometries by transport mode
    for (final leg in legs) {
      // The backend withholds geometry for the small set of source GTFS bus
      // shapes that fail its stop-to-shape audit. Omitting that segment is
      // more honest than drawing a misleading straight or incorrect line.
      if (leg['geometryQuality'] == 'unverified') continue;
      final mode = leg['mode'] as String? ?? 'WALK';
      final legCoordinates = <List<double>>[];
      final geometry = leg['legGeometry'];
      if (geometry is Map && geometry['points'] is String) {
        final points = geometry['points'] as String;
        final precision = geometry['precision'] is num
            ? (geometry['precision'] as num).toInt()
            : 5;
        legCoordinates.addAll(_decodePolyline(points, precision: precision));
      } else if (geometry is Map && geometry['coordinates'] is List) {
        // GTFS shapes are supplied by the backend for generated BRT legs.
        // Preserve every alignment point instead of drawing a straight line
        // between the two station coordinates.
        for (final coordinate in geometry['coordinates'] as List) {
          if (coordinate is List &&
              coordinate.length >= 2 &&
              coordinate[0] is num &&
              coordinate[1] is num) {
            legCoordinates.add([
              (coordinate[0] as num).toDouble(),
              (coordinate[1] as num).toDouble(),
            ]);
          }
        }
      } else {
        // Never draw a straight line for e-hailing. The backend must provide
        // a road-network geometry; if both road routers are unavailable, omit
        // the map segment instead of displaying an invalid route.
        if (mode.toUpperCase() == 'HAIL' &&
            leg['roadRoutingUnavailable'] == true) {
          continue;
        }
        // Direct fallback estimates do not claim to have road-level geometry.
        final from = leg['from'];
        final to = leg['to'];
        if (from is Map &&
            to is Map &&
            from['lat'] is num &&
            from['lon'] is num &&
            to['lat'] is num &&
            to['lon'] is num) {
          legCoordinates.add([
            (from['lon'] as num).toDouble(),
            (from['lat'] as num).toDouble(),
          ]);
          legCoordinates.add([
            (to['lon'] as num).toDouble(),
            (to['lat'] as num).toDouble(),
          ]);
        }
      }

      if (legCoordinates.isEmpty) continue;
      hasGeometry = true;
      routeCoordinates.addAll(legCoordinates);

      final feature = {
        "type": "Feature",
        "properties": {},
        "geometry": {"type": "LineString", "coordinates": legCoordinates},
      };

      if (mode.toUpperCase() == 'WALK') {
        walkFeatures.add(feature);
      } else {
        transitFeatures.add(feature);
      }
    }

    if (!hasGeometry) {
      if (_isCurrentItineraryRender(renderGeneration)) {
        _showMessage('The selected route has no map geometry.');
      }
      return;
    }
    if (!_isCurrentItineraryRender(renderGeneration)) return;

    // 3. Render distinct dashed walk paths onto the GPU
    if (walkFeatures.isNotEmpty &&
        _isCurrentItineraryRender(renderGeneration)) {
      await _mapController?.addSource(
        "route_walk_source",
        GeojsonSourceProperties(
          data: {"type": "FeatureCollection", "features": walkFeatures},
        ),
      );
      await _mapController?.addLineLayer(
        "route_walk_source",
        "route_walk_layer",
        const LineLayerProperties(
          lineColor: '#64748B',
          lineWidth: 4.0,
          lineOpacity: 0.8,
          // Dash pattern: [dashLength, gapLength]
          lineDasharray: [2.0, 2.0],
          lineCap: 'round',
          lineJoin: 'round',
        ),
      );
    }

    // 4. Render solid transit streaks for buses or trains
    if (transitFeatures.isNotEmpty &&
        _isCurrentItineraryRender(renderGeneration)) {
      await _mapController?.addSource(
        "route_transit_source",
        GeojsonSourceProperties(
          data: {"type": "FeatureCollection", "features": transitFeatures},
        ),
      );
      await _mapController?.addLineLayer(
        "route_transit_source",
        "route_transit_layer",
        const LineLayerProperties(
          lineColor: '#FF3B30', // High-visibility solid transit red
          lineWidth: 6.0,
          lineOpacity: 0.95,
          lineCap: 'round',
          lineJoin: 'round',
        ),
      );
    }

    if (_isCurrentItineraryRender(renderGeneration)) {
      await _focusItineraryOnMap(routeCoordinates);
    }
  }

  List<List<double>> _decodePolyline(String encoded, {required int precision}) {
    final coordinates = <List<double>>[];
    var index = 0;
    var latitude = 0;
    var longitude = 0;
    final factor = math.pow(10, precision.clamp(0, 8)).toDouble();

    int? nextDelta() {
      var result = 0;
      var shift = 0;
      while (index < encoded.length) {
        final value = encoded.codeUnitAt(index++) - 63;
        if (value < 0) return null;
        result |= (value & 0x1f) << shift;
        shift += 5;
        if (value < 0x20) {
          return (result & 1) == 1 ? ~(result >> 1) : (result >> 1);
        }
      }
      return null;
    }

    while (index < encoded.length) {
      final latitudeDelta = nextDelta();
      final longitudeDelta = nextDelta();
      if (latitudeDelta == null || longitudeDelta == null) break;
      latitude += latitudeDelta;
      longitude += longitudeDelta;
      final lat = latitude / factor;
      final lon = longitude / factor;
      if (lat.abs() <= 90 && lon.abs() <= 180) {
        // GeoJSON uses [longitude, latitude].
        coordinates.add([lon, lat]);
      }
    }
    return coordinates;
  }

  Future<void> _focusItineraryOnMap(List<List<double>> coordinates) async {
    final controller = _mapController;
    if (controller == null || coordinates.isEmpty) return;

    final longitudes = coordinates.map((point) => point[0]);
    final latitudes = coordinates.map((point) => point[1]);
    final west = longitudes.reduce(math.min);
    final east = longitudes.reduce(math.max);
    final south = latitudes.reduce(math.min);
    final north = latitudes.reduce(math.max);

    try {
      if (west == east && south == north) {
        await controller.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(south, west), 15),
        );
        return;
      }
      await controller.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(south, west),
            northeast: LatLng(north, east),
          ),
          left: 36,
          top: 100,
          right: 36,
          bottom: 260,
        ),
      );
    } catch (_) {
      // Rendering the route is still useful even if the camera animation
      // cannot complete while the map is being rebuilt.
    }
  }

  Future<void> _onMapCreated(MapLibreMapController controller) async {
    final generation = ++_mapGeneration;
    _mapController = controller;
    await _loadAndRenderOfflineRailLines();
    if (!mounted || generation != _mapGeneration) return;
    await _loadAndRenderOfflineStops();
    if (!mounted || generation != _mapGeneration) return;
    await _loadAndRenderStationPerimeters();
    if (!mounted || generation != _mapGeneration) return;
    _scheduleWeather(const CameraPosition(target: LatLng(3.1390, 101.6868)));
    await _startLocationTracking();
    if (!mounted || generation != _mapGeneration) return;
    controller.onFeatureTapped.add((
      point,
      coordinates,
      id,
      layerId,
      annotation,
    ) {
      _queryTappedFeature(point);
    });
  }

  Future<void> _startLocationTracking() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _showMessage('Turn on location services to show your position.');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      _showMessage('Location permission was not granted.');
      return;
    }
    if (permission == LocationPermission.deniedForever) {
      _showMessage('Enable location permission in your device settings.');
      return;
    }

    await _locationSubscription?.cancel();
    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );
    _locationSubscription =
        Geolocator.getPositionStream(locationSettings: settings).listen(
          _updateUserLocation,
          onError: (_) => _showMessage('Could not update your location.'),
        );

    try {
      await _updateUserLocation(
        await Geolocator.getCurrentPosition(locationSettings: settings),
      );
    } catch (_) {
      _showMessage('Could not get your current location.');
    }
  }

  Future<void> _updateUserLocation(Position position) async {
    _lastKnownPosition = position;
    final isOutsideZone = !_isSupportedCoordinate(
      position.latitude,
      position.longitude,
    );
    if (mounted && _isOutsideSupportedZone != isOutsideZone) {
      setState(() => _isOutsideSupportedZone = isOutsideZone);
    }
    if (isOutsideZone) return;
    _updateJourneyGuidance(position);
    // GPS can emit several updates per second on some devices. Station
    // matching, Supabase presence tracking and interchange prompts do not
    // need that frequency; keep the map marker responsive while throttling
    // the more expensive work to one pass every five seconds.
    final now = DateTime.now();
    final shouldRunLocationWork =
        _lastLocationWorkAt == null ||
        now.difference(_lastLocationWorkAt!) >= const Duration(seconds: 5);
    if (shouldRunLocationWork) {
      _lastLocationWorkAt = now;
      _updateNearestStation(position);
      _trackAnonymousStationPresence(position);
      unawaited(_askForNearbyStationChoice(position));
    }
    final controller = _mapController;
    if (controller == null) return;

    _locationMarkerUpdate = _locationMarkerUpdate.then(
      (_) => _renderUserLocation(controller, position),
      onError: (_) => _renderUserLocation(controller, position),
    );
    await _locationMarkerUpdate;
  }

  Future<void> _renderUserLocation(
    MapLibreMapController controller,
    Position position,
  ) async {
    try {
      final coordinate = LatLng(position.latitude, position.longitude);
      // Update existing annotations instead of removing/recreating them on
      // every GPS event. This avoids flicker and reduces platform-channel
      // traffic substantially during live tracking.
      if (_userLocationHalo != null) {
        await controller.updateCircle(
          _userLocationHalo!,
          CircleOptions(geometry: coordinate),
        );
      } else {
        _userLocationHalo = await controller.addCircle(
          CircleOptions(
            geometry: coordinate,
            circleRadius: 26,
            circleColor: '#007AFF',
            circleOpacity: 0.22,
            circleStrokeColor: '#007AFF',
            circleStrokeOpacity: 0.35,
            circleStrokeWidth: 1,
          ),
        );
      }
      if (_userLocationMarker != null) {
        await controller.updateCircle(
          _userLocationMarker!,
          CircleOptions(geometry: coordinate),
        );
      } else {
        _userLocationMarker = await controller.addCircle(
          CircleOptions(
            geometry: coordinate,
            circleRadius: 9,
            circleColor: '#007AFF',
            circleStrokeColor: '#FFFFFF',
            circleStrokeWidth: 3,
          ),
        );
      }
      if (!_hasCenteredInitialLocation) {
        _hasCenteredInitialLocation = true;
        await controller.animateCamera(
          CameraUpdate.newLatLngZoom(
            LatLng(position.latitude, position.longitude),
            15,
          ),
        );
      }
    } catch (_) {
      // The map can be disposed while a location update is in flight.
    }
  }

  void _updateNearestStation(Position position) {
    if (_railStations.isEmpty || !mounted) return;
    final station = _railStations.reduce((closest, candidate) {
      final closestDistance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        closest.lat,
        closest.lon,
      );
      final candidateDistance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        candidate.lat,
        candidate.lon,
      );
      return candidateDistance < closestDistance ? candidate : closest;
    });
    if (_nearestStation?.id != station.id) {
      setState(() => _nearestStation = station);
    }
  }

  void _trackAnonymousStationPresence(Position position) {
    if (!_stationLocationTrackingEnabled ||
        Supabase.instance.client.auth.currentUser == null ||
        _transitStopsById.isEmpty) {
      _resetStationPresenceTracking();
      return;
    }
    const stationRadiusMeters = 45.0;
    final confirmedStop = _confirmedNearbyStopId == null
        ? null
        : _transitStopsById[_confirmedNearbyStopId];
    final closestStop = _transitStopsById.values.reduce((closest, candidate) {
      final closestDistance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        closest.lat,
        closest.lon,
      );
      final candidateDistance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        candidate.lat,
        candidate.lon,
      );
      return candidateDistance < closestDistance ? candidate : closest;
    });
    final stop =
        confirmedStop != null &&
            Geolocator.distanceBetween(
                  position.latitude,
                  position.longitude,
                  confirmedStop.lat,
                  confirmedStop.lon,
                ) <=
                stationRadiusMeters
        ? confirmedStop
        : closestStop;
    final distance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      stop.lat,
      stop.lon,
    );
    if (distance > stationRadiusMeters) {
      _resetStationPresenceTracking();
      return;
    }
    if (_stationPresenceCandidateId == stop.id) {
      _stationPresenceObservations++;
    } else {
      _stationPresenceCandidateId = stop.id;
      _stationPresenceObservations = 1;
      _loggedStationPresenceId = null;
    }
    if (_stationPresenceObservations < 2 ||
        _loggedStationPresenceId == stop.id) {
      return;
    }
    _loggedStationPresenceId = stop.id;
    unawaited(_logAnonymousStationPresence(stop));
  }

  Future<void> _logAnonymousStationPresence(_TransitStop stop) async {
    try {
      // Deliberately omit user IDs, device IDs, and raw GPS coordinates.
      final response = await _httpClient.post(
        Uri.parse('$_backendBaseUrl/api/station-presence'),
        headers: await backendHeaders(json: true),
        body: jsonEncode({
          'station_id': stop.id,
          'station_name': stop.name,
          'observed_at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      if (response.statusCode != 202) {
        throw StateError('Presence was rejected');
      }
    } catch (_) {
      // Logging is optional and must never interrupt navigation or tracking.
      _loggedStationPresenceId = null;
    }
  }

  Future<void> _openIncidentReport() async {
    if (!_isSupabaseConfigured) {
      _showMessage('Incident reporting is not configured yet.');
      return;
    }
    final auth = Supabase.instance.client.auth;
    if (auth.currentUser == null) {
      _showMessage('Sign in to submit an incident report.');
      return;
    }
    if (auth.currentSession == null) {
      try {
        await auth.refreshSession();
      } on AuthException {
        // The following message gives the user a safe way to recover.
      }
    }
    if (auth.currentSession == null) {
      _showMessage('Your sign-in session has expired. Please sign in again.');
      return;
    }
    if (_lastKnownPosition == null) await _startLocationTracking();
    if (!mounted) return;
    final position = _lastKnownPosition;
    if (position == null || _transitStopsById.isEmpty) {
      _showMessage('Your location is needed to report an incident.');
      return;
    }

    final stop = _transitStopsById.values.reduce((closest, candidate) {
      final closestDistance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        closest.lat,
        closest.lon,
      );
      final candidateDistance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        candidate.lat,
        candidate.lon,
      );
      return candidateDistance < closestDistance ? candidate : closest;
    });
    final distance = Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      stop.lat,
      stop.lon,
    );
    if (distance > 100) {
      _showMessage(
        'You need to be within 100 m of a station or stop to report an incident.',
      );
      return;
    }

    final isBusStop = stop.transitType == 'bus';
    String? affectedRoute;
    if (isBusStop) {
      final routes = stop.routes
          .split(',')
          .map((route) => route.trim())
          .where((route) => route.isNotEmpty)
          .toList();
      if (routes.isEmpty) routes.add('Unknown service');
      affectedRoute = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Which bus is affected?',
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                ...routes.map(
                  (route) => ListTile(
                    leading: const Icon(Icons.directions_bus),
                    title: Text('Bus $route'),
                    onTap: () => Navigator.of(sheetContext).pop(route),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (affectedRoute == null) return;
    }
    if (!mounted) return;

    final report = await showModalBottomSheet<_IncidentType>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
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
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text('Reporting for ${stop.name} • ${distance.round()} m away'),
              const SizedBox(height: 12),
              ..._IncidentType.values
                  .where((type) => type.isBus == isBusStop)
                  .map(
                    (type) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(type.icon, color: Colors.red.shade700),
                      title: Text(type.label),
                      subtitle: Text(type.description),
                      onTap: () => Navigator.of(sheetContext).pop(type),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
    if (report == null) return;

    final reportKey = '${stop.id}:${affectedRoute ?? 'station'}:${report.name}';
    if (_submittedIncidentKeys.contains(reportKey)) {
      _showMessage('You have already reported this incident at this stop.');
      return;
    }
    try {
      final response = await _httpClient.post(
        Uri.parse('$_backendBaseUrl/api/incidents'),
        headers: await backendHeaders(json: true),
        body: jsonEncode({
          'station_id': stop.id,
          'station_name': stop.name,
          'station_lat': stop.lat,
          'station_lon': stop.lon,
          'report_type': report.name,
          'target_type': isBusStop ? 'bus' : 'station',
          'service_route': affectedRoute,
          'reported_at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      if (response.statusCode != 202) {
        throw StateError('Incident was rejected');
      }
      _submittedIncidentKeys.add(reportKey);
      _showMessage('Thanks — your anonymous report was submitted.');
    } catch (_) {
      _showMessage(
        'Could not submit the report. Check your connection and try again.',
      );
    }
  }

  Future<void> _askForNearbyStationChoice(Position position) async {
    if (!_stationLocationTrackingEnabled ||
        _isStationChoicePromptOpen ||
        _transitStopsById.isEmpty ||
        _selectedTab != 0 ||
        !mounted) {
      return;
    }
    const nearbyDistanceMeters = 60.0;
    const sharedStationDistanceMeters = 20.0;
    final nearbyStops = _transitStopsById.values.where((stop) {
      return Geolocator.distanceBetween(
            position.latitude,
            position.longitude,
            stop.lat,
            stop.lon,
          ) <=
          nearbyDistanceMeters;
    }).toList();
    final clusteredStops = nearbyStops.where((stop) {
      return nearbyStops.any(
        (other) =>
            other.id != stop.id &&
            Geolocator.distanceBetween(
                  stop.lat,
                  stop.lon,
                  other.lat,
                  other.lon,
                ) <=
                sharedStationDistanceMeters,
      );
    }).toList();
    if (clusteredStops.length < 2) {
      _nearbyStationClusterKey = null;
      return;
    }
    clusteredStops.sort((first, second) => first.name.compareTo(second.name));
    final clusterKey = clusteredStops.map((stop) => stop.id).join('|');
    if (clusterKey == _nearbyStationClusterKey) return;

    _nearbyStationClusterKey = clusterKey;
    _isStationChoicePromptOpen = true;
    try {
      final selected = await showModalBottomSheet<_TransitStop>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Which station are you at?',
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text('Several nearby stops share this interchange.'),
                const SizedBox(height: 12),
                ...clusteredStops.map(
                  (stop) => ListTile(
                    leading: const Icon(Icons.train),
                    title: Text(stop.name),
                    subtitle: Text(stop.id),
                    onTap: () => Navigator.of(sheetContext).pop(stop),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (selected != null) {
        _confirmedNearbyStopId = selected.id;
        await _mapController?.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(selected.lat, selected.lon), 16),
        );
      }
    } finally {
      _isStationChoicePromptOpen = false;
    }
  }

  Future<void> _focusNearestStation() async {
    final station = _nearestStation;
    if (station == null) return;
    await _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(station.lat, station.lon), 15),
    );
  }

  Future<void> _showMyLocation() async {
    if (_lastKnownPosition == null) {
      await _startLocationTracking();
    }
    final position = _lastKnownPosition;
    final controller = _mapController;
    if (position == null || controller == null) return;

    final location = LatLng(position.latitude, position.longitude);
    await controller.animateCamera(CameraUpdate.newLatLngZoom(location, 16));
  }

  Future<void> _loadAndRenderOfflineRailLines() async {
    try {
      final geoJson = jsonDecode(
        await rootBundle.loadString('assets/transit/rail_lines.geojson'),
      );
      if (geoJson is! Map<String, dynamic>) {
        _showMessage('The bundled rail-line data is invalid.');
        return;
      }

      await _mapController?.addSource(
        'offline_rail_lines_source',
        GeojsonSourceProperties(data: geoJson),
      );
      await _mapController?.addLineLayer(
        'offline_rail_lines_source',
        'offline_rail_lines_layer',
        const LineLayerProperties(
          lineColor: [Expressions.get, 'color'],
          lineWidth: 4,
          lineOpacity: 0.85,
        ),
        minzoom: 8,
      );
    } on FormatException catch (error) {
      _showMessage('The bundled rail-line data is invalid.');
      debugPrint('Invalid offline rail-line JSON: $error');
    } catch (error) {
      _showMessage('Could not load bundled rail lines.');
      debugPrint('Offline rail-line error: $error');
    }
  }

  Future<void> _queryTappedFeature(dynamic point) async {
    final features = await _mapController?.queryRenderedFeatures(point, [
      'rail_stop_hit_targets_layer',
      'bus_stop_hit_targets_layer',
      'rail_stops_layer',
      'transit_stops_layer',
    ], null);
    if (features == null || features.isEmpty) return;

    final feature = features.first;
    if (feature is! Map || feature['properties'] is! Map) return;

    final properties = feature['properties'] as Map;
    final stopId = properties['id']?.toString();
    if (stopId == null || stopId.isEmpty) return;
    final stopName = properties['name']?.toString() ?? 'Selected stop';
    final routes =
        properties['routes']?.toString() ?? 'Route information unavailable';
    final transitType = properties['transit_type']?.toString() ?? 'transit';
    final stop = _transitStopsById[stopId];
    _showStopDetails(
      stopId: stopId,
      stopName: stopName,
      routes: routes,
      transitType: transitType,
      stop: stop,
    );
  }

  void _showStopDetails({
    required String stopId,
    required String stopName,
    required String routes,
    required String transitType,
    _TransitStop? stop,
  }) {
    Future<List<StopDeparture>> departureFuture = _fetchNextDepartures(stopId);
    Future<_TrafficCongestion?> congestionFuture = stop == null
        ? Future.value(null)
        : _fetchTrafficCongestion(stopId, stop.lat, stop.lon);
    final incidents = _fetchStopIncidents(stopId);
    Timer? refreshTimer;
    var refreshScheduled = false;
    final modalFuture = showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          // GTFS-Realtime vehicle positions are refreshed by the backend's
          // 20-second cache. Poll while this stop sheet is visible so live
          // estimates update without requiring the user to close and reopen it.
          if (!refreshScheduled) {
            refreshScheduled = true;
            refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
              setModalState(() {
                departureFuture = _fetchNextDepartures(stopId);
                if (stop != null) {
                  congestionFuture = _fetchTrafficCongestion(
                    stopId,
                    stop.lat,
                    stop.lon,
                  );
                }
              });
            });
          }
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
                        stopName,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${transitType == 'rail' ? 'Rail station' : 'Bus stop'} routes',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: stop == null
                            ? null
                            : () {
                                Navigator.of(context).pop();
                                _getDirectionsToPlace(
                                  stop.asPlaceSearchResult(),
                                );
                              },
                        icon: const Icon(Icons.directions),
                        label: const Text('Directions'),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: routes
                            .split(', ')
                            .map((route) => Chip(label: Text(route)))
                            .toList(),
                      ),
                      const SizedBox(height: 24),
                      FutureBuilder<List<StationIncident>>(
                        future: incidents,
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
                      FutureBuilder<_TrafficCongestion?>(
                        future: congestionFuture,
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
                        future: departureFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
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
                                    child: Text(
                                      'Departure times are unavailable.',
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () {
                                      Navigator.of(context).pop();
                                      _showStopDetails(
                                        stopId: stopId,
                                        stopName: stopName,
                                        routes: routes,
                                        transitType: transitType,
                                        stop: stop,
                                      );
                                    },
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Retry'),
                                  ),
                                ],
                              ),
                            );
                          }

                          final nextDepartures = snapshot.data ?? const [];
                          if (nextDepartures.isEmpty) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 8),
                                  child: Text(
                                    'No upcoming scheduled departures.',
                                  ),
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
                                  // Make the bound terminal the primary label:
                                  // e.g. "To Gombak   8:12 PM". Some GTFS feeds
                                  // supply a verbose "From A to B" headsign;
                                  // station cards should show only where this
                                  // particular departure is going.
                                  // The line remains visible beneath it.
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
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
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
        },
      ),
    );
    modalFuture.whenComplete(() => refreshTimer?.cancel());
  }

  Future<List<StopDeparture>> _fetchNextDepartures(String stopId) async {
    final cached = _departureCache[stopId];
    if (cached != null &&
        DateTime.now().difference(cached.loadedAt) <
            const Duration(seconds: 15)) {
      return cached.value;
    }
    final uri = Uri.parse(
      '$_backendBaseUrl/api/gtfs/stops/${Uri.encodeComponent(stopId)}/departures',
    ).replace(queryParameters: const {'limit': '6'});
    final response = await _httpClient
        .get(uri, headers: await backendHeaders())
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw StateError('Could not load departures.');
    }

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic> || data['departures'] is! List) {
      throw const FormatException('Invalid departure response.');
    }

    final departures = (data['departures'] as List<dynamic>)
        .whereType<Map>()
        .map(
          (departure) =>
              StopDeparture.fromJson(Map<String, dynamic>.from(departure)),
        )
        .toList();
    _departureCache[stopId] = _TimedCache(departures);
    return departures;
  }

  Future<List<StationIncident>> _fetchStopIncidents(String stopId) async {
    final cached = _incidentCache[stopId];
    if (cached != null &&
        DateTime.now().difference(cached.loadedAt) <
            const Duration(seconds: 30)) {
      return cached.value;
    }
    // Incident reports are stored directly in Supabase by this app; the GTFS
    // service intentionally has no incidents endpoint.
    const incidents = <StationIncident>[];
    _incidentCache[stopId] = _TimedCache(incidents);
    return incidents;
  }

  Future<_TrafficCongestion?> _fetchTrafficCongestion(
    String stationId,
    double latitude,
    double longitude,
  ) async {
    final cacheKey =
        '$stationId:${latitude.toStringAsFixed(4)},${longitude.toStringAsFixed(4)}';
    final cached = _trafficCache[cacheKey];
    if (cached != null &&
        DateTime.now().difference(cached.loadedAt) <
            const Duration(minutes: 1)) {
      return cached.value;
    }
    try {
      final uri = Uri.parse('$_backendBaseUrl/api/traffic/congestion').replace(
        queryParameters: {
          'lat': latitude.toStringAsFixed(6),
          'lon': longitude.toStringAsFixed(6),
          'station_id': stationId,
        },
      );
      final response = await _httpClient
          .get(uri, headers: await backendHeaders())
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body);
      if (data is! Map) return null;
      final congestion = _TrafficCongestion.fromJson(
        Map<String, dynamic>.from(data),
      );
      _trafficCache[cacheKey] = _TimedCache(congestion);
      return congestion;
    } catch (_) {
      return null;
    }
  }

  Widget _buildCongestionIndicator(_TrafficCongestion congestion) {
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

  Future<void> _loadAndRenderOfflineStops() async {
    try {
      final geoJson =
          await _loadBackendStopsGeoJson() ??
          jsonDecode(
            await rootBundle.loadString('assets/transit/stops.geojson'),
          );
      if (geoJson is! Map<String, dynamic>) {
        _showMessage('The bundled transit-stop data is invalid.');
        return;
      }

      final stopFeatures = (geoJson['features'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .toList();
      final stations = stopFeatures
          .whereType<Map>()
          .map((feature) => _TransitStation.fromGeoJson(feature))
          .whereType<_TransitStation>()
          .toList();
      final stops = stopFeatures
          .map((feature) => _TransitStop.fromGeoJson(feature))
          .whereType<_TransitStop>()
          .toList();
      final stopsById = <String, _TransitStop>{
        for (final stop in stops) stop.id: stop,
      };
      if (mounted) {
        setState(() {
          _railStations = stations;
          _transitStopsById = stopsById;
        });
        final position = _lastKnownPosition;
        if (position != null) _updateNearestStation(position);
      }

      // Prefer the current FastAPI catalogue; bundled stops keep the map useful
      // when the service is unavailable.
      await _mapController?.addSource(
        "offline_stops_source",
        GeojsonSourceProperties(data: geoJson),
      );

      await _mapController?.addCircleLayer(
        "offline_stops_source",
        "rail_stops_layer",
        const CircleLayerProperties(
          circleRadius: 7,
          circleColor: '#FF9500',
          circleStrokeWidth: 1.5,
          circleStrokeColor: '#FFFFFF',
        ),
        filter: [
          '==',
          ['get', 'transit_type'],
          'rail',
        ],
        minzoom: 11,
      );
      await _mapController?.addCircleLayer(
        "offline_stops_source",
        "transit_stops_layer",
        const CircleLayerProperties(
          circleRadius: 5,
          circleColor: '#007FFF',
          circleStrokeWidth: 1.5,
          circleStrokeColor: '#FFFFFF',
        ),
        filter: [
          '==',
          ['get', 'transit_type'],
          'bus',
        ],
        minzoom: 14,
      );
      // Invisible circles make small stop markers much easier to tap without
      // changing their visible size.
      await _mapController?.addCircleLayer(
        "offline_stops_source",
        "rail_stop_hit_targets_layer",
        const CircleLayerProperties(
          circleRadius: 20,
          circleColor: '#000000',
          circleOpacity: 0.01,
        ),
        filter: [
          '==',
          ['get', 'transit_type'],
          'rail',
        ],
        minzoom: 11,
      );
      await _mapController?.addCircleLayer(
        "offline_stops_source",
        "bus_stop_hit_targets_layer",
        const CircleLayerProperties(
          circleRadius: 20,
          circleColor: '#000000',
          circleOpacity: 0.01,
        ),
        filter: [
          '==',
          ['get', 'transit_type'],
          'bus',
        ],
        minzoom: 14,
      );
    } on FormatException catch (error) {
      _showMessage('The transit-stop data is invalid.');
      debugPrint('Invalid transit-stop JSON: $error');
    } catch (error) {
      _showMessage('Could not load transit stops.');
      debugPrint('Transit-stop error: $error');
    }
  }

  Future<Map<String, dynamic>?> _loadBackendStopsGeoJson() async {
    try {
      final response = await _httpClient
          .get(
            Uri.parse('$_backendBaseUrl/api/gtfs/stops'),
            headers: await backendHeaders(),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final document = jsonDecode(response.body);
      if (document is! Map || document['stops'] is! List) return null;

      final features = <Map<String, dynamic>>[];
      for (final item in document['stops'] as List) {
        if (item is! Map ||
            item['id'] == null ||
            item['name'] == null ||
            item['lat'] is! num ||
            item['lon'] is! num) {
          continue;
        }
        features.add({
          'type': 'Feature',
          'properties': {
            'id': item['id'].toString(),
            'name': item['name'].toString(),
            'transit_type': item['type'] == 'bus' ? 'bus' : 'rail',
            // GTFS stop catalogues do not carry every serving route. The
            // operator still gives useful context in the stop sheet.
            'routes': item['operator']?.toString() ?? '',
          },
          'geometry': {
            'type': 'Point',
            'coordinates': [
              (item['lon'] as num).toDouble(),
              (item['lat'] as num).toDouble(),
            ],
          },
        });
      }
      return {'type': 'FeatureCollection', 'features': features};
    } catch (error) {
      debugPrint('FastAPI stop catalogue unavailable: $error');
      return null;
    }
  }

  Future<void> _loadAndRenderStationPerimeters() async {
    try {
      final response = await _httpClient
          .get(
            Uri.parse('$_backendBaseUrl/api/gtfs/station-access'),
            headers: await backendHeaders(),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return;
      final document = jsonDecode(response.body);
      if (document is! Map || document['stations'] is! Map) return;

      final features = <Map<String, dynamic>>[];
      for (final entry in (document['stations'] as Map).entries) {
        final station = entry.value;
        if (station is! Map || station['perimeter'] is! Map) continue;
        final perimeter = station['perimeter'] as Map;
        if (perimeter['type'] != 'MultiPolygon' ||
            perimeter['coordinates'] is! List) {
          continue;
        }
        features.add({
          'type': 'Feature',
          'properties': {'id': entry.key.toString()},
          'geometry': perimeter,
        });
      }
      if (features.isEmpty || _mapController == null) return;

      // A map may be recreated after a hot restart, so layers are replaced
      // defensively rather than assuming this method only runs once.
      for (final layer in const [
        'station_perimeter_outline',
        'station_perimeter_fill',
      ]) {
        try {
          await _mapController!.removeLayer(layer);
        } catch (_) {}
      }
      try {
        await _mapController!.removeSource('station_perimeter_source');
      } catch (_) {}
      await _mapController!.addSource(
        'station_perimeter_source',
        GeojsonSourceProperties(
          data: {'type': 'FeatureCollection', 'features': features},
        ),
      );
      await _mapController!.addFillLayer(
        'station_perimeter_source',
        'station_perimeter_fill',
        const FillLayerProperties(fillColor: '#94A3B8', fillOpacity: 0.22),
        minzoom: 14,
      );
      await _mapController!.addLineLayer(
        'station_perimeter_source',
        'station_perimeter_outline',
        const LineLayerProperties(lineColor: '#64748B', lineWidth: 1.5),
        minzoom: 14,
      );
    } catch (error) {
      // Stop markers and routing remain available if the optional OSM-derived
      // station data has not yet been uploaded to the runtime volume.
      debugPrint('Station perimeter data unavailable: $error');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openEhailingStore() async {
    final storeUri = defaultTargetPlatform == TargetPlatform.iOS
        ? Uri.parse('https://apps.apple.com/my/search?term=e-hailing')
        : Uri.parse(
            'https://play.google.com/store/search?q=e-hailing%20Malaysia&c=apps',
          );
    if (!await launchUrl(storeUri, mode: LaunchMode.externalApplication)) {
      _showMessage('Could not open the app store.');
    }
  }

  String _formatTime(String rawTimestamp) {
    if (rawTimestamp.isEmpty) return '--:--';

    final int? milliseconds = int.tryParse(rawTimestamp);
    final DateTime? parsedTime = milliseconds == null
        ? DateTime.tryParse(rawTimestamp)
        : DateTime.fromMillisecondsSinceEpoch(milliseconds);
    if (parsedTime == null) return '--:--';

    // MOTIS returns ISO-8601 timestamps. Convert both legacy epoch values and
    // MOTIS timestamps to the device's local clock, without ever displaying a
    // date in the itinerary.
    final localTime = parsedTime.toLocal();

    // Format to standard 12-hour AM/PM string structure
    final int hour = localTime.hour == 0
        ? 12
        : (localTime.hour > 12 ? localTime.hour - 12 : localTime.hour);
    final String minute = localTime.minute.toString().padLeft(2, '0');
    final String period = localTime.hour >= 12 ? 'PM' : 'AM';

    return '$hour:$minute $period';
  }

  Future<void> _showLegIncidents(ItineraryLeg leg) async {
    if (leg.incidentReports.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Recent service reports',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              ...leg.incidentReports.map(
                (incident) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange,
                  ),
                  title: Text(incident.label),
                  subtitle: Text(incident.stationName),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNearestStationCard() {
    final station = _nearestStation;
    final position = _lastKnownPosition;
    final distance = station == null || position == null
        ? null
        : Geolocator.distanceBetween(
            position.latitude,
            position.longitude,
            station.lat,
            station.lon,
          );
    final distanceLabel = distance == null
        ? 'Finding the closest rail station…'
        : distance < 1000
        ? '${distance.round()} m away'
        : '${(distance / 1000).toStringAsFixed(1)} km away';

    return Card(
      elevation: 4,
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.train)),
        title: const Text('Nearest station'),
        subtitle: Text(station?.name ?? distanceLabel),
        trailing: station == null
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                onPressed: _focusNearestStation,
                child: Text(distanceLabel),
              ),
        onTap: station == null ? null : _focusNearestStation,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isOutsideSupportedZone) {
      return const Scaffold(body: _UnsupportedZoneScreen());
    }
    final isMapTab = _selectedTab == 0;
    final itineraryIsOpen = _selectedTab == 0 && _currentItinerary != null;
    return PopScope(
      canPop: !itineraryIsOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && itineraryIsOpen) _dismissItinerary();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leadingWidth: isMapTab && _isSearchOpen ? 118 : null,
          leading: isMapTab && _isSearchOpen
              ? const Padding(
                  padding: EdgeInsets.only(left: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _currentRegion,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
              : null,
          title: isMapTab && _isSearchOpen
              ? TextField(
                  key: const ValueKey('place-search-field'),
                  controller: _placeSearchController,
                  focusNode: _placeSearchFocusNode,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _searchPlaces(),
                  onChanged: _onPlaceSearchChanged,
                  decoration: const InputDecoration(
                    hintText: 'Search for a location',
                    border: InputBorder.none,
                  ),
                )
              : Text(isMapTab ? 'JomNaik' : 'Profile'),
          actions: isMapTab
              ? [
                  IconButton(
                    tooltip: _isSearchOpen
                        ? 'Close search'
                        : 'Search locations',
                    icon: Icon(_isSearchOpen ? Icons.close : Icons.search),
                    onPressed: _togglePlaceSearch,
                  ),
                ]
              : const [],
          elevation: 0,
        ),
        body: IndexedStack(
          index: _selectedTab,
          children: [
            _dynamicStyleString == null
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      MapLibreMap(
                        initialCameraPosition: const CameraPosition(
                          target: LatLng(3.1390, 101.6868),
                          zoom: 12,
                        ),
                        // Native MapLibre only guarantees reporting updated
                        // camera positions when this is enabled. Weather is
                        // keyed to the visible map centre, not device GPS.
                        trackCameraPosition: true,
                        onMapCreated: _onMapCreated,
                        onMapLongClick: (_, coordinate) =>
                            _showLongPressedLocation(coordinate),
                        onCameraMove: _onCameraMove,
                        onCameraIdle: _onCameraIdle,
                        styleString: _dynamicStyleString!,
                        // MapLibre's web implementation does not support
                        // custom compass margins. Leave them unset on web;
                        // native builds retain the layout above the buttons.
                        compassViewPosition: kIsWeb
                            ? CompassViewPosition.topRight
                            : CompassViewPosition.bottomRight,
                        compassViewMargins: kIsWeb
                            ? null
                            : const Point(16, 160),
                      ),
                      if (!_isSearchOpen)
                        Positioned(
                          top: 12,
                          left: 16,
                          right: 16,
                          child: SafeArea(
                            child: Row(
                              children: [
                                Expanded(child: _buildNearestStationCard()),
                                if (_weatherTemperature != null) ...[
                                  const SizedBox(width: 8),
                                  Card(
                                    elevation: 4,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 12,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.wb_sunny_outlined,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            '${_weatherTemperature!}${_weatherCondition == null ? '' : ' ${_weatherCondition!}'}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      if (_isSearchOpen &&
                          (_placeSearchResults.isNotEmpty ||
                              _selectedPlace != null))
                        Positioned(
                          top: 12,
                          left: 16,
                          right: 16,
                          child: SafeArea(
                            child: Material(
                              elevation: 4,
                              borderRadius: BorderRadius.circular(12),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_placeSearchResults.isNotEmpty)
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxHeight: 280,
                                      ),
                                      child: ListView.separated(
                                        shrinkWrap: true,
                                        itemCount: _placeSearchResults.length,
                                        separatorBuilder: (_, _) =>
                                            const Divider(height: 1),
                                        itemBuilder: (context, index) {
                                          final place =
                                              _placeSearchResults[index];
                                          return ListTile(
                                            title: Text(place.name),
                                            subtitle: Text(
                                              place.address,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            onTap: () => _selectPlace(place),
                                          );
                                        },
                                      ),
                                    ),
                                  if (_selectedPlace != null) ...[
                                    const Divider(height: 1),
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        12,
                                        8,
                                        12,
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  _selectedPlace!.name,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  _selectedPlace!.address,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          FilledButton.icon(
                                            onPressed:
                                                _getDirectionsToSelectedPlace,
                                            icon: const Icon(Icons.directions),
                                            label: const Text('Directions'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  if (_placeSearchResults.isNotEmpty ||
                                      _selectedPlace != null)
                                    const Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        16,
                                        0,
                                        16,
                                        8,
                                      ),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          'Search results © OpenStreetMap contributors',
                                          style: TextStyle(fontSize: 11),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (_currentItinerary == null && _canReportIncident)
                        Positioned(
                          left: 16,
                          bottom: 16,
                          child: SafeArea(
                            child: FloatingActionButton.extended(
                              heroTag: 'report-incident',
                              onPressed: _openIncidentReport,
                              icon: const Icon(Icons.report_problem_outlined),
                              label: const Text('Report'),
                            ),
                          ),
                        ),
                      if (_currentItinerary != null)
                        DraggableScrollableSheet(
                          initialChildSize: 0.25,
                          minChildSize: 0.15,
                          maxChildSize: 0.6,
                          builder: (BuildContext context, ScrollController scrollController) {
                            return Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(20),
                                ),
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
                                itemCount: _currentItinerary!.legs.length + 1,
                                itemBuilder: (context, index) {
                                  if (index == 0) {
                                    // Header Summary Card
                                    final weatherReminder =
                                        _weatherItineraryReminder(
                                          _currentItinerary!,
                                        );
                                    return Padding(
                                      padding: const EdgeInsets.all(16.0),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Center(
                                            child: Container(
                                              width: 40,
                                              height: 5,
                                              decoration: BoxDecoration(
                                                color: Colors.grey[300],
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 12),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  'Total Travel Time: ${_formatDuration(_currentItinerary!.duration)}',
                                                  style: const TextStyle(
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: 'Close itinerary',
                                                icon: const Icon(Icons.close),
                                                onPressed: _dismissItinerary,
                                              ),
                                            ],
                                          ),
                                          if (_currentItinerary!.fareAmount !=
                                              null)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                              ),
                                              child: Text(
                                                '${_currentItinerary!.fareLabel ?? 'Estimated fare'}: ${_fareLabel(_currentItinerary!)}',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          if (_currentItinerary!
                                                  .fallbackMessage !=
                                              null) ...[
                                            const SizedBox(height: 8),
                                            Text(
                                              _currentItinerary!
                                                  .fallbackMessage!,
                                              style: TextStyle(
                                                color: Colors.orange[800],
                                              ),
                                            ),
                                          ],
                                          if (weatherReminder != null) ...[
                                            const SizedBox(height: 8),
                                            Container(
                                              width: double.infinity,
                                              padding: const EdgeInsets.all(10),
                                              decoration: BoxDecoration(
                                                color: Colors.blue.shade50,
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                              ),
                                              child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  const Icon(
                                                    Icons.umbrella_outlined,
                                                    color: Colors.blue,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      weatherReminder,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                          const SizedBox(height: 8),
                                          _buildJourneyGuidanceCard(),
                                        ],
                                      ),
                                    );
                                  }

                                  final leg =
                                      _currentItinerary!.legs[index - 1];
                                  final isWalk =
                                      leg.mode.toUpperCase() == 'WALK';
                                  final isHail =
                                      leg.mode.toUpperCase() == 'HAIL';
                                  if (isWalk) {
                                    final walkwayLabel = leg.isSheltered
                                        ? 'Covered walkway'
                                        : 'Open walkway';
                                    return ListTile(
                                      leading: Icon(
                                        Icons.umbrella_outlined,
                                        color: leg.isSheltered
                                            ? Colors.teal
                                            : Colors.grey,
                                      ),
                                      title: Text(
                                        '${leg.isNearestStationAccess
                                            ? 'Walk via nearest pedestrian road to:'
                                            : leg.isTransferWalk
                                            ? 'Transfer via pedestrian route to'
                                            : 'Walk to'} ${leg.toPlace?.name ?? 'the next stop'}',
                                      ),
                                      subtitle: Text(
                                        '$walkwayLabel • ${leg.isNearestStationAccess ? 'Street route • ' : ''}${leg.fromPlace != null ? 'From ${leg.fromPlace!.name} • ' : ''}${_formatTime(leg.startTime)} - ${_formatTime(leg.endTime)}',
                                      ),
                                    );
                                  }
                                  if (isHail) {
                                    return ListTile(
                                      leading: const Icon(
                                        Icons.local_taxi,
                                        color: Colors.orange,
                                      ),
                                      title: Text(
                                        leg.routeShortName ??
                                            'E-hailing estimate',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      subtitle: Text(
                                        '${_formatTime(leg.startTime)} - ${_formatTime(leg.endTime)} • ${_currentItinerary!.fareAmount == null ? 'Direct distance estimate' : _fareLabel(_currentItinerary!)} planning estimate (excludes surge and tolls)\nPayment: ${leg.paymentMethod ?? 'Pay in the e-hailing app'}',
                                      ),
                                      trailing: TextButton.icon(
                                        onPressed: _openEhailingStore,
                                        icon: const Icon(
                                          Icons.open_in_new,
                                          size: 16,
                                        ),
                                        label: const Text('Find apps'),
                                      ),
                                    );
                                  }

                                  return ExpansionTile(
                                    leading: Icon(
                                      Icons.directions_bus,
                                      color: Colors.green,
                                    ),
                                    title: Wrap(
                                      spacing: 6,
                                      runSpacing: 2,
                                      children: [
                                        Text(
                                          leg.routeShortName
                                                      ?.trim()
                                                      .isNotEmpty ==
                                                  true
                                              ? leg.routeShortName!
                                              : 'Bus',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          '→ ${leg.headsign ?? 'Direction'}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        if (leg.incidentReports.isNotEmpty)
                                          IconButton(
                                            visualDensity:
                                                VisualDensity.compact,
                                            tooltip: 'View recent reports',
                                            icon: const Icon(
                                              Icons.warning_amber_rounded,
                                              color: Colors.orange,
                                            ),
                                            onPressed: () =>
                                                _showLegIncidents(leg),
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
                                          'Depart ${_formatTime(leg.startTime)} • Arrive ${_formatTime(leg.endTime)}',
                                        ),
                                        if (leg.paymentMethod != null)
                                          Text(
                                            '• Payment: ${leg.paymentMethod}',
                                          ),
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
                                      if (leg.intermediateStops.isEmpty)
                                        const Padding(
                                          padding: EdgeInsets.fromLTRB(
                                            72,
                                            0,
                                            16,
                                            8,
                                          ),
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              'No intermediate stops provided.',
                                            ),
                                          ),
                                        ),
                                      ...leg.intermediateStops
                                          .asMap()
                                          .entries
                                          .map((entry) {
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
                            );
                          },
                        ),
                    ],
                  ),
            _ProfilePage(
              onStationLocationTrackingChanged:
                  _setStationLocationTrackingEnabled,
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedTab,
          onDestinationSelected: _selectTab,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.map_outlined),
              selectedIcon: Icon(Icons.map),
              label: 'Map',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
        // The itinerary sheet owns the lower map while it is open, so it is
        // never obstructed by the map action buttons.
        floatingActionButton: _selectedTab == 0 && _currentItinerary == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FloatingActionButton(
                    heroTag: 'my-location',
                    onPressed: _showMyLocation,
                    tooltip: 'Show my location',
                    child: const Icon(Icons.my_location),
                  ),
                ],
              )
            : null,
      ),
    );
  }
}

class _ProfilePage extends StatefulWidget {
  const _ProfilePage({required this.onStationLocationTrackingChanged});

  final ValueChanged<bool> onStationLocationTrackingChanged;

  @override
  State<_ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<_ProfilePage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _isSubmitting = false;
  bool _obscurePassword = true;
  String? _message;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _isSubmitting = true;
      _message = null;
    });

    try {
      final auth = Supabase.instance.client.auth;
      if (_isSignUp) {
        final response = await auth.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
        if (!mounted) return;
        setState(() {
          _message = response.session == null
              ? 'Check your email to confirm your new account.'
              : 'Your account is ready.';
        });
      } else {
        final response = await auth.signInWithPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
        if (!mounted) return;
        if (response.session == null || auth.currentSession == null) {
          setState(() {
            _message =
                'Supabase did not create a sign-in session. Confirm the account email, then try again.';
          });
        }
      }
    } on AuthException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not reach the account service.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isSupabaseConfigured) return const _SupabaseSetupNotice();

    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, _) {
        final auth = Supabase.instance.client.auth;
        final user = auth.currentUser;
        if (user != null && auth.currentSession != null) {
          return _SignedInProfile(
            user: user,
            onStationLocationTrackingChanged:
                widget.onStationLocationTrackingChanged,
          );
        }

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Icon(Icons.account_circle, size: 72),
              const SizedBox(height: 16),
              Text(
                _isSignUp ? 'Create an account' : 'Welcome back',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _isSignUp
                    ? 'Save your preferences and access them on any device.'
                    : 'Sign in to manage your JomNaik account.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || !value.contains('@')) {
                          return 'Enter a valid email address.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      autofillHints: [
                        _isSignUp
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: _obscurePassword
                              ? 'Show password'
                              : 'Hide password',
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.length < 6) {
                          return 'Password must contain at least 6 characters.';
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) => _submit(),
                    ),
                  ],
                ),
              ),
              if (_message != null) ...[
                const SizedBox(height: 16),
                Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color:
                        _message!.startsWith('Could') ||
                            _message!.startsWith('Invalid')
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_isSignUp ? 'Sign up' : 'Sign in'),
                ),
              ),
              TextButton(
                onPressed: _isSubmitting
                    ? null
                    : () => setState(() {
                        _isSignUp = !_isSignUp;
                        _message = null;
                      }),
                child: Text(
                  _isSignUp
                      ? 'Already have an account? Sign in'
                      : 'New to JomNaik? Sign up',
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SignedInProfile extends StatefulWidget {
  const _SignedInProfile({
    required this.user,
    required this.onStationLocationTrackingChanged,
  });

  final User user;
  final ValueChanged<bool> onStationLocationTrackingChanged;

  @override
  State<_SignedInProfile> createState() => _SignedInProfileState();
}

class _SignedInProfileState extends State<_SignedInProfile> {
  bool _isSavingLocationTracking = false;

  bool get _locationTrackingEnabled =>
      widget.user.userMetadata?['station_location_tracking'] == true;

  Future<void> _setLocationTrackingEnabled(bool enabled) async {
    setState(() => _isSavingLocationTracking = true);
    try {
      final metadata = Map<String, dynamic>.from(
        widget.user.userMetadata ?? {},
      );
      metadata['station_location_tracking'] = enabled;
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(data: metadata),
      );
      widget.onStationLocationTrackingChanged(enabled);
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the tracking preference.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingLocationTracking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.account_circle, size: 72),
            const SizedBox(height: 16),
            Text(
              'You are signed in',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              widget.user.email ?? 'JomNaik account',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.location_searching),
              title: const Text('Station location tracking'),
              subtitle: const Text(
                'Ask which nearby station or stop you are at when an interchange has stops within 20 metres.',
              ),
              value: _locationTrackingEnabled,
              onChanged: _isSavingLocationTracking
                  ? null
                  : _setLocationTrackingEnabled,
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () => Supabase.instance.client.auth.signOut(),
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SupabaseSetupNotice extends StatelessWidget {
  const _SupabaseSetupNotice();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline, size: 64),
            const SizedBox(height: 20),
            Text(
              'Account sign-in is being set up',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text(
              'Add this app\'s Supabase URL and publishable key when building the app to enable sign-in and sign-up.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _UnsupportedZoneScreen extends StatelessWidget {
  const _UnsupportedZoneScreen();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.map_outlined,
                size: 72,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                'You are outside of supported zone',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'JomNaik currently supports only the Klang Valley map area.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Itinerary {
  const Itinerary({
    required this.duration,
    required this.legs,
    this.fallbackMessage,
    this.fareAmount,
    this.fareLabel,
    this.congestion,
  });

  factory Itinerary.fromJson(Map<String, dynamic> json) {
    final rawLegs = json['legs'];
    final fallback = json['fallback'];
    final fare = json['fare'];
    return Itinerary(
      duration: json['duration'] is num ? json['duration'] as num : 0,
      legs: rawLegs is List
          ? rawLegs
                .whereType<Map>()
                .map(
                  (leg) =>
                      ItineraryLeg.fromJson(Map<String, dynamic>.from(leg)),
                )
                .toList()
          : const [],
      fallbackMessage:
          json['fallbackMessage']?.toString() ??
          (fallback is Map ? fallback['message']?.toString() : null),
      fareAmount: fare is Map && fare['amount'] is num
          ? (fare['amount'] as num).toDouble()
          : null,
      fareLabel: fare is Map ? fare['label']?.toString() : null,
      congestion: json['congestion'] is Map
          ? Map<String, dynamic>.from(json['congestion'] as Map)
          : null,
    );
  }

  final num duration;
  final List<ItineraryLeg> legs;
  final String? fallbackMessage;
  final double? fareAmount;
  final String? fareLabel;
  final Map<String, dynamic>? congestion;
}

class ItineraryLeg {
  const ItineraryLeg({
    required this.mode,
    required this.startTime,
    required this.endTime,
    this.routeShortName,
    this.headsign,
    this.fromPlace,
    this.toPlace,
    this.isSheltered = false,
    this.isTransferWalk = false,
    this.isNearestStationAccess = false,
    this.paymentMethod,
    this.liveBusEstimate,
    this.intermediateStops = const [],
    this.incidentReports = const [],
  });

  factory ItineraryLeg.fromJson(Map<String, dynamic> json) {
    final from = json['from'];
    final to = json['to'];
    return ItineraryLeg(
      mode: json['mode']?.toString() ?? 'UNKNOWN',
      startTime: _legTime(
        json['startTime'],
        from is Map ? from['departure'] ?? from['scheduledDeparture'] : null,
      ),
      endTime: _legTime(
        json['endTime'],
        to is Map ? to['arrival'] ?? to['scheduledArrival'] : null,
      ),
      routeShortName: json['routeShortName']?.toString(),
      headsign: json['headsign']?.toString(),
      fromPlace: ItineraryPlace.fromJsonOrNull(json['from']),
      toPlace: ItineraryPlace.fromJsonOrNull(json['to']),
      isSheltered: json['isSheltered'] == true,
      isTransferWalk: json['isTransferWalk'] == true,
      isNearestStationAccess: json['isNearestStationAccess'] == true,
      paymentMethod: json['paymentMethod']?.toString(),
      liveBusEstimate: LiveBusEstimate.fromJsonOrNull(json['liveBusEstimate']),
      intermediateStops: _intermediateStopsFromJson(json['intermediateStops']),
      incidentReports: _legIncidentsFromJson(json['incidentReports']),
    );
  }

  final String mode;
  final String startTime;
  final String endTime;
  final String? routeShortName;
  final String? headsign;
  final ItineraryPlace? fromPlace;
  final ItineraryPlace? toPlace;
  final bool isSheltered;
  final bool isTransferWalk;
  final bool isNearestStationAccess;
  final String? paymentMethod;
  final LiveBusEstimate? liveBusEstimate;
  final List<IntermediateStop> intermediateStops;
  final List<LegIncident> incidentReports;

  static String _legTime(dynamic primary, dynamic fallback) {
    final value = primary ?? fallback;
    return value?.toString() ?? '';
  }
}

class LegIncident {
  const LegIncident({
    required this.stationName,
    required this.type,
    this.route,
  });

  factory LegIncident.fromJson(Map<String, dynamic> json) => LegIncident(
    stationName: json['stationName']?.toString() ?? 'Affected station',
    type: json['type']?.toString() ?? 'disruption',
    route: json['route']?.toString(),
  );

  final String stationName;
  final String type;
  final String? route;

  String get label => _incidentLabel(type, route);
}

class LiveBusEstimate {
  const LiveBusEstimate({
    required this.timestamp,
    required this.trafficAdjusted,
  });

  static LiveBusEstimate? fromJsonOrNull(dynamic value) {
    if (value is! Map || value['timestamp'] is! num) return null;
    return LiveBusEstimate(
      timestamp: (value['timestamp'] as num).toInt(),
      trafficAdjusted: value['trafficAdjusted'] == true,
    );
  }

  String get minutesRemaining {
    final seconds = (DateTime.fromMillisecondsSinceEpoch(
      timestamp,
    ).difference(DateTime.now()).inSeconds).clamp(0, 7200);
    if (seconds < 60) return 'due now';
    return 'in ${(seconds / 60).ceil()} min';
  }

  final int timestamp;
  final bool trafficAdjusted;
}

class ItineraryPlace {
  const ItineraryPlace({required this.name, this.lat, this.lon});

  static ItineraryPlace? fromJsonOrNull(dynamic value) {
    if (value is! Map || value['name'] == null) return null;
    return ItineraryPlace(
      name: value['name'].toString(),
      lat: value['lat'] is num ? (value['lat'] as num).toDouble() : null,
      lon: value['lon'] is num ? (value['lon'] as num).toDouble() : null,
    );
  }

  final String name;
  final double? lat;
  final double? lon;
}

List<IntermediateStop> _intermediateStopsFromJson(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((stop) => IntermediateStop.fromJson(Map<String, dynamic>.from(stop)))
      .toList();
}

List<LegIncident> _legIncidentsFromJson(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map(
        (incident) => LegIncident.fromJson(Map<String, dynamic>.from(incident)),
      )
      .toList();
}

class IntermediateStop {
  const IntermediateStop({
    required this.name,
    required this.lat,
    required this.lon,
  });

  factory IntermediateStop.fromJson(Map<String, dynamic> json) {
    return IntermediateStop(
      name: json['name']?.toString() ?? 'Unnamed stop',
      lat: json['lat'] is num ? (json['lat'] as num).toDouble() : 0,
      lon: json['lon'] is num ? (json['lon'] as num).toDouble() : 0,
    );
  }

  final String name;
  final double lat;
  final double lon;
}

enum _IncidentType {
  stuckTrain(
    'Stuck train for over 5 minutes',
    'A train has been stationary longer than expected.',
    Icons.train,
    false,
  ),
  crowding(
    'Crowding',
    'The platform, station or vehicle is unusually crowded.',
    Icons.groups,
    false,
  ),
  disruption(
    'Service disruption',
    'There is a delay, closure or other service issue.',
    Icons.warning_amber_rounded,
    false,
  ),
  safety(
    'Safety or accessibility issue',
    'Report a safety concern or an accessibility obstruction.',
    Icons.accessible,
    false,
  ),
  busNotArrived(
    'Bus has not arrived for over 10 minutes',
    'Report an overdue bus for the selected route.',
    Icons.schedule,
    true,
  ),
  busCrowding(
    'Bus crowding',
    'The selected bus is unusually crowded.',
    Icons.groups,
    true,
  ),
  busBreakdown(
    'Bus breakdown or service issue',
    'The selected bus is not operating normally.',
    Icons.build_circle_outlined,
    true,
  ),
  busSafety(
    'Bus safety or accessibility issue',
    'Report a safety concern or accessibility obstruction.',
    Icons.accessible,
    true,
  );

  const _IncidentType(this.label, this.description, this.icon, this.isBus);

  final String label;
  final String description;
  final IconData icon;
  final bool isBus;
}

class _TimedCache<T> {
  _TimedCache(this.value) : loadedAt = DateTime.now();

  final T value;
  final DateTime loadedAt;
}

class _TransitStation {
  const _TransitStation({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
  });

  static _TransitStation? fromGeoJson(Map feature) {
    final properties = feature['properties'];
    final geometry = feature['geometry'];
    if (properties is! Map || geometry is! Map) return null;
    if (properties['transit_type']?.toString() != 'rail') return null;
    final coordinates = geometry['coordinates'];
    if (coordinates is! List || coordinates.length < 2) return null;
    final lon = coordinates[0];
    final lat = coordinates[1];
    if (lon is! num || lat is! num || properties['id'] == null) return null;
    return _TransitStation(
      id: properties['id'].toString(),
      name: properties['name']?.toString() ?? 'Rail station',
      lat: lat.toDouble(),
      lon: lon.toDouble(),
    );
  }

  final String id;
  final String name;
  final double lat;
  final double lon;
}

class _TransitStop {
  const _TransitStop({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.transitType,
    required this.routes,
  });

  static _TransitStop? fromGeoJson(Map feature) {
    final properties = feature['properties'];
    final geometry = feature['geometry'];
    if (properties is! Map || geometry is! Map) return null;
    final coordinates = geometry['coordinates'];
    if (coordinates is! List || coordinates.length < 2) return null;
    final lon = coordinates[0];
    final lat = coordinates[1];
    if (lon is! num || lat is! num || properties['id'] == null) return null;
    return _TransitStop(
      id: properties['id'].toString(),
      name: properties['name']?.toString() ?? 'Transit stop',
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      transitType: properties['transit_type']?.toString() ?? 'bus',
      routes: properties['routes']?.toString() ?? '',
    );
  }

  PlaceSearchResult asPlaceSearchResult() => PlaceSearchResult(
    name: name,
    address: 'Selected transit stop',
    lat: lat,
    lon: lon,
    stopId: id,
  );

  final String id;
  final String name;
  final double lat;
  final double lon;
  final String transitType;
  final String routes;
}

class PlaceSearchResult {
  const PlaceSearchResult({
    required this.name,
    required this.address,
    required this.lat,
    required this.lon,
    this.stopId,
  });

  factory PlaceSearchResult.fromJson(Map<String, dynamic> json) {
    return PlaceSearchResult(
      name: json['name']?.toString() ?? 'Selected location',
      address: json['address']?.toString() ?? '',
      lat: json['lat'] is num ? (json['lat'] as num).toDouble() : 0,
      lon: json['lon'] is num ? (json['lon'] as num).toDouble() : 0,
      stopId: json['stop_id']?.toString(),
    );
  }

  final String name;
  final String address;
  final double lat;
  final double lon;
  final String? stopId;
}

class StopDeparture {
  const StopDeparture({
    required this.route,
    required this.time,
    required this.timestamp,
    required this.isEstimated,
    required this.direction,
  });

  factory StopDeparture.fromJson(Map<String, dynamic> json) {
    return StopDeparture(
      route: json['route']?.toString() ?? 'Transit service',
      time: json['time']?.toString() ?? '--:--',
      timestamp: json['timestamp'] is num
          ? (json['timestamp'] as num).toInt()
          : 0,
      isEstimated: json['is_estimated'] == true,
      // FastAPI returns the GTFS terminal under `terminal` and only provides
      // scheduled times. Retain the older name for compatibility.
      direction:
          json['terminal']?.toString() ?? json['direction']?.toString() ?? '',
    );
  }

  final String route;
  final String time;
  final int timestamp;
  final bool isEstimated;
  final String direction;

  String get displayDirection {
    var destination = direction.trim();
    final lowerCase = destination.toLowerCase();
    if (lowerCase.startsWith('from ')) {
      final toIndex = lowerCase.indexOf(' to ');
      if (toIndex >= 0) destination = destination.substring(toIndex + 4).trim();
    }
    if (destination.toLowerCase().startsWith('to ')) {
      destination = destination.substring(3).trim();
    }
    return destination.isEmpty ? '' : 'To $destination';
  }

  String get minutesRemaining {
    if (timestamp <= 0) return 'Arriving soon';
    final secondsRemaining = DateTime.fromMillisecondsSinceEpoch(
      timestamp,
    ).difference(DateTime.now()).inSeconds;
    if (secondsRemaining <= 60) return '< 1 min';
    return '${(secondsRemaining / 60).ceil()} min away';
  }
}

class _TrafficCongestion {
  const _TrafficCongestion({
    required this.level,
    required this.roadLevel,
    required this.currentSpeedKph,
    required this.freeFlowSpeedKph,
    required this.delayPercent,
    this.observedUsers,
    this.capacity,
    this.stationLevel,
  });

  factory _TrafficCongestion.fromJson(Map<String, dynamic> json) {
    return _TrafficCongestion(
      level: json['level']?.toString() ?? 'unavailable',
      roadLevel:
          json['roadLevel']?.toString() ??
          json['level']?.toString() ??
          'unavailable',
      currentSpeedKph: (json['currentSpeedKph'] as num?)?.toDouble() ?? 0,
      freeFlowSpeedKph: (json['freeFlowSpeedKph'] as num?)?.toDouble() ?? 0,
      delayPercent: (json['delayPercent'] as num?)?.toDouble(),
      observedUsers:
          json['stationPresence'] is Map &&
              (json['stationPresence'] as Map)['observedUsers'] is num
          ? ((json['stationPresence'] as Map)['observedUsers'] as num).toInt()
          : null,
      capacity:
          json['stationPresence'] is Map &&
              (json['stationPresence'] as Map)['capacity'] is num
          ? ((json['stationPresence'] as Map)['capacity'] as num).toInt()
          : null,
      stationLevel: json['stationPresence'] is Map
          ? (json['stationPresence'] as Map)['level']?.toString()
          : null,
    );
  }

  final String level;
  final String roadLevel;
  final double currentSpeedKph;
  final double freeFlowSpeedKph;
  final double? delayPercent;
  final int? observedUsers;
  final int? capacity;
  final String? stationLevel;

  String get label {
    if (roadLevel == 'road_closed') return 'TomTom traffic: nearby road closed';
    final roadStatus = switch (roadLevel) {
      'heavy' => 'Heavy traffic',
      'moderate' => 'Moderate traffic',
      'low' => 'Light traffic',
      _ => 'Traffic unavailable',
    };
    final delay = delayPercent == null
        ? ''
        : ' • ${delayPercent!.round()}% slower';
    final presence = observedUsers == null
        ? ''
        : capacity == null
        ? ' • $observedUsers recent station users'
        : ' • Station ${stationLevel ?? 'occupancy'}: $observedUsers/$capacity';
    return 'Congestion Status: $roadStatus • ${currentSpeedKph.round()} km/h$delay$presence';
  }
}

class StationIncident {
  const StationIncident({required this.type, required this.count, this.route});

  factory StationIncident.fromJson(Map<String, dynamic> json) {
    return StationIncident(
      type: json['type']?.toString() ?? 'disruption',
      count: json['count'] is num ? (json['count'] as num).toInt() : 1,
      route: json['route']?.toString(),
    );
  }

  final String type;
  final int count;
  final String? route;

  String get label => _incidentLabel(type, route);
}

String _incidentLabel(String type, String? route) {
  final bus = route == null || route.trim().isEmpty ? 'Bus' : 'Bus $route';
  return switch (type) {
    'stuckTrain' => 'Train has been stationary for over 5 minutes',
    'missingBus' => 'Bus or BRT has not arrived for over 10 minutes',
    'crowding' => 'Crowding reported',
    'safety' => 'Safety or accessibility issue reported',
    'busNotArrived' => '$bus has not arrived for over 10 minutes',
    'busCrowding' => '$bus crowding reported',
    'busBreakdown' => '$bus breakdown or service issue reported',
    'busSafety' => '$bus safety or accessibility issue reported',
    _ => 'Service disruption reported',
  };
}
