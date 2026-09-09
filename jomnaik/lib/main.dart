import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'screens/startup_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'map_tiles_source.dart';
import 'widgets/live_guidance_card.dart';
import 'offline_raptor_router.dart';
import 'services/routing_service.dart';
import 'models/itinerary.dart';
import 'models/search.dart';
import 'models/transit.dart';
import 'controllers/journey_guidance_controller.dart';
import 'screens/profile_screen.dart';
import 'widgets/itinerary_sheet.dart';
import 'widgets/route_choices_sheet.dart';
import 'widgets/station_details_sheet.dart';
import 'widgets/incident_report_sheet.dart';
import 'services/api_service.dart';

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
  if (kIsWeb) return 'https://jomnaik2-production.up.railway.app';
  if (defaultTargetPlatform == TargetPlatform.android) {
    return 'https://jomnaik2-production.up.railway.app';
  }
  return 'https://jomnaik2-production.up.railway.app';
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
    return MaterialApp(
      title: 'JomNaik Map', 
      home: StartupScreen(
        nextScreen: const MapView(),
        storage: _privacyStorage, // Pass the storage instance
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
  int _completedJourneyCount = 0;
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
  final Set<String> _submittedIncidentKeys = <String>{};
  List<TransitStation> _railStations = const [];
  Map<String, TransitStop> transitStopsById = const {};
  TransitStation? _nearestStation;
  int _selectedTab = 0;
  late final RoutingService _routingService;
  late final JourneyGuidanceController _guidanceController;
  late final ApiService _apiService;
  final Map<String, TransitStop> _transitStopsById = const {};

  bool get _canReportIncident =>
      _isSupabaseConfigured &&
      Supabase.instance.client.auth.currentUser != null &&
      Supabase.instance.client.auth.currentSession != null;

  @override
  void initState() {
    super.initState();
    unawaited(_offlineRaptorRouter.refreshFromBackend(_backendBaseUrl));

    // Initialize the routing service
    _routingService = RoutingService(
      httpClient: _httpClient,
      backendBaseUrl: _backendBaseUrl,
      offlineRouter: _offlineRaptorRouter,
    );

    _guidanceController = JourneyGuidanceController(
    routingService: _routingService,
    onMessage: _showMessage,
    onJourneyCompleted: _recordCompletedJourney,
    );

    _apiService = ApiService(
    httpClient: _httpClient,
    backendBaseUrl: _backendBaseUrl,
    );

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
    _guidanceController.dispose();
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
    });
    if (index == 0 && _lastKnownPosition != null) {
      unawaited(_askForNearbyStationChoice(_lastKnownPosition!));
    }
  }

Future<void> _prepareMapData() async {
  try {
    // Attempt standard PMTiles / Protomaps vector style load
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

    final tileUrl = await mapTilesSourceUrl();
    if (tileUrl.isEmpty && _isComputerPlatform) {
      throw Exception('Tile source URL is unavailable on computer platform.');
    }

    (sources['protomaps'] as Map<String, dynamic>)['url'] = tileUrl;

    if (!mounted) return;
    setState(() => _dynamicStyleString = jsonEncode(styleData));
  } catch (error) {
    debugPrint(
      'Vector tile initialization failed ($error). Falling back to OpenStreetMap raster tiles.',
    );

    if (!mounted) return;
    // Fall back to OSM raster style string
    setState(() => _dynamicStyleString = jsonEncode(_osmFallbackStyle));
  }
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
    final data = await _apiService.fetchWeather(
        centre.latitude,
        centre.longitude,
        requestVersion,
      );

      if (data != null &&
          data['current_temp'] is num &&
          mounted &&
          requestVersion == _weatherRequestVersion) {
        setState(() {
          _weatherCentre = centre;
          _weatherTemperature = '${(data['current_temp'] as num).toStringAsFixed(1)}°';
          _weatherCondition = data['forecast']?.toString();
        });
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

  Future<void> _clearSelectedPlaceMarker() async {
    final marker = _selectedPlaceMarker;
    final controller = _mapController;
    _selectedPlaceMarker = null;
    if (marker != null && controller != null) {
      await controller.removeCircle(marker);
    }
  }

Future<List<PlaceSearchResult>> _findPlaces(String query) async {
    final results = await _apiService.searchPlaces(query);
    if (results != null && results.isNotEmpty) {
      return results;
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

  if (_routeRequestInFlight) return;
  _routeRequestInFlight = true;

  try {
    final routeData = await _routingService.getRoute(
      fromLat: originLat,
      fromLon: originLon,
      toLat: destination.lat,
      toLon: destination.lon,
      fromStopId: origin == null ? selectedStart!.stopId : null,
      toStopId: destination.stopId,
      onMessage: _showMessage,
    );
    await _showRouteChoices(routeData);
  } finally {
    _routeRequestInFlight = false;
  }
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
        final rawLegs = itinerary['legs'];
        final legs = rawLegs is List ? rawLegs.whereType<Map>().toList() : [];
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
      builder: (context) => RouteChoicesSheet(
        itineraries: itineraries,
        onSelectItinerary: _applyItinerary,
      ),
    );
  }

  Future<void> _applyItinerary(Map<String, dynamic> itinerary) async {
    FocusScope.of(context).unfocus();
    _placeSearchDebounce?.cancel();
    if (mounted) {
      setState(() {
        _placeSearchRequestId++;
        _placeSearchController.clear();
        _selectedPlace = null;
        _placeSearchResults = const [];
        _isSearchingPlaces = false;
      });
      unawaited(_clearSelectedPlaceMarker());
    }
    
    // Inline the raw legs extraction here
    final rawLegs = itinerary['legs'];
    final legs = rawLegs is List
        ? rawLegs.whereType<Map>().map(Map<String, dynamic>.from).toList()
        : const <Map<String, dynamic>>[];
        
    final renderGeneration = ++_itineraryRenderGeneration;
    if (!mounted) return;
    
    // Open the details immediately. Map rendering is asynchronous and should
    // never make a valid itinerary appear to have failed to load.
    setState(() {
      _currentItinerary = Itinerary.fromJson(itinerary);
    });
    
    _guidanceController.setItinerary(_currentItinerary); 
    unawaited(_renderItinerary(legs, renderGeneration));
  }

  /// Checks if the application is running on Web or Desktop platforms (macOS, Windows, Linux).
bool get _isComputerPlatform {
  if (kIsWeb) return true;
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return true;
    default:
      return false;
  }
}

/// Fallback MapLibre JSON style pointing to standard OpenStreetMap raster tiles.
Map<String, dynamic> get _osmFallbackStyle => {
      'version': 8,
      'sources': {
        'osm-raster-tiles': {
          'type': 'raster',
          'tiles': [
            'https://a.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
          ],
          'tileSize': 256,
          'attribution': '© OpenStreetMap contributors © CARTO',
        },
      },
      'layers': [
        {
          'id': 'osm-raster-layer',
          'type': 'raster',
          'source': 'osm-raster-tiles',
          'minzoom': 0,
          'maxzoom': 19,
        },
      ],
    };

  Widget _buildJourneyGuidanceCard() {
    return ListenableBuilder(
      listenable: _guidanceController,
      builder: (context, _) {
        final itinerary = _currentItinerary;
        if (itinerary == null || itinerary.legs.isEmpty) {
          return const SizedBox.shrink();
        }

        final hasCurrentLeg = _guidanceController.guidedLegIndex < itinerary.legs.length;
        final leg = hasCurrentLeg ? itinerary.legs[_guidanceController.guidedLegIndex] : null;
        
        // You'll need to check mode locally for the UI layout, or expose a helper in the controller
        final isTransit = leg != null && leg.mode.toUpperCase() != 'WALK' && leg.mode.toUpperCase() != 'HAIL';
        
        final atBoardingStop = _guidanceController.isActive &&
            leg != null &&
            isTransit &&
            !_guidanceController.hasBoardedTransit &&
            (_guidanceController.distanceMeters ?? double.infinity) <= 90;

        return LiveGuidanceCard(
          isActive: _guidanceController.isActive,
          hasCurrentStep: hasCurrentLeg,
          currentStep: _guidanceController.guidedLegIndex + 1,
          totalSteps: itinerary.legs.length,
          message: _guidanceController.message ??
              'Use your live location to advance each journey step.',
          showBoardedAction: atBoardingStop,
          isReplanning: _guidanceController.isReplanning,
          isCompleted: _guidanceController.hasCompleted,
          completedTrips: _completedJourneyCount,
          onStart: () => _guidanceController.startGuidance(_lastKnownPosition),
          onBoarded: _guidanceController.markTransitBoarded,
          onReplan: _guidanceController.replanJourney,
          onStop: _guidanceController.stopGuidance,
        );
      },
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

Future<void> _drawItinerary(
  List<Map<String, dynamic>> legs,
  int renderGeneration,
) async {
  debugPrint(
    '🗺️ _drawItinerary STARTED. Processing ${legs.length} legs...',
  );

  // ------------------------------------------------------------
  // 1. Make sure this is still the active render before doing
  //    expensive map operations.
  // ------------------------------------------------------------

  if (!_isCurrentItineraryRender(renderGeneration)) {
    debugPrint('⏭️ Stale itinerary render. Aborting.');
    return;
  }

  // ------------------------------------------------------------
  // 2. Remove previous route layers/sources.
  // ------------------------------------------------------------

  await _removeRouteLayerSafely('route_walk_layer');
  await _removeRouteLayerSafely('route_ehailing_layer');
  await _removeRouteLayerSafely('route_transit_layer');

  await _removeRouteSourceSafely('route_walk_source');
  await _removeRouteSourceSafely('route_ehailing_source');
  await _removeRouteSourceSafely('route_transit_source');

  if (!_isCurrentItineraryRender(renderGeneration)) {
    return;
  }

  // ------------------------------------------------------------
  // 3. Separate route geometries by actual transport mode.
  // ------------------------------------------------------------

  final walkFeatures = <Map<String, dynamic>>[];
  final transitFeatures = <Map<String, dynamic>>[];
  final ehailingFeatures = <Map<String, dynamic>>[];

  final routeCoordinates = <List<double>>[];

  bool hasGeometry = false;

  for (final leg in legs) {
    if (!_isCurrentItineraryRender(renderGeneration)) {
      debugPrint('⏭️ Render became stale while processing legs.');
      return;
    }

    final mode = (leg['mode']?.toString() ?? 'WALK').toUpperCase();

    debugPrint('🚦 Processing leg mode: $mode');

    // ----------------------------------------------------------
    // Ignore geometry explicitly marked as unverified.
    // ----------------------------------------------------------

    if (leg['geometryQuality'] == 'unverified') {
      debugPrint(
        '⚠️ Skipping unverified geometry for $mode',
      );
      continue;
    }

List<List<double>> _extractLegCoordinates(
  Map<String, dynamic> leg,
) {
  final geometry = leg['legGeometry'] ?? leg['geometry'];

  // ------------------------------------------------------------
  // Case 1:
  // Geometry is already a decoded coordinate array.
  // ------------------------------------------------------------
  if (geometry is List) {
    return _parseCoordinateList(geometry);
  }

  // ------------------------------------------------------------
  // Case 2:
  // Geometry is a Map.
  // ------------------------------------------------------------
  if (geometry is Map) {
    final coordinates = geometry['coordinates'];

    if (coordinates is List) {
      final parsed = _parseCoordinateList(coordinates);
      if (parsed.isNotEmpty) {
        return parsed;
      }
    }

    // Encoded polyline.
    final encoded = geometry['points'] ?? geometry['polyline'];

    if (encoded is String && encoded.isNotEmpty) {
      final precision = geometry['precision'] is num
          ? (geometry['precision'] as num).toInt()
          : 5;

      try {
        return _decodePolyline(encoded, precision: precision);
      } catch (error) {
        debugPrint('❌ Polyline decoding failed: $error');
      }
    }
  }

  // ------------------------------------------------------------
  // Case 3:
  // Geometry itself is an encoded polyline string.
  // ------------------------------------------------------------
  if (geometry is String && geometry.isNotEmpty) {
    try {
      return _decodePolyline(geometry, precision: 5);
    } catch (error) {
      debugPrint('❌ Polyline decoding failed: $error');
    }
  }

  // ------------------------------------------------------------
  // Final fallback: No valid geometry found.
  // Return an empty list so we DON'T draw a straight line.
  // ------------------------------------------------------------
  
  return []; // <-- Changed from "return geometry;"
}

    final legCoordinates = _extractLegCoordinates(leg);

    if (legCoordinates.isEmpty) {
      debugPrint(
        '❌ No geometry available for $mode.',
      );
      continue;
    }

    debugPrint(
      '✅ Extracted ${legCoordinates.length} coordinates for $mode.',
    );

    hasGeometry = true;
    routeCoordinates.addAll(legCoordinates);

    final feature = <String, dynamic>{
      'type': 'Feature',
      'properties': {
        'mode': mode,
      },
      'geometry': {
        'type': 'LineString',
        'coordinates': legCoordinates,
      },
    };

    // ----------------------------------------------------------
    // Classify the leg properly.
    // ----------------------------------------------------------

    if (_isWalkingMode(mode)) {
      walkFeatures.add(feature);
    } else if (_isEHailingMode(mode)) {
      ehailingFeatures.add(feature);
    } else {
      transitFeatures.add(feature);
    }
  }

  debugPrint(
    '🏁 Geometry extraction complete. '
    'hasGeometry=$hasGeometry '
    'walk=${walkFeatures.length} '
    'transit=${transitFeatures.length} '
    'ehailing=${ehailingFeatures.length}',
  );

  if (!hasGeometry) {
    if (_isCurrentItineraryRender(renderGeneration)) {
      _showMessage(
        'The selected route has no map geometry.',
      );
    }
    return;
  }

  if (!_isCurrentItineraryRender(renderGeneration)) {
    return;
  }

  // ------------------------------------------------------------
  // 4. WALKING
  // ------------------------------------------------------------

  if (walkFeatures.isNotEmpty) {
    if (!_isCurrentItineraryRender(renderGeneration)) {
      return;
    }

    debugPrint('🎨 Adding WALK layer...');

    await _mapController?.addSource(
      'route_walk_source',
      GeojsonSourceProperties(
        data: {
          'type': 'FeatureCollection',
          'features': walkFeatures,
        },
      ),
    );

    if (!_isCurrentItineraryRender(renderGeneration)) {
      return;
    }

    await _mapController?.addLineLayer(
      'route_walk_source',
      'route_walk_layer',
      const LineLayerProperties(
        lineColor: '#64748B',
        lineWidth: 4.0,
        lineOpacity: 0.85,
        lineDasharray: [2.0, 2.0],
        lineCap: 'round',
        lineJoin: 'round',
      ),
    );
  }

  // ------------------------------------------------------------
  // 5. PUBLIC TRANSPORT
  // ------------------------------------------------------------

  if (transitFeatures.isNotEmpty) {
    if (!_isCurrentItineraryRender(renderGeneration)) {
      return;
    }

    debugPrint('🎨 Adding TRANSIT layer...');

    await _mapController?.addSource(
      'route_transit_source',
      GeojsonSourceProperties(
        data: {
          'type': 'FeatureCollection',
          'features': transitFeatures,
        },
      ),
    );

    if (!_isCurrentItineraryRender(renderGeneration)) {
      return;
    }

    await _mapController?.addLineLayer(
      'route_transit_source',
      'route_transit_layer',
      const LineLayerProperties(
        lineColor: '#FF3B30',
        lineWidth: 6.0,
        lineOpacity: 0.95,
        lineCap: 'round',
        lineJoin: 'round',
      ),
    );
  }

  // ------------------------------------------------------------
  // 6. E-HAILING
  // ------------------------------------------------------------

  if (ehailingFeatures.isNotEmpty) {
    if (!_isCurrentItineraryRender(renderGeneration)) {
      return;
    }

    debugPrint('🎨 Adding E-HAILING layer...');

    await _mapController?.addSource(
      'route_ehailing_source',
      GeojsonSourceProperties(
        data: {
          'type': 'FeatureCollection',
          'features': ehailingFeatures,
        },
      ),
    );

    if (!_isCurrentItineraryRender(renderGeneration)) {
      return;
    }

    await _mapController?.addLineLayer(
      'route_ehailing_source',
      'route_ehailing_layer',
      const LineLayerProperties(
        lineColor: '#2563EB',
        lineWidth: 5.0,
        lineOpacity: 0.90,
        lineCap: 'round',
        lineJoin: 'round',
        lineDasharray: [1.0, 1.5],
      ),
    );
  }

  // ------------------------------------------------------------
  // 7. Fit map to complete itinerary.
  // ------------------------------------------------------------

  if (!_isCurrentItineraryRender(renderGeneration)) {
    return;
  }

  if (routeCoordinates.isNotEmpty) {
    await _focusItineraryOnMap(
      routeCoordinates,
    );
  }

  debugPrint('🗺️ _drawItinerary FINISHED.');
}

List<List<double>> _parseCoordinateList(
  List coordinates,
) {
  final result = <List<double>>[];

  for (final coordinate in coordinates) {
    if (coordinate is! List ||
        coordinate.length < 2) {
      continue;
    }

    final lon = coordinate[0];
    final lat = coordinate[1];

    if (lon is! num || lat is! num) {
      continue;
    }

    final longitude = lon.toDouble();
    final latitude = lat.toDouble();

    // Basic geographic sanity check.
    if (longitude < -180 ||
        longitude > 180 ||
        latitude < -90 ||
        latitude > 90) {
      continue;
    }

    // IMPORTANT:
    // GeoJSON / MapLibre = [longitude, latitude]
    result.add([
      longitude,
      latitude,
    ]);
  }

  return result;
}

  bool _isWalkingMode(String mode) {
    return mode == 'WALK' ||
        mode == 'WALKING' ||
        mode == 'FOOT';
  }

  bool _isEHailingMode(String mode) {
    return mode == 'HAIL' ||
        mode == 'EHAILING' ||
        mode == 'E_HAILING' ||
        mode == 'RIDE_HAIL' ||
        mode == 'CAR';
  }

  Future<void> _removeRouteLayerSafely(
  String layerId,
) async {
  try {
    await _mapController?.removeLayer(layerId);
  } catch (error) {
    debugPrint(
      'ℹ️ Could not remove layer $layerId: $error',
    );
  }
}

Future<void> _removeRouteSourceSafely(
  String sourceId,
) async {
  try {
    await _mapController?.removeSource(sourceId);
  } catch (error) {
    debugPrint(
      'ℹ️ Could not remove source $sourceId: $error',
    );
  }
}

/// Decodes an encoded polyline string into a list of [longitude, latitude] coordinates.
  List<List<double>> _decodePolyline(String encoded, {int precision = 5}) {
    final List<List<double>> poly = [];
    int index = 0;
    final int len = encoded.length;
    int lat = 0, lng = 0;
    
    // Use math.pow(10, precision) - make sure you have "import 'dart:math' as math;" at the top of your file
    final double factor = math.pow(10, precision).toDouble(); 

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < len);
      
      final int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      if (index >= len) break;
      
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < len);
      
      final int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      // MapLibre requires [longitude, latitude] format
      poly.add([lng / factor, lat / factor]);
    }
    
    return poly;
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
      _guidanceController.updatePosition(position); // Notify the controller of new coordinates
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
        transitStopsById.isEmpty) {
      _resetStationPresenceTracking();
      return;
    }
    const stationRadiusMeters = 45.0;
    final confirmedStop = _confirmedNearbyStopId == null
        ? null
        : transitStopsById[_confirmedNearbyStopId];
    final closestStop = transitStopsById.values.reduce((closest, candidate) {
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
    unawaited(_apiService.logStationPresence(stop));
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
    if (position == null || transitStopsById.isEmpty) {
      _showMessage('Your location is needed to report an incident.');
      return;
    }

    final stop = transitStopsById.values.reduce((closest, candidate) {
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
        builder: (sheetContext) => BusRouteSelectionSheet(routes: routes),
      );
      if (affectedRoute == null) return;
    }
    if (!mounted) return;

  final report = await showModalBottomSheet<IncidentType>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => IncidentTypeSelectionSheet(
        isBusStop: isBusStop,
        stopName: stop.name,
        distance: distance,
        affectedRoute: affectedRoute,
      ),
    );
    if (report == null) return;

    final reportKey = '${stop.id}:${affectedRoute ?? 'station'}:${report.name}';
    if (_submittedIncidentKeys.contains(reportKey)) {
      _showMessage('You have already reported this incident at this stop.');
      return;
    }
    try {
          await _apiService.submitIncident(
            stopId: stop.id,
            stopName: stop.name,
            stopLat: stop.lat,
            stopLon: stop.lon,
            reportType: report.name,
            isBusStop: isBusStop,
            affectedRoute: affectedRoute,
          );
          _submittedIncidentKeys.add(reportKey);
          _showMessage('Thanks — your anonymous report was submitted.');
        } catch (_) {
          _showMessage('Could not submit the report. Check your connection and try again.');
        }
  }

  Future<void> _askForNearbyStationChoice(Position position) async {
    if (!_stationLocationTrackingEnabled ||
        _isStationChoicePromptOpen ||
        transitStopsById.isEmpty ||
        _selectedTab != 0 ||
        !mounted) {
      return;
    }
    const nearbyDistanceMeters = 60.0;
    const sharedStationDistanceMeters = 20.0;
    final nearbyStops = transitStopsById.values.where((stop) {
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
      final selected = await showModalBottomSheet<TransitStop>(
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
    final stop = transitStopsById[stopId];
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
    TransitStop? stop,
  }) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StationDetailsSheet(
        stopId: stopId,
        stopName: stopName,
        routes: routes,
        transitType: transitType,
        stop: stop,
        onGetDirections: () {
          if (stop == null) return;
          Navigator.of(context).pop();
          _getDirectionsToPlace(stop.asPlaceSearchResult());
        },
        fetchDepartures: () => _apiService.fetchNextDepartures(stopId),
        fetchCongestion: () => stop == null
            ? Future.value(null)
            : _apiService.fetchTrafficCongestion(stopId, stop.lat, stop.lon),
        fetchIncidents: () => _apiService.fetchStopIncidents(stopId),
      ),
    );
  }

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

  Future<void> _loadAndRenderOfflineStops() async {
    try {
      final geoJson =
          await _apiService.fetchStopsGeoJson() ??
          jsonDecode(
            await rootBundle.loadString('assets/transit/stops.geojson'),
          );
      final stopFeatures = (geoJson['features'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .toList();
      final stations = stopFeatures
          .whereType<Map>()
          .map((feature) => TransitStation.fromGeoJson(feature))
          .whereType<TransitStation>()
          .toList();
      final stops = stopFeatures
          .map((feature) => TransitStop.fromGeoJson(feature))
          .whereType<TransitStop>()
          .toList();
      final stopsById = <String, TransitStop>{
        for (final stop in stops) stop.id: stop,
      };
      if (mounted) {
        setState(() {
          _railStations = stations;
          transitStopsById = stopsById;
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

  Future<void> _loadAndRenderStationPerimeters() async {
    final features = await _apiService.fetchStationPerimeters();
      if (features == null || features.isEmpty || _mapController == null) return;
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
    final itineraryIsOpen = _selectedTab == 0 && _currentItinerary != null;
    return PopScope(
      canPop: !itineraryIsOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && itineraryIsOpen) _dismissItinerary();
      },
      child: Scaffold(
        appBar: _selectedTab == 1
            ? AppBar(
                title: const Text('Profile'),
                elevation: 0,
              )
            : null,
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
                        compassEnabled: false,
                      ),
                      Positioned(
                        top: 12,
                        left: 16,
                        right: 16,
                        child: SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Material(
                                    elevation: 4,
                                    borderRadius: BorderRadius.circular(12),
                                    color: Colors.white,
                                    child: PopupMenuButton<String>(
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      tooltip: 'Select region',
                                      initialValue: _currentRegion,
                                      onSelected: (_) {}, // Only Klang Valley is supported
                                      itemBuilder: (context) => [
                                        const PopupMenuItem(
                                          value: _currentRegion,
                                          child: Text(_currentRegion),
                                        ),
                                      ],
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12, vertical: 14),
                                        child: Row(
                                          children: const [
                                            Text(
                                              _currentRegion,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 14,
                                              ),
                                            ),
                                            SizedBox(width: 4),
                                            Icon(Icons.arrow_drop_down, size: 20),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Material(
                                      elevation: 4,
                                      borderRadius: BorderRadius.circular(12),
                                      color: Colors.white,
                                      child: ValueListenableBuilder<TextEditingValue>(
                                        valueListenable: _placeSearchController,
                                        builder: (context, value, child) {
                                          return TextField(
                                            key: const ValueKey('place-search-field'),
                                            controller: _placeSearchController,
                                            focusNode: _placeSearchFocusNode,
                                            textInputAction: TextInputAction.search,
                                            onSubmitted: (_) => _searchPlaces(),
                                            onChanged: _onPlaceSearchChanged,
                                            decoration: InputDecoration(
                                              hintText: 'Search for a location',
                                              border: InputBorder.none,
                                              prefixIcon: const Icon(Icons.search, size: 20),
                                              contentPadding: const EdgeInsets.symmetric(
                                                vertical: 14,
                                              ),
                                              isDense: true,
                                              suffixIcon: value.text.isNotEmpty
                                                  ? IconButton(
                                                      icon: const Icon(Icons.close, size: 20),
                                                      onPressed: () {
                                                        _placeSearchController.clear();
                                                        _onPlaceSearchChanged('');
                                                        _placeSearchFocusNode.unfocus();
                                                      },
                                                    )
                                                  : null,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              if (_placeSearchResults.isNotEmpty || _selectedPlace != null)
                                Material(
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
                                )
                              else if (_currentItinerary == null)
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: _buildNearestStationCard()),
                                    if (_weatherTemperature != null) ...[
                                      const SizedBox(width: 8),
                                      Card(
                                        elevation: 4,
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12)),
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
                            ],
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
                        ItinerarySheet(
                          itinerary: _currentItinerary!,
                          weatherReminder: _weatherItineraryReminder(_currentItinerary!),
                          guidanceCard: _buildJourneyGuidanceCard(),
                          onDismiss: _dismissItinerary,
                          onFindApps: _openEhailingStore,
                          onShowLegIncidents: _showLegIncidents,
                        ),
                    ],
                  ),
            ProfilePage(
              isSupabaseConfigured: _isSupabaseConfigured,
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
                    heroTag: 'reset-compass',
                    backgroundColor: Theme.of(context).colorScheme.surface,
                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                    onPressed: () {
                      _mapController?.animateCamera(CameraUpdate.bearingTo(0.0));
                    },
                    tooltip: 'Reset compass',
                    child: const Icon(Icons.explore_outlined),
                  ),
                  const SizedBox(height: 16),
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