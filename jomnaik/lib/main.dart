import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:math' show Point;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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
import 'models/itinerary.dart';
import 'models/transit.dart';
import 'models/search.dart';
import 'screens/startup_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/unsupported_zone_screen.dart';
import 'widgets/live_guidance_card.dart';
import 'widgets/station_details_sheet.dart';
import 'widgets/itinerary_sheet.dart';
import 'widgets/route_choices_sheet.dart';
import 'widgets/incident_report_sheet.dart';
import 'offline_raptor_router.dart';

const _configuredGtfsBackendBaseUrl = String.fromEnvironment(
  'GTFS_BACKEND_URL',
);
const _deployedBackendBaseUrl = 'https://jomnaik2-production.up.railway.app';
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

enum _StartChoice { currentLocation, search, map }

enum _MapLayerAction { satellite, toggleTheme }

bool get _isSupabaseConfigured =>
    _supabaseUrl.isNotEmpty && _supabasePublishableKey.isNotEmpty;

String get _backendBaseUrl {
  if (_configuredGtfsBackendBaseUrl.isNotEmpty) {
    return _configuredGtfsBackendBaseUrl;
  }
  if (_legacyConfiguredBackendBaseUrl.isNotEmpty) {
    return _legacyConfiguredBackendBaseUrl;
  }

  // Production builds use the deployed API. Local development can override
  // this explicitly with --dart-define=GTFS_BACKEND_URL=http://localhost:8000.
  if (kIsWeb) {
    return _deployedBackendBaseUrl;
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:8000';
  }
  return _deployedBackendBaseUrl;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_isSupabaseConfigured) {
    await Supabase.initialize(
      url: _supabaseUrl,
      publishableKey: _supabasePublishableKey,
    );
  }
  runApp(const JomRideApp());
}

final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier<ThemeMode>(
  ThemeMode.light,
);

class JomRideApp extends StatelessWidget {
  const JomRideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, currentMode, _) {
        return MaterialApp(
          title: 'JomRide',
          themeMode: currentMode,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0D9488),
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: const Color(0xFFF8FAFC),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0D9488),
              brightness: Brightness.dark,
            ),
            scaffoldBackgroundColor: const Color(0xFF0F172A),
          ),
          home: const StartupScreen(
            nextScreen: MapView(),
            storage: _privacyStorage,
          ),
        );
      },
    );
  }
}

class MapView extends StatefulWidget {
  const MapView({super.key});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  static const double _itineraryInitialExtent = 0.40;

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
  int _mapControllerStyleVersion = -1;
  final http.Client _httpClient = http.Client();
  String? _dynamicStyleString;
  Map<String, dynamic>? _cachedRawStyle;
  Map<String, dynamic>? _cachedDarkRawStyle;
  int _mapStyleVersion = 0;
  int _styleRequestGeneration = 0;
  int _initializedMapGeneration = -1;
  bool _isSatelliteMode = false;
  bool _isCardExpanded = false;
  bool _isStationDetailsOpen = false;
  bool _isRouteChoicesOpen = false;
  bool _suppressMapTapFromOverlay = false;
  Timer? _mapTapSuppressionTimer;
  bool _isUsingCurrentLocation = true;
  Itinerary? _currentItinerary;
  Map<String, dynamic>? _currentRawItinerary;
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
  String? _weatherCondition;
  LatLng? _weatherCentre;
  CameraPosition? _lastCameraPosition;
  int _weatherRequestVersion = 0;
  int _itineraryRenderGeneration = 0;
  bool _itineraryUserInteracted = false;
  List<PlaceSearchResult> _placeSearchResults = const [];
  PlaceSearchResult? _selectedPlace;
  bool _isSearchingPlaces = false;
  int _placeSearchRequestId = 0;
  DateTime? _lastLocationWorkAt;
  bool _routeRequestInFlight = false;
  bool _isSearchingRoute = false;
  final Map<String, TimedCache<List<StopDeparture>>> _departureCache = {};
  final Map<String, TimedCache<TrafficCongestion?>> _trafficCache = {};
  final Map<String, TimedCache<Future<StationCrowd>>> _stationCrowdCache = {};
  bool _isSearchOpen = true;
  Completer<PlaceSearchResult?>? _mapStartPicker;
  final Set<String> _submittedIncidentKeys = <String>{};
  Map<String, TransitStop> _transitStopsById = const {};
  TransitStop? _nearestTransitStop;
  int _selectedTab = 0;
  bool _isScrollingCard = false;
  Timer? _scrollCardDebounce;

  void _setScrollingCard(bool isScrolling) {
    _scrollCardDebounce?.cancel();
    if (isScrolling) {
      if (!_isScrollingCard && mounted) {
        setState(() => _isScrollingCard = true);
      }
    } else {
      _scrollCardDebounce = Timer(const Duration(milliseconds: 80), () {
        if (_isScrollingCard && mounted) {
          setState(() => _isScrollingCard = false);
        }
      });
    }
  }

  void _beginOverlayInteraction() {
    _mapTapSuppressionTimer?.cancel();
    _suppressMapTapFromOverlay = true;
  }

  void _endOverlayInteraction() {
    _mapTapSuppressionTimer?.cancel();
    _mapTapSuppressionTimer = Timer(const Duration(milliseconds: 350), () {
      _suppressMapTapFromOverlay = false;
    });
  }

  bool get _canReportIncident => _isSupabaseConfigured;

  String get _walkingPreference {
    if (!_isSupabaseConfigured) return 'standard';
    final preference = Supabase
        .instance
        .client
        .auth
        .currentUser
        ?.userMetadata?['accessibility_mode']
        ?.toString();
    return const {'standard', 'avoid_stairs', 'step_free'}.contains(preference)
        ? preference!
        : 'standard';
  }

  double get _walkingSpeedMetersPerSecond => switch (_walkingPreference) {
    'avoid_stairs' => 1.0,
    'step_free' => 0.8,
    _ => 1.35,
  };

  double _routePreferenceScore(Map<String, dynamic> itinerary) {
    final duration =
        (itinerary['duration'] as num?)?.toDouble() ?? double.infinity;
    if (_walkingPreference == 'standard') return duration;

    final walkingSeconds =
        (itinerary['walkingSeconds'] as num?)?.toDouble() ?? 0;
    final transfers = (itinerary['transferCount'] as num?)?.toDouble() ?? 0;
    final walkingWeight = _walkingPreference == 'step_free' ? 2.0 : 1.5;
    final transferPenalty = _walkingPreference == 'step_free' ? 480 : 240;
    return duration +
        walkingSeconds * (walkingWeight - 1) +
        transfers * transferPenalty;
  }

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
    _scrollCardDebounce?.cancel();
    _mapTapSuppressionTimer?.cancel();
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
      if (index == 0) _isSearchOpen = true;
    });
    if (index == 0 && _lastKnownPosition != null) {
      unawaited(_askForNearbyStationChoice(_lastKnownPosition!));
    }
  }

  void _toggleTheme() {
    final next = themeModeNotifier.value == ThemeMode.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    themeModeNotifier.value = next;
    unawaited(_updateMapStyle());
  }

  void _toggleSatellite() {
    setState(() {
      _isSatelliteMode = !_isSatelliteMode;
    });
    unawaited(_updateMapStyle());
  }

  Future<void> _prepareMapData() async {
    try {
      final styleData = jsonDecode(
        await rootBundle.loadString('assets/style/protomaps_light.json'),
      );
      if (styleData is! Map<String, dynamic>) {
        throw const FormatException('Map style must be a JSON object.');
      }
      _cachedRawStyle = styleData;
      final darkStyleData = jsonDecode(
        await rootBundle.loadString('assets/style/protomaps_dark.json'),
      );
      if (darkStyleData is! Map<String, dynamic>) {
        throw const FormatException('Dark map style must be a JSON object.');
      }
      _cachedDarkRawStyle = darkStyleData;
      await _updateMapStyle();
    } catch (error) {
      debugPrint('Could not prepare offline map style: $error');
      if (mounted) {
        // Keep the map surface usable if a style edit or asset is malformed.
        // The minimal style still exposes the same local PMTiles source.
        try {
          final fallback = jsonDecode(
            await rootBundle.loadString('assets/style/minimal_style.json'),
          );
          if (fallback is Map<String, dynamic> &&
              fallback['sources'] is Map<String, dynamic> &&
              (fallback['sources'] as Map<String, dynamic>)['protomaps_offline']
                  is Map<String, dynamic>) {
            final sources = fallback['sources'] as Map<String, dynamic>;
            final source = sources['protomaps_offline'] as Map<String, dynamic>;
            source['url'] = await mapTilesSourceUrl();
            setState(() => _dynamicStyleString = jsonEncode(fallback));
          }
        } catch (fallbackError) {
          debugPrint('Could not prepare fallback map style: $fallbackError');
        }
        _showMessage('The offline map could not be loaded.');
      }
    }
  }

  Future<void> _updateMapStyle() async {
    final requestGeneration = ++_styleRequestGeneration;
    final isDark = themeModeNotifier.value == ThemeMode.dark;
    final base = isDark
        ? (_cachedDarkRawStyle ?? _cachedRawStyle)
        : _cachedRawStyle;
    if (base == null) return;
    try {
      final styleData = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
      final sources = styleData['sources'] as Map<String, dynamic>;
      final tileUrl = await mapTilesSourceUrl();
      for (final source in sources.values) {
        if (source is Map<String, dynamic> && source['type'] == 'vector') {
          source['url'] = tileUrl;
        }
      }
      if (!mounted || requestGeneration != _styleRequestGeneration) return;

      final layers = (styleData['layers'] as List).cast<Map<String, dynamic>>();

      if (_isSatelliteMode) {
        sources['satellite'] = {
          'type': 'raster',
          'tiles': [
            'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
          ],
          'tileSize': 256,
        };
        final satLayer = <String, dynamic>{
          'id': 'satellite_imagery_layer',
          'type': 'raster',
          'source': 'satellite',
          'minzoom': 0,
          'maxzoom': 19,
        };
        // Keep the imagery above every land, water, land-use, and building
        // fill. Inserting at index 1 leaves those opaque fills above the
        // imagery in the light style. Place it before roads and labels so
        // those remain legible over the satellite tiles in both themes.
        final lastFillIndex = layers.lastIndexWhere(
          (layer) => layer['type'] == 'fill',
        );
        layers.insert(lastFillIndex + 1, satLayer);

        for (final layer in layers) {
          final type = layer['type']?.toString() ?? '';
          final sourceLayer = layer['source-layer']?.toString() ?? '';
          final paint =
              (layer['paint'] as Map<String, dynamic>?) ?? <String, dynamic>{};
          layer['paint'] = paint;

          if (type == 'background') {
            paint['background-color'] = '#000000';
          } else if (type == 'fill') {
            // The light and dark styles use different source IDs and include
            // slightly different fill layers. Hide every base fill so none
            // can cover the satellite raster in either theme.
            paint['fill-opacity'] = 0.0;
          } else if (sourceLayer == 'roads' && type == 'line') {
            // In satellite view, make road lines transparent or sufficiently subtle
            // so imagery remains visible.
            paint['line-opacity'] = 0.25;
            paint['line-color'] = '#ffffff';
          } else if (type == 'symbol') {
            // Retain road names and all other labels with strong contrast
            paint['text-color'] = '#ffffff';
            paint['text-halo-color'] = '#000000';
            paint['text-halo-width'] = 2.0;
            paint['icon-opacity'] = 1.0;
          }
        }
      }
      // Light and dark modes use their own bundled Protomaps themes. Both
      // point at the same local PMTiles source so the map remains offline.

      if (!mounted || requestGeneration != _styleRequestGeneration) return;
      setState(() {
        _mapStyleVersion++;
        _dynamicStyleString = jsonEncode(styleData);
      });
      print(
        '[JomRide][map] Protomaps PMTiles style assigned (dark=$isDark, sat=$_isSatelliteMode)',
      );
    } catch (error) {
      debugPrint('Failed to construct dynamic map style: $error');
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
      try {
        print(
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
          print('Weather API error (${response.statusCode}): ${response.body}');
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

  Future<void> _clearSelectedPlaceMarker() async {
    final marker = _selectedPlaceMarker;
    final controller = _mapController;
    _selectedPlaceMarker = null;
    if (marker != null && controller != null) {
      await controller.removeCircle(marker);
    }
  }

  Future<List<PlaceSearchResult>> _findPlaces(
    String query, {
    bool allowTransitFallback = true,
  }) async {
    var placeServiceResponded = false;
    for (final baseUrl in _placeSearchBaseUrls()) {
      try {
        final response = await _httpClient
            .get(
              Uri.parse(
                '$baseUrl/api/places/search',
              ).replace(queryParameters: {'q': query}),
              headers: await backendHeaders(),
            )
            .timeout(const Duration(seconds: 8));
        if (response.statusCode == 200) {
          placeServiceResponded = true;
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
        debugPrint('Place search unavailable at $baseUrl: $error');
      }
    }

    // The backend is a proxy for Nominatim, but keep the web search usable
    // when that proxy is unavailable. Do not use transit fallback after a
    // successful Nominatim response, even when it contains no matches.
    if (!placeServiceResponded) {
      try {
        final response = await _httpClient
            .get(
              Uri.https('nominatim.openstreetmap.org', '/search', {
                'q': query,
                'format': 'jsonv2',
                'addressdetails': '1',
                'limit': '12',
                'countrycodes': 'my',
                'viewbox': '101.2,3.45,101.95,2.7',
                'bounded': '1',
              }),
            )
            .timeout(const Duration(seconds: 8));
        if (response.statusCode == 200) {
          final payload = jsonDecode(response.body);
          if (payload is List) {
            return payload
                .whereType<Map>()
                .map((place) {
                  final displayName =
                      place['display_name']?.toString() ?? query;
                  return PlaceSearchResult(
                    name:
                        place['name']?.toString() ??
                        displayName.split(',').first,
                    address: displayName,
                    lat: double.tryParse(place['lat']?.toString() ?? '') ?? 0,
                    lon: double.tryParse(place['lon']?.toString() ?? '') ?? 0,
                  );
                })
                .where((place) => place.lat != 0 || place.lon != 0)
                .toList();
          }
        }
      } catch (error) {
        debugPrint('Direct Nominatim search unavailable: $error');
      }
    }

    if (!allowTransitFallback) return const [];

    // Keep the map's transit-stop search functional only when every
    // place-search endpoint is unavailable.
    final normalizedQuery = query.toLowerCase();
    return _transitStopsById.values
        .where((stop) => stop.name.toLowerCase().contains(normalizedQuery))
        .take(12)
        .map((stop) => stop.asPlaceSearchResult())
        .toList();
  }

  List<String> _placeSearchBaseUrls() {
    return <String>[_backendBaseUrl];
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

  Future<void> _showLongPressedLocation(
    dynamic point,
    LatLng coordinate,
  ) async {
    if (_currentItinerary != null ||
        _isCardExpanded ||
        _isStationDetailsOpen ||
        _isRouteChoicesOpen ||
        _suppressMapTapFromOverlay) {
      return;
    }
    if (!_isSupportedCoordinate(coordinate.latitude, coordinate.longitude)) {
      _showUnsupportedZone();
      return;
    }
    try {
      var stop = await _transitStopAtMapPoint(point);
      stop ??= _nearestTransitStopWithin(
        coordinate.latitude,
        coordinate.longitude,
        120.0,
      );
      final place = stop == null
          ? await _reverseGeocodePlace(coordinate)
          : PlaceSearchResult(
              name: stop.name,
              address:
                  'Coordinates: ${stop.lat.toStringAsFixed(6)}, ${stop.lon.toStringAsFixed(6)}',
              lat: stop.lat,
              lon: stop.lon,
              stopId: stop.id,
            );
      if (!mounted) return;
      FocusScope.of(context).unfocus();
      setState(() {
        _selectedPlace = place;
        _placeSearchResults = const [];
        _isSearchOpen = true;
      });
    } catch (_) {
      if (mounted) _showMessage('Could not look up that map location.');
    }
  }

  Future<TransitStop?> _transitStopAtMapPoint(dynamic point) async {
    final features = await _mapController?.queryRenderedFeatures(point, [
      'rail_stop_hit_targets_layer',
      'bus_stop_hit_targets_layer',
      'rail_stops_layer',
      'transit_stops_layer',
    ], null);
    if (features == null) return null;

    for (final feature in features) {
      if (feature is! Map || feature['properties'] is! Map) continue;
      final properties = feature['properties'] as Map;
      final id = properties['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final knownStop = _transitStopsById[id];
      if (knownStop != null) return knownStop;
      final parsedStop = TransitStop.fromGeoJson(feature);
      if (parsedStop != null) return parsedStop;
    }
    return null;
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
    final startChoice = await _chooseCurrentOrManualStart();
    if (startChoice == null) return;
    _isUsingCurrentLocation = (startChoice == _StartChoice.currentLocation);
    Position? origin;
    PlaceSearchResult? selectedStart;
    if (startChoice == _StartChoice.currentLocation) {
      await _startLocationTracking();
      origin = _lastKnownPosition;
      if (origin == null) {
        _showMessage('Could not get your current location.');
        return;
      }
    } else if (startChoice == _StartChoice.search) {
      selectedStart = await _askForStartLocation();
    } else {
      selectedStart = await _pickStartFromMap();
    }
    if (origin == null && selectedStart == null) return;
    final originLat = origin?.latitude ?? selectedStart!.lat;
    final originLon = origin?.longitude ?? selectedStart!.lon;
    if (!_isSupportedCoordinate(originLat, originLon)) {
      _showUnsupportedZone();
      return;
    }
    final candidateFromStopId = origin == null ? selectedStart!.stopId : null;
    final effectiveFromStopId = candidateFromStopId ??
        _nearestTransitStopWithin(originLat, originLon, 200.0)?.id;
    final effectiveToStopId = destination.stopId ??
        _nearestTransitStopWithin(destination.lat, destination.lon, 200.0)?.id;

    final routeData = await _requestRoute(
      fromLat: originLat,
      fromLon: originLon,
      toLat: destination.lat,
      toLon: destination.lon,
      fromStopId: effectiveFromStopId,
      toStopId: effectiveToStopId,
    );
    await _showRouteChoices(routeData);
  }

  Future<_StartChoice?> _chooseCurrentOrManualStart() {
    return showModalBottomSheet<_StartChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Choose your starting point',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () =>
                    Navigator.of(context).pop(_StartChoice.currentLocation),
                icon: const Icon(Icons.my_location),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                ),
                label: const Text(
                  'Use current location',
                  style: TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(_StartChoice.search),
                icon: const Icon(Icons.search),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                ),
                label: const Text(
                  'Enter a location',
                  style: TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(_StartChoice.map),
                icon: const Icon(Icons.map_outlined),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                ),
                label: const Text(
                  'Select from map',
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<PlaceSearchResult?> _pickStartFromMap() async {
    final picker = Completer<PlaceSearchResult?>();
    _mapStartPicker = picker;
    if (mounted) {
      _showMessage('Tap the map to select your starting point.');
    }
    final result = await picker.future;
    if (identical(_mapStartPicker, picker)) _mapStartPicker = null;
    return result;
  }

  Future<void> _handleMapStartPick(dynamic point, LatLng coordinate) async {
    if (_currentItinerary != null ||
        _isCardExpanded ||
        _isStationDetailsOpen ||
        _isRouteChoicesOpen ||
        _suppressMapTapFromOverlay) {
      return;
    }
    final picker = _mapStartPicker;
    if (picker == null || picker.isCompleted) return;
    if (!_isSupportedCoordinate(coordinate.latitude, coordinate.longitude)) {
      _showUnsupportedZone();
      return;
    }
    final features = await _mapController?.queryRenderedFeatures(point, [
      'rail_stop_hit_targets_layer',
      'bus_stop_hit_targets_layer',
      'rail_stops_layer',
      'transit_stops_layer',
    ], null);
    if (!mounted) return;
    TransitStop? stop;
    if (features != null && features.isNotEmpty) {
      final feature = features.first;
      final properties = feature is Map && feature['properties'] is Map
          ? feature['properties'] as Map
          : null;
      final stopId = properties?['id']?.toString();
      stop = stopId == null ? null : _transitStopsById[stopId];
    }
    stop ??= _nearestTransitStopWithin(
      coordinate.latitude,
      coordinate.longitude,
      120.0,
    );
    if (stop != null) {
      final shouldUseStop = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Use this station or stop?'),
          content: Text(stop!.name),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Set as start'),
            ),
          ],
        ),
      );
      if (shouldUseStop == true && !picker.isCompleted) {
        picker.complete(stop.asPlaceSearchResult());
      }
      return;
    }
    final place = await _reverseGeocodePlace(coordinate);
    if (!picker.isCompleted) picker.complete(place);
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
                      hintText: 'Search an address, landmark, or station',
                      prefixIcon: const Icon(Icons.search),
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
                  if (!isSearching &&
                      controller.text.trim().length >= 2 &&
                      results.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'No mapped locations found. Try a nearby address or landmark.',
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

  int _durationFromLegs(List<Map<String, dynamic>> legs, int fallback) {
    if (legs.isEmpty) return fallback;
    final start = DateTime.tryParse(legs.first['startTime']?.toString() ?? '');
    final end = DateTime.tryParse(legs.last['endTime']?.toString() ?? '');
    if (start == null || end == null || !end.isAfter(start)) return fallback;
    return end.difference(start).inSeconds;
  }

  Future<void> _showRouteChoices(Map<String, dynamic>? routeData) async {
    if (routeData == null || routeData['itineraries'] is! List) return;
    final itineraries = (routeData['itineraries'] as List<dynamic>)
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    String routeSignature(Map<String, dynamic> itinerary) {
      final legs = _itineraryLegs(itinerary);
      final transit = legs.where(
        (leg) => !_isStreetLegMode(leg['mode']?.toString() ?? ''),
      );
      return transit
          .map(
            (leg) => [
              leg['mode']?.toString() ?? '',
              leg['routeShortName']?.toString() ?? '',
              leg['headsign']?.toString() ?? '',
            ].join(':'),
          )
          .join('|');
    }

    // Duration can exclude waiting time in a timetable view. Prefer the
    // earliest usable public-transport departure rather than a journey that
    // starts later, while keeping short walking and direct e-hailing options
    // ahead of a timetable that departs much later.
    itineraries.sort((left, right) {
      if (_walkingPreference != 'standard') {
        final preferenceComparison = _routePreferenceScore(
          left,
        ).compareTo(_routePreferenceScore(right));
        if (preferenceComparison != 0) return preferenceComparison;
      }
      final walkingComparison =
          ((left['walkingSeconds'] as num?)?.toInt() ?? 1 << 30).compareTo(
            (right['walkingSeconds'] as num?)?.toInt() ?? 1 << 30,
          );
      if (walkingComparison != 0) return walkingComparison;
      int priority(Map<String, dynamic> itinerary) {
        if (itinerary['routeCategory']?.toString() == 'ehailing') return 2;
        if (itinerary['routeCategory']?.toString() == 'walking') return 0;
        final transfers = (itinerary['transferCount'] as num?)?.toInt() ?? 0;
        if (transfers <= 1) return 0;
        return 1;
      }

      final priorityComparison = priority(left).compareTo(priority(right));
      if (priorityComparison != 0) return priorityComparison;
      final leftIsFullHail = left['routeCategory']?.toString() == 'ehailing';
      final rightIsFullHail = right['routeCategory']?.toString() == 'ehailing';
      if (leftIsFullHail != rightIsFullHail) return leftIsFullHail ? -1 : 1;
      final leftDuration =
          (left['duration'] as num?)?.toDouble() ?? double.infinity;
      final rightDuration =
          (right['duration'] as num?)?.toDouble() ?? double.infinity;
      return leftDuration.compareTo(rightDuration);
    });

    DateTime departure(Map<String, dynamic> itinerary) {
      final legs = _itineraryLegs(itinerary);
      final value = legs.isEmpty ? null : legs.first['startTime'];
      return value is String
          ? DateTime.tryParse(value)?.toLocal() ?? DateTime(9999)
          : DateTime(9999);
    }

    // Keep only the earliest departure for each actual transit pattern. This
    // removes timetable variants that produce the same route card.
    final unique = <String, Map<String, dynamic>>{};
    for (final itinerary in itineraries) {
      final signature = routeSignature(itinerary);
      final category = itinerary['routeCategory']?.toString() ?? 'unknown';
      // Keep different access strategies for the same transit pattern:
      // walking-to-transit and e-hailing-to-transit are distinct user choices.
      final key = signature.isEmpty
          ? category
          : category == 'hybrid'
          ? 'hybrid|${itinerary['hybridFirstMile'] == true}|${itinerary['hybridLastMile'] == true}|$signature'
          : signature;
      final existing = unique[key];
      if (existing == null ||
          departure(itinerary).isBefore(departure(existing))) {
        unique[key] = itinerary;
      }
    }
    final deduplicated = unique.values.toList();

    // Accessibility preferences apply a walking and transfer cost before
    // incident risk and the usual duration tie-breakers.
    deduplicated.sort((left, right) {
      final preferenceComparison = _routePreferenceScore(
        left,
      ).compareTo(_routePreferenceScore(right));
      if (preferenceComparison != 0) return preferenceComparison;
      final riskComparison =
          ((left['incidentRiskScore'] as num?)?.toDouble() ?? 0).compareTo(
            (right['incidentRiskScore'] as num?)?.toDouble() ?? 0,
          );
      if (riskComparison != 0) return riskComparison;
      final leftTransfers = (left['transferCount'] as num?)?.toInt() ?? 0;
      final rightTransfers = (right['transferCount'] as num?)?.toInt() ?? 0;
      final transferComparison = leftTransfers.compareTo(rightTransfers);
      if (transferComparison != 0) return transferComparison;
      final distanceComparison =
          ((left['distanceMeters'] as num?)?.toDouble() ?? double.infinity)
              .compareTo(
                (right['distanceMeters'] as num?)?.toDouble() ??
                    double.infinity,
              );
      if (distanceComparison != 0) return distanceComparison;
      return departure(left).compareTo(departure(right));
    });
    itineraries
      ..clear()
      ..addAll(deduplicated);
    if (itineraries.isEmpty || !mounted) {
      _showMessage('No routes found for this location.');
      return;
    }

    if (_isRouteChoicesOpen || !mounted) return;
    setState(() => _isRouteChoicesOpen = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => RouteChoicesSheet(
          itineraries: itineraries,
          onSelectItinerary: _applyItinerary,
        ),
      );
    } finally {
      if (mounted) setState(() => _isRouteChoicesOpen = false);
    }
  }

  Future<void> _applyItinerary(Map<String, dynamic> itinerary) async {
    FocusScope.of(context).unfocus();
    _placeSearchDebounce?.cancel();
    if (mounted) {
      setState(() {
        _isSearchOpen = true;
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
      _currentRawItinerary = itinerary;
      _itineraryUserInteracted = false;
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
    if (!_isUsingCurrentLocation) {
      _showMessage(
        'Live guidance is only available when starting from your current location.',
      );
      return;
    }
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
  /// JomRide's guidance for its transit portion.
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
              'At ${target.name}. Board ${leg.routeShortName ?? 'the service'} toward ${leg.terminus ?? leg.headsign ?? leg.toPlace?.name ?? 'your destination'}.';
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
      return 'This journey includes '
          '$openWalks open walking ${openWalks == 1 ? 'section' : 'sections'}; '
          'use covered paths where available.';
    }
    if (coveredWalks > 0) {
      return 'This journey includes the covered '
          '${coveredWalks == 1 ? 'walkway' : 'walkways'} in this itinerary.';
    }
    return 'Bring an umbrella for station access and transfers if it is raining.';
  }

  Widget _buildJourneyGuidanceCard() {
    final itinerary = _currentItinerary;
    if (itinerary == null ||
        itinerary.legs.isEmpty ||
        _isDirectEhailingItinerary(itinerary)) {
      return const SizedBox.shrink();
    }
    if (!_isUsingCurrentLocation) {
      final colorScheme = Theme.of(context).colorScheme;
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(Icons.location_disabled, size: 20, color: colorScheme.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Live guidance is disabled because the journey starts from a custom location.',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
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

  void _markItineraryUserInteracted() {
    if (_itineraryUserInteracted) return;
    _itineraryUserInteracted = true;

    // Route geometry is rendered asynchronously and its final step fits the
    // route into the map. If that animation has already started when the user
    // begins scrolling the sheet, freeze the current camera immediately.
    final controller = _mapController;
    final camera = _lastCameraPosition;
    if (controller == null || camera == null) return;
    unawaited(() async {
      try {
        await controller.moveCamera(CameraUpdate.newCameraPosition(camera));
      } catch (error) {
        debugPrint(
          '[JomRide][map] Could not stop route camera animation: $error',
        );
      }
    }());
  }

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
    _scrollCardDebounce?.cancel();
    setState(() {
      _currentItinerary = null;
      _currentRawItinerary = null;
      _isCardExpanded = false;
      _isScrollingCard = false;
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
    for (final layerId in [
      'route_ehailing_layer',
      'route_ehailing',
      'ehailing_layer',
      'hail_layer',
    ]) {
      try {
        await _mapController?.removeLayer(layerId);
      } catch (_) {}
    }
    try {
      await _mapController?.removeSource('route_transit_source');
    } catch (_) {}
    try {
      await _mapController?.removeSource('route_walk_source');
    } catch (_) {}
    for (final sourceId in [
      'route_ehailing_source',
      'route_ehailing',
      'ehailing_source',
      'hail_source',
    ]) {
      try {
        await _mapController?.removeSource(sourceId);
      } catch (_) {}
    }
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
    DateTime? departure,
  }) async {
    if (_routeRequestInFlight) return null;
    _routeRequestInFlight = true;
    if (mounted) setState(() => _isSearchingRoute = true);
    try {
      final when = departure ?? DateTime.now();
      final requestBody = <String, dynamic>{
        'from_lat': fromLat,
        'from_lon': fromLon,
        'to_lat': toLat,
        'to_lon': toLon,
        'prefer_brt': preferBrt,
        'walking_preference': _walkingPreference,
        'departure_date':
            '${when.year.toString().padLeft(4, '0')}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')}',
        'departure_time':
            '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}:${when.second.toString().padLeft(2, '0')}',
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
          departure: when,
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

      bool hasTransitItinerary(Iterable<dynamic> candidates) =>
          candidates.any((itinerary) {
            if (itinerary is! Map || itinerary['legs'] is! List) return false;
            return (itinerary['legs'] as List).any((leg) {
              if (leg is! Map) return false;
              final mode = leg['mode']?.toString().toUpperCase();
              return mode != null && mode != 'WALK' && mode != 'HAIL';
            });
          });

      // Filter itineraries to only keep journeys available at the requested departure time
      final validItineraries = itineraries.where((it) {
        if (it is! Map<String, dynamic>) return false;
        return isItineraryMapAvailableAtDeparture(it, when);
      }).toList();

      // If backend had no available transit at the departure time, check offline RAPTOR
      if (!hasTransitItinerary(validItineraries)) {
        try {
          final offlineTransit = await _offlineRaptorRouter.plan(
            fromLat: fromLat,
            fromLon: fromLon,
            toLat: toLat,
            toLon: toLon,
            fromStopId: fromStopId,
            toStopId: toStopId,
            departure: when,
            walkingPreference: _walkingPreference,
          );
          final offlineItineraries = offlineTransit?['itineraries'];
          if (offlineItineraries is List) {
            final validOffline = offlineItineraries.where((it) {
              if (it is! Map<String, dynamic>) return false;
              return isItineraryMapAvailableAtDeparture(it, when);
            }).toList();
            if (hasTransitItinerary(validOffline)) {
              final combined = {
                ...responseData,
                'itineraries': [...validOffline, ...validItineraries],
                'offlineRouting': true,
              };
              return _applyIncidentRisk(
                _addDirectModeAlternatives(
                  combined,
                  fromLat: fromLat,
                  fromLon: fromLon,
                  toLat: toLat,
                  toLon: toLon,
                  departure: when,
                ),
              );
            }
          }
        } catch (error) {
          debugPrint('Offline transit supplement failed: $error');
        }
      }

      final alternatives = _addDirectModeAlternatives(
        {...responseData, 'itineraries': validItineraries},
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        departure: when,
      );

      final combinedList = alternatives['itineraries'] as List<dynamic>? ?? [];
      final hasAnyTransit = hasTransitItinerary(combinedList);
      if (!hasAnyTransit) {
        _showMessage(
          'Public transit is not operating at the requested departure time. Showing available alternatives like e-hailing and walking.',
        );
      }
      return _applyIncidentRisk(alternatives);
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
        departure: departure,
      );
    } on TimeoutException {
      return _offlineRoute(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        fromStopId: fromStopId,
        toStopId: toStopId,
        departure: departure,
      );
    } catch (error) {
      _showMessage('Could not calculate the route.');
      debugPrint('Route error: $error');
      return null;
    } finally {
      _routeRequestInFlight = false;
      if (mounted) setState(() => _isSearchingRoute = false);
    }
  }

  Future<Map<String, dynamic>?> _offlineRoute({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    String? fromStopId,
    String? toStopId,
    DateTime? departure,
  }) async {
    final when = departure ?? DateTime.now();
    final directEhailing = _offlineEhailingItinerary(
      fromLat: fromLat,
      fromLon: fromLon,
      toLat: toLat,
      toLon: toLon,
      departure: when,
    );
    final directWalking = _offlineWalkingItinerary(
      fromLat: fromLat,
      fromLon: fromLon,
      toLat: toLat,
      toLon: toLon,
      departure: when,
    );
    try {
      final result = await _offlineRaptorRouter.plan(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        fromStopId: fromStopId,
        toStopId: toStopId,
        departure: when,
        walkingPreference: _walkingPreference,
      );
      if (result != null) {
        final rawItineraries = result['itineraries'] as List? ?? [];
        final validItineraries = rawItineraries.where((it) {
          if (it is! Map<String, dynamic>) return false;
          return isItineraryMapAvailableAtDeparture(it, when);
        }).toList();

        if (validItineraries.isNotEmpty) {
          final alternatives = _addDirectModeAlternatives(
            {...result, 'itineraries': validItineraries},
            fromLat: fromLat,
            fromLon: fromLon,
            toLat: toLat,
            toLon: toLon,
            departure: when,
          );
          return _applyIncidentRisk(alternatives);
        }
      }
    } catch (error) {
      debugPrint('Offline RAPTOR route error: $error');
    }
    _showMessage(
      'Public transit is not operating at the requested departure time. Showing available alternatives like e-hailing and walking.',
    );
    return _applyIncidentRisk({
      'itineraries': [
        directWalking,
        if (Geolocator.distanceBetween(fromLat, fromLon, toLat, toLon) > 1000)
          directEhailing,
      ],
      'offlineRouting': true,
    });
  }

  Future<Map<String, dynamic>> _applyIncidentRisk(
    Map<String, dynamic> routeData,
  ) async {
    routeData = await _applyTomTomTrafficEstimates(routeData);
    // For bus routes, journey times are calculated based on only scheduled
    // timetable times once the user reaches the bus stop. Live bus estimates
    // are not applied to route planning.
    try {
      final response = await _httpClient
          .get(
            Uri.parse('$_backendBaseUrl/api/incidents/recent'),
            headers: await backendHeaders(),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return routeData;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['incidents'] is! List) return routeData;
      final now = DateTime.now().toUtc();
      final incidents = (decoded['incidents'] as List).whereType<Map>().where((
        incident,
      ) {
        final reportedAt = DateTime.tryParse(
          incident['reported_at']?.toString() ?? '',
        );
        if (reportedAt == null) return false;
        return now.difference(reportedAt.toUtc()) <=
            const Duration(minutes: 15);
      }).toList();
      final itineraries = routeData['itineraries'];
      if (itineraries is! List) return routeData;
      return {
        ...routeData,
        'itineraries': itineraries.map((raw) {
          if (raw is! Map) return raw;
          final itinerary = Map<String, dynamic>.from(raw);
          final risk = _incidentRiskForItinerary(itinerary, incidents);
          final incidentDelaySeconds = _incidentDelaySeconds(
            itinerary,
            incidents,
          );
          final legs = itinerary['legs'];
          if (legs is List) {
            itinerary['legs'] = legs.map((rawLeg) {
              if (rawLeg is! Map) return rawLeg;
              final leg = Map<String, dynamic>.from(rawLeg);
              final matches = _incidentsForLeg(leg, incidents);
              if (matches.isNotEmpty) leg['incidentReports'] = matches;
              return leg;
            }).toList();
          }
          return {
            ...itinerary,
            if (incidentDelaySeconds > 0) ...{
              'baseDuration': itinerary['duration'],
              'incidentDelaySeconds': incidentDelaySeconds,
              'duration':
                  (itinerary['duration'] as num? ?? 0).toInt() +
                  incidentDelaySeconds,
            },
            'incidentRiskScore': risk.score,
            if (risk.count > 0)
              'incidentRiskLabel':
                  'Reported incidents: ${risk.reports.join('; ')}',
            if (risk.count == 0)
              'incidentRiskLabel': 'No recent reported incidents',
          };
        }).toList(),
      };
    } catch (_) {
      return routeData;
    }
  }

  Future<Map<String, dynamic>> _applyTomTomTrafficEstimates(
    Map<String, dynamic> routeData,
  ) async {
    final itineraries = routeData['itineraries'];
    if (itineraries is! List) return routeData;

    String routeKey(
      double fromLat,
      double fromLon,
      double toLat,
      double toLon,
    ) =>
        '${fromLat.toStringAsFixed(5)},${fromLon.toStringAsFixed(5)}:'
        '${toLat.toStringAsFixed(5)},${toLon.toStringAsFixed(5)}';

    final requests = <String, Future<Map<String, dynamic>?>>{};
    for (final rawItinerary in itineraries) {
      if (rawItinerary is! Map || rawItinerary['legs'] is! List) continue;
      for (final rawLeg in rawItinerary['legs'] as List) {
        if (rawLeg is! Map ||
            rawLeg['mode']?.toString().toUpperCase() != 'HAIL') {
          continue;
        }
        final from = rawLeg['from'];
        final to = rawLeg['to'];
        if (from is! Map ||
            to is! Map ||
            from['lat'] is! num ||
            from['lon'] is! num ||
            to['lat'] is! num ||
            to['lon'] is! num) {
          continue;
        }
        final fromLat = (from['lat'] as num).toDouble();
        final fromLon = (from['lon'] as num).toDouble();
        final toLat = (to['lat'] as num).toDouble();
        final toLon = (to['lon'] as num).toDouble();
        final key = routeKey(fromLat, fromLon, toLat, toLon);
        requests.putIfAbsent(
          key,
          () => _fetchTomTomTrafficEstimate(
            fromLat: fromLat,
            fromLon: fromLon,
            toLat: toLat,
            toLon: toLon,
            departAt: DateTime.tryParse(rawLeg['startTime']?.toString() ?? '')
                ?.add(
                  Duration(
                    seconds: (rawLeg['pickupDuration'] as num?)?.toInt() ?? 0,
                  ),
                ),
          ),
        );
      }
    }
    if (requests.isEmpty) return routeData;

    final entries = await Future.wait(
      requests.entries.map(
        (entry) async => MapEntry(entry.key, await entry.value),
      ),
    );
    final estimates = Map<String, Map<String, dynamic>?>.fromEntries(entries);

    return {
      ...routeData,
      'itineraries': itineraries.map((rawItinerary) {
        if (rawItinerary is! Map || rawItinerary['legs'] is! List) {
          return rawItinerary;
        }
        final itinerary = Map<String, dynamic>.from(rawItinerary);
        var durationDelta = 0;
        itinerary['legs'] = (rawItinerary['legs'] as List).map((rawLeg) {
          if (rawLeg is! Map ||
              rawLeg['mode']?.toString().toUpperCase() != 'HAIL') {
            return rawLeg;
          }
          final from = rawLeg['from'];
          final to = rawLeg['to'];
          if (from is! Map ||
              to is! Map ||
              from['lat'] is! num ||
              from['lon'] is! num ||
              to['lat'] is! num ||
              to['lon'] is! num) {
            return rawLeg;
          }
          final key = routeKey(
            (from['lat'] as num).toDouble(),
            (from['lon'] as num).toDouble(),
            (to['lat'] as num).toDouble(),
            (to['lon'] as num).toDouble(),
          );
          final estimate = estimates[key];
          if (estimate == null) return rawLeg;

          final oldStart = DateTime.tryParse(
            rawLeg['startTime']?.toString() ?? '',
          );
          final start = oldStart ?? DateTime.now();
          final pickupSeconds =
              (rawLeg['pickupDuration'] as num?)?.toInt() ?? 0;
          final drivingSeconds = (estimate['travelTimeSeconds'] as num).toInt();
          final totalSeconds = math.max(300, pickupSeconds + drivingSeconds);
          final end = start.add(Duration(seconds: totalSeconds));
          final oldDuration =
              (rawLeg['duration'] as num?)?.toInt() ??
              (() {
                final oldEnd = DateTime.tryParse(
                  rawLeg['endTime']?.toString() ?? '',
                );
                return oldEnd == null ? 0 : oldEnd.difference(start).inSeconds;
              })();
          durationDelta += totalSeconds - oldDuration;
          return {
            ...Map<String, dynamic>.from(rawLeg),
            'startTime': start.toIso8601String(),
            'endTime': end.toIso8601String(),
            'duration': totalSeconds,
            'drivingDuration': drivingSeconds,
            'trafficDelaySeconds': estimate['trafficDelaySeconds'],
            'trafficLevel': estimate['trafficLevel'],
            'distanceMeters': estimate['distanceMeters'],
            'routingSource': 'tomtom',
          };
        }).toList();
        if (durationDelta != 0) {
          itinerary['duration'] =
              ((rawItinerary['duration'] as num?)?.toInt() ?? 0) +
              durationDelta;
        }
        return itinerary;
      }).toList(),
    };
  }

  Future<Map<String, dynamic>> _applyLiveBusEstimates(
    Map<String, dynamic> routeData,
  ) async {
    final itineraries = routeData['itineraries'];
    if (itineraries is! List) return routeData;

    final departureRequests = <String, Future<List<StopDeparture>>>{};

    for (final rawItinerary in itineraries) {
      if (rawItinerary is! Map || rawItinerary['legs'] is! List) continue;
      for (final rawLeg in rawItinerary['legs'] as List) {
        if (rawLeg is! Map) continue;
        final mode = rawLeg['mode']?.toString().toUpperCase();
        if (mode != 'BUS') continue;

        final from = rawLeg['from'];
        final stopId = from is Map
            ? (from['stopId']?.toString() ?? from['id']?.toString())
            : null;
        if (stopId != null && stopId.isNotEmpty) {
          departureRequests.putIfAbsent(
            stopId,
            () => _fetchNextDepartures(stopId).catchError(
              (_) => const <StopDeparture>[],
            ),
          );
        }
      }
    }

    if (departureRequests.isEmpty) return routeData;

    final departuresByStop = <String, List<StopDeparture>>{};
    for (final entry in departureRequests.entries) {
      try {
        departuresByStop[entry.key] = await entry.value;
      } catch (_) {
        departuresByStop[entry.key] = const <StopDeparture>[];
      }
    }

    final updatedItineraries = <Map<String, dynamic>>[];
    for (final rawItinerary in itineraries) {
      if (rawItinerary is! Map || rawItinerary['legs'] is! List) {
        if (rawItinerary is Map) {
          updatedItineraries.add(Map<String, dynamic>.from(rawItinerary));
        }
        continue;
      }

      final legs = (rawItinerary['legs'] as List).map((l) {
        if (l is! Map) return l;
        final legMap = Map<String, dynamic>.from(l);
        final mode = legMap['mode']?.toString().toUpperCase();
        if (mode == 'BUS') {
          final from = legMap['from'];
          final stopId = from is Map
              ? (from['stopId']?.toString() ?? from['id']?.toString())
              : null;
          final routeName = legMap['routeShortName']?.toString().trim() ?? '';
          if (stopId != null && departuresByStop.containsKey(stopId)) {
            final deps = departuresByStop[stopId]!;
            final estimatedDep = deps.firstWhere(
              (d) =>
                  d.isEstimated &&
                  routeName.isNotEmpty &&
                  (d.route.toLowerCase() == routeName.toLowerCase() ||
                      routeName.toLowerCase().contains(d.route.toLowerCase()) ||
                      d.route.toLowerCase().contains(routeName.toLowerCase())),
              orElse: () => const StopDeparture(
                route: '',
                time: '',
                timestamp: 0,
                isEstimated: false,
                direction: '',
              ),
            );
            if (estimatedDep.isEstimated && estimatedDep.timestamp > 0) {
              legMap['liveBusEstimate'] = {
                'timestamp': estimatedDep.timestamp,
                'trafficAdjusted': false,
              };
            }
          }
        }
        return legMap;
      }).toList();

      updatedItineraries.add({
        ...Map<String, dynamic>.from(rawItinerary),
        'legs': legs,
      });
    }

    return {
      ...routeData,
      'itineraries': updatedItineraries,
    };
  }

  Future<Map<String, dynamic>?> _fetchTomTomTrafficEstimate({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    DateTime? departAt,
  }) async {
    try {
      final uri = Uri.parse('$_backendBaseUrl/api/traffic/route').replace(
        queryParameters: {
          'from_lat': fromLat.toStringAsFixed(6),
          'from_lon': fromLon.toStringAsFixed(6),
          'to_lat': toLat.toStringAsFixed(6),
          'to_lon': toLon.toStringAsFixed(6),
          if (departAt != null) 'depart_at': departAt.toIso8601String(),
        },
      );
      final response = await _httpClient
          .get(uri, headers: await backendHeaders())
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body);
      return body is Map ? Map<String, dynamic>.from(body) : null;
    } catch (error) {
      debugPrint('TomTom e-hailing estimate unavailable: $error');
      return null;
    }
  }

  int _incidentDelaySeconds(
    Map<String, dynamic> itinerary,
    List<Map> incidents,
  ) {
    final seen = <String>{};
    var delay = 0;
    for (final leg in _itineraryLegs(itinerary)) {
      for (final incident in _incidentsForLeg(leg, incidents)) {
        final key =
            '${incident['stationName']}|${incident['type']}|${incident['route']}|${incident['reportedAt']}';
        if (!seen.add(key)) continue;
        final reportedAt = DateTime.tryParse(
          incident['reportedAt']?.toString() ?? '',
        );
        final age = reportedAt == null
            ? const Duration(days: 30)
            : DateTime.now().toUtc().difference(reportedAt.toUtc());

        final incidentType = incident['type']?.toString() ?? '';
        final int baseImpactSeconds;
        switch (incidentType) {
          case 'busReroute':
            // Rerouting or detour causes substantial route adjustment delay
            baseImpactSeconds = 480; // 8 minutes
            break;
          case 'stuckTrain':
          case 'busBreakdown':
          case 'breakdown':
            baseImpactSeconds = 720; // 12 minutes
            break;
          case 'disruption':
            baseImpactSeconds = 600; // 10 minutes
            break;
          case 'delay':
            baseImpactSeconds = 360; // 6 minutes
            break;
          case 'crowdedTrain':
          case 'crowdedStation':
            baseImpactSeconds = 240; // 4 minutes
            break;
          case 'liftFault':
          case 'escalatorFault':
            baseImpactSeconds = 120; // 2 minutes
            break;
          default:
            baseImpactSeconds = 180;
        }

        final double ageFactor = age <= const Duration(hours: 1)
            ? 1.0
            : age <= const Duration(hours: 3)
            ? 0.8
            : age <= const Duration(hours: 6)
            ? 0.5
            : age <= const Duration(days: 1)
            ? 0.25
            : 0.1;

        delay += (baseImpactSeconds * ageFactor).round();
      }
    }
    return delay.clamp(0, 1800);
  }

  List<Map<String, dynamic>> _incidentsForLeg(
    Map<String, dynamic> leg,
    List<Map> incidents,
  ) {
    final mode = leg['mode']?.toString().toUpperCase();
    if (mode == 'WALK' || mode == 'HAIL') return const [];
    final route = leg['routeShortName']?.toString().trim().toLowerCase();
    final points = <Map>[];
    if (leg['from'] is Map) points.add(leg['from'] as Map);
    if (leg['intermediateStops'] is List) {
      points.addAll((leg['intermediateStops'] as List).whereType<Map>());
    }
    if (leg['to'] is Map) points.add(leg['to'] as Map);
    final matches = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final incident in incidents) {
      final lat = (incident['station_lat'] as num?)?.toDouble();
      final lon = (incident['station_lon'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      final incidentRoute = incident['service_route']
          ?.toString()
          .trim()
          .toLowerCase();
      final routeMatches =
          incidentRoute == null ||
          incidentRoute.isEmpty ||
          route == null ||
          route == incidentRoute;
      if (!routeMatches) continue;
      final nearStop = points.any((point) {
        final pointLat = (point['lat'] as num?)?.toDouble();
        final pointLon = (point['lon'] as num?)?.toDouble();
        return pointLat != null &&
            pointLon != null &&
            Geolocator.distanceBetween(pointLat, pointLon, lat, lon) <= 180;
      });
      if (!nearStop) continue;
      final stationName =
          incident['station_name']?.toString() ?? 'Affected station';
      final type = incident['report_type']?.toString() ?? 'disruption';
      final routeName = incident['service_route']?.toString();
      final key =
          '${stationName.toLowerCase()}|${type.toLowerCase()}|${routeName?.toLowerCase() ?? ''}|${incident['reported_at'] ?? ''}';
      if (!seen.add(key)) continue;
      matches.add({
        'stationName': stationName,
        'type': type,
        'route': routeName,
        'reportedAt': incident['reported_at']?.toString(),
      });
    }
    return matches;
  }

  ({double score, int count, List<String> reports}) _incidentRiskForItinerary(
    Map<String, dynamic> itinerary,
    List<Map> incidents,
  ) {
    var score = 0.0;
    var count = 0;
    final reports = <String>[];
    for (final leg in _itineraryLegs(itinerary)) {
      for (final incident in _incidentsForLeg(leg, incidents)) {
        count++;
        score += incident['route'] == null ? 1.0 : 1.5;
        final station = incident['stationName']?.toString();
        final reportType = incident['type']?.toString();
        final detail = [
          if (reportType != null && reportType.isNotEmpty) reportType,
          if (station != null && station.isNotEmpty) 'near $station',
        ].join(' ');
        if (detail.isNotEmpty && !reports.contains(detail)) {
          reports.add(detail);
        }
      }
    }
    return (score: score, count: count, reports: reports);
  }

  Map<String, dynamic> _addDirectModeAlternatives(
    Map<String, dynamic> routeData, {
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    DateTime? departure,
  }) {
    final when = departure ?? DateTime.now();
    final existing = routeData['itineraries'];
    if (existing is! List) return routeData;

    // Convert any transit itineraries where access (first-mile) or
    // egress (last-mile) walk exceeds 1km to use car route and e-hailing.
    final convertedExisting = <Map<String, dynamic>>[];
    for (final item in existing) {
      if (item is Map) {
        final itMap = Map<String, dynamic>.from(item);
        if (isItineraryMapAvailableAtDeparture(itMap, when)) {
          convertedExisting.add(_convertExcessiveWalksToEhailing(itMap));
        }
      }
    }

    final itineraries = List<dynamic>.from(convertedExisting);
    bool hasCategory(String category) => itineraries.any(
      (itinerary) =>
          itinerary is Map &&
          itinerary['routeCategory']?.toString() == category,
    );

    final directDistance = Geolocator.distanceBetween(
      fromLat,
      fromLon,
      toLat,
      toLon,
    );
    if (directDistance > 1000 && !hasCategory('ehailing')) {
      itineraries.add(
        _offlineEhailingItinerary(
          fromLat: fromLat,
          fromLon: fromLon,
          toLat: toLat,
          toLon: toLon,
          departure: when,
        ),
      );
    }
    final firstMileAlternatives = _firstMileEhailingAlternatives(
      itineraries,
    ).where((alt) => isItineraryMapAvailableAtDeparture(alt, when)).toList();
    itineraries.addAll(firstMileAlternatives);
    // Build final-mile variants from both the original transit routes and
    // first-mile variants, so a single itinerary can use transit for its main
    // journey with e-hailing at both ends when needed.
    final lastMileAlternatives = _lastMileEhailingAlternatives([
      ...itineraries,
      ...firstMileAlternatives,
    ]).where((alt) => isItineraryMapAvailableAtDeparture(alt, when)).toList();
    itineraries.addAll(lastMileAlternatives);

    final walking = _offlineWalkingItinerary(
      fromLat: fromLat,
      fromLon: fromLon,
      toLat: toLat,
      toLon: toLon,
      departure: when,
    );
    if (!hasCategory('walking')) {
      itineraries.add(walking);
    }

    final uniqueItineraries = <Map<String, dynamic>>[];
    final seenSignatures = <String>{};
    for (final it in itineraries) {
      if (it is! Map<String, dynamic>) continue;
      final sig = _itinerarySignature(it);
      if (seenSignatures.add(sig)) {
        uniqueItineraries.add(it);
      }
    }

    return {...routeData, 'itineraries': uniqueItineraries};
  }

  Map<String, dynamic> _convertExcessiveWalksToEhailing(
    Map<String, dynamic> itinerary,
  ) {
    final category = itinerary['routeCategory']?.toString();
    if (category == 'ehailing' || category == 'walking') {
      return itinerary;
    }
    final rawLegs = itinerary['legs'];
    if (rawLegs is! List || rawLegs.isEmpty) return itinerary;

    final legs = rawLegs
        .whereType<Map>()
        .map((leg) => Map<String, dynamic>.from(leg))
        .toList();

    var changed = false;
    var hybridFirstMile = itinerary['hybridFirstMile'] == true;
    var hybridLastMile = itinerary['hybridLastMile'] == true;
    double addedFareMin = 0.0;
    double addedFareMax = 0.0;

    // Check first mile
    if (legs.isNotEmpty) {
      final first = legs.first;
      final mode = first['mode']?.toString().toUpperCase();
      if (mode == 'WALK') {
        final from = first['from'];
        final to = first['to'];
        if (from is Map &&
            to is Map &&
            from['lat'] is num &&
            from['lon'] is num &&
            to['lat'] is num &&
            to['lon'] is num) {
          final dist = _walkingLegDistanceMeters(first);
          if (dist > 1000) {
            final hailSeconds = math.max(300, (dist / 9.7).round() + 180);
            final start =
                DateTime.tryParse(first['startTime']?.toString() ?? '') ??
                DateTime.now();
            final end = start.add(Duration(seconds: hailSeconds));
            legs[0] = {
              ...first,
              'mode': 'HAIL',
              'startTime': start.toIso8601String(),
              'endTime': end.toIso8601String(),
              'routeShortName': 'E-hailing to nearest stop',
              'pickupDuration': 180,
              'distanceMeters': dist,
              'paymentMethod': 'Pay in the e-hailing app',
              'isFirstMile': true,
            };
            hybridFirstMile = true;
            changed = true;
            addedFareMin += (dist / 1000);
            addedFareMax += (dist / 1000) * 3;
          }
        }
      }
    }

    // Check last mile (the final stretch)
    if (legs.length > 1 || (legs.isNotEmpty && !hybridFirstMile)) {
      final last = legs.last;
      final mode = last['mode']?.toString().toUpperCase();
      if (mode == 'WALK') {
        final from = last['from'];
        final to = last['to'];
        if (from is Map &&
            to is Map &&
            from['lat'] is num &&
            from['lon'] is num &&
            to['lat'] is num &&
            to['lon'] is num) {
          final dist = _walkingLegDistanceMeters(last);
          if (dist > 1000) {
            final hailSeconds = math.max(300, (dist / 9.7).round() + 180);
            final start =
                DateTime.tryParse(last['startTime']?.toString() ?? '') ??
                DateTime.now();
            final end = start.add(Duration(seconds: hailSeconds));
            legs[legs.length - 1] = {
              ...last,
              'mode': 'HAIL',
              'startTime': start.toIso8601String(),
              'endTime': end.toIso8601String(),
              'routeShortName': 'E-hailing from nearest stop',
              'pickupDuration': 180,
              'distanceMeters': dist,
              'paymentMethod': 'Pay in the e-hailing app',
              'isLastMile': true,
            };
            hybridLastMile = true;
            changed = true;
            addedFareMin += (dist / 1000);
            addedFareMax += (dist / 1000) * 3;
          }
        }
      }
    }

    if (!changed) return itinerary;

    final origDuration = (itinerary['duration'] as num?)?.toInt() ?? 0;
    final updatedDuration = _durationFromLegs(legs, origDuration);
    final walkingSeconds = legs
        .where((l) => l['mode']?.toString().toUpperCase() == 'WALK')
        .fold<int>(0, (total, leg) {
          final start = DateTime.tryParse(leg['startTime']?.toString() ?? '');
          final end = DateTime.tryParse(leg['endTime']?.toString() ?? '');
          return total +
              (start != null && end != null
                  ? end.difference(start).inSeconds
                  : 0);
        });

    final previousFareMin =
        (itinerary['fareMin'] as num?)?.toDouble() ??
        (itinerary['fareAmount'] as num?)?.toDouble() ??
        0.0;
    final previousFareMax =
        (itinerary['fareMax'] as num?)?.toDouble() ?? previousFareMin;

    final fareLabel = hybridFirstMile && hybridLastMile
        ? 'Estimated first and last-mile e-hailing fare'
        : hybridLastMile
        ? 'Estimated connecting e-hailing fare'
        : 'Estimated first-mile e-hailing fare';

    final optionMessage = hybridFirstMile && hybridLastMile
        ? 'E-hailing to the nearest stop and from the last stop, with public transport for the main journey.'
        : hybridLastMile
        ? 'Public transport with e-hailing for the final mile because the destination is more than 1 km from the last stop.'
        : 'E-hailing to the nearest stop, followed by public transport. This avoids a long walk to a connecting service.';

    return {
      ...itinerary,
      'duration': updatedDuration,
      'walkingSeconds': walkingSeconds,
      'routeCategory': 'hybrid',
      'hybridFirstMile': hybridFirstMile,
      'hybridLastMile': hybridLastMile,
      'fareMin': previousFareMin + addedFareMin,
      'fareMax': previousFareMax + addedFareMax,
      'fareLabel': fareLabel,
      'optionMessage': optionMessage,
      'legs': legs,
    };
  }

  double _walkingLegDistanceMeters(Map<String, dynamic> leg) {
    final from = leg['from'];
    final to = leg['to'];
    double? straightDistance;
    if (from is Map &&
        to is Map &&
        from['lat'] is num &&
        from['lon'] is num &&
        to['lat'] is num &&
        to['lon'] is num) {
      straightDistance = Geolocator.distanceBetween(
        (from['lat'] as num).toDouble(),
        (from['lon'] as num).toDouble(),
        (to['lat'] as num).toDouble(),
        (to['lon'] as num).toDouble(),
      );
    }

    final reportedDistance =
        (leg['distanceMeters'] as num?)?.toDouble() ??
        (leg['distance'] as num?)?.toDouble();
    if (reportedDistance != null && reportedDistance > 0) {
      if (straightDistance != null &&
          straightDistance <= 500 &&
          reportedDistance > straightDistance * 2.0) {
        return straightDistance;
      }
      return reportedDistance;
    }

    final geometry = leg['legGeometry'] ?? leg['geometry'];
    if (geometry is Map && geometry['coordinates'] is List) {
      final coordinates = (geometry['coordinates'] as List)
          .whereType<List>()
          .where((point) => point.length >= 2)
          .toList();
      var distance = 0.0;
      for (var i = 1; i < coordinates.length; i++) {
        final previous = coordinates[i - 1];
        final current = coordinates[i];
        if (previous[0] is! num ||
            previous[1] is! num ||
            current[0] is! num ||
            current[1] is! num) {
          continue;
        }
        distance += Geolocator.distanceBetween(
          (previous[1] as num).toDouble(),
          (previous[0] as num).toDouble(),
          (current[1] as num).toDouble(),
          (current[0] as num).toDouble(),
        );
      }
      if (distance > 0) {
        if (straightDistance != null &&
            straightDistance <= 500 &&
            distance > straightDistance * 2.0) {
          return straightDistance;
        }
        return distance;
      }
    }

    if (straightDistance != null) return straightDistance;
    return 0;
  }

  String _itinerarySignature(Map<String, dynamic> itinerary) {
    final rawLegs = itinerary['legs'];
    if (rawLegs is! List) return '';
    return rawLegs
        .map((l) {
          if (l is! Map) return '';
          final mode = l['mode']?.toString() ?? '';
          final name = l['routeShortName']?.toString() ?? '';
          final fromName = l['from'] is Map ? (l['from']['name'] ?? '') : '';
          final toName = l['to'] is Map ? (l['to']['name'] ?? '') : '';
          return '$mode:$name:$fromName->$toName';
        })
        .join(';');
  }

  List<Map<String, dynamic>> _firstMileEhailingAlternatives(
    List<dynamic> itineraries,
  ) {
    final alternatives = <Map<String, dynamic>>[];
    for (final itinerary in itineraries) {
      if (itinerary is! Map<String, dynamic> ||
          itinerary['routeCategory']?.toString() == 'ehailing' ||
          itinerary['routeCategory']?.toString() == 'walking') {
        continue;
      }
      final sourceLegs = itinerary['legs'];
      if (sourceLegs is! List || sourceLegs.isEmpty) continue;
      final first = sourceLegs.first;
      if (first is! Map<String, dynamic> ||
          first['mode']?.toString().toUpperCase() != 'WALK') {
        continue;
      }
      final from = first['from'];
      final to = first['to'];
      if (from is! Map || to is! Map) continue;
      final fromLat = (from['lat'] as num?)?.toDouble();
      final fromLon = (from['lon'] as num?)?.toDouble();
      final toLat = (to['lat'] as num?)?.toDouble();
      final toLon = (to['lon'] as num?)?.toDouble();
      if (fromLat == null ||
          fromLon == null ||
          toLat == null ||
          toLon == null) {
        continue;
      }

      final distanceMeters = _walkingLegDistanceMeters(
        Map<String, dynamic>.from(first),
      );
      if (distanceMeters <= 1000) continue;
      final hailSeconds = math.max(300, (distanceMeters / 9.7).round() + 180);
      final walkStart = DateTime.tryParse(first['startTime']?.toString() ?? '');
      final walkEnd = DateTime.tryParse(first['endTime']?.toString() ?? '');
      if (walkStart == null || walkEnd == null) continue;
      final hailEnd = walkStart.add(Duration(seconds: hailSeconds));
      final firstTransit = sourceLegs.skip(1).cast<Map>().firstWhere((leg) {
        final mode = leg['mode']?.toString().toUpperCase();
        return mode != 'WALK' && mode != 'HAIL';
      }, orElse: () => const <String, dynamic>{});
      final transitStart = DateTime.tryParse(
        firstTransit['startTime']?.toString() ?? '',
      );
      if (transitStart == null) continue;
      final legs = sourceLegs
          .map((leg) => Map<String, dynamic>.from(leg as Map))
          .toList();
      legs[0] = {
        ...legs[0],
        'mode': 'HAIL',
        'startTime': walkStart.toIso8601String(),
        'endTime': hailEnd.toIso8601String(),
        'routeShortName': 'E-hailing to nearest stop',
        'pickupDuration': 180,
        'distanceMeters': distanceMeters,
        'paymentMethod': 'Pay in the e-hailing app',
        'from': from,
        'to': to,
      };
      final walkingSeconds =
          (itinerary['walkingSeconds'] as num?)?.toInt() ?? 0;
      final duration = (itinerary['duration'] as num?)?.toInt() ?? 0;
      final updatedDuration = _durationFromLegs(legs, duration);
      final previousFareMin =
          (itinerary['fareMin'] as num?)?.toDouble() ??
          (itinerary['fareAmount'] as num?)?.toDouble() ??
          0;
      final previousFareMax =
          (itinerary['fareMax'] as num?)?.toDouble() ?? previousFareMin;
      final hailFarePerKm = distanceMeters / 1000;
      alternatives.add({
        ...itinerary,
        'duration': updatedDuration,
        'walkingSeconds': math.max(
          0,
          walkingSeconds - walkEnd.difference(walkStart).inSeconds,
        ),
        'fareMin': previousFareMin + hailFarePerKm,
        'fareMax': previousFareMax + hailFarePerKm * 3,
        'fareLabel': 'Estimated first-mile e-hailing fare',
        'routeCategory': 'hybrid',
        'hybridFirstMile': true,
        'optionMessage':
            'E-hailing to the nearest stop, followed by public transport. '
            'This avoids a long walk to a connecting service.',
        'legs': legs,
      });
    }
    return alternatives;
  }

  List<Map<String, dynamic>> _lastMileEhailingAlternatives(
    List<dynamic> itineraries,
  ) {
    final alternatives = <Map<String, dynamic>>[];
    for (final itinerary in itineraries) {
      if (itinerary is! Map<String, dynamic> ||
          itinerary['routeCategory']?.toString() == 'ehailing' ||
          itinerary['routeCategory']?.toString() == 'walking') {
        continue;
      }
      final sourceLegs = itinerary['legs'];
      if (sourceLegs is! List || sourceLegs.isEmpty) continue;
      final last = sourceLegs.last;
      if (last is! Map<String, dynamic>) continue;
      final mode = last['mode']?.toString().toUpperCase();
      if (mode != 'WALK' && mode != 'HAIL') continue;
      final from = last['from'];
      final to = last['to'];
      if (from is! Map || to is! Map) continue;
      final fromLat = (from['lat'] as num?)?.toDouble();
      final fromLon = (from['lon'] as num?)?.toDouble();
      final toLat = (to['lat'] as num?)?.toDouble();
      final toLon = (to['lon'] as num?)?.toDouble();
      if (fromLat == null ||
          fromLon == null ||
          toLat == null ||
          toLon == null) {
        continue;
      }
      final distanceMeters = _walkingLegDistanceMeters(
        Map<String, dynamic>.from(last),
      );
      if (distanceMeters <= 1000) continue;
      final start = DateTime.tryParse(last['startTime']?.toString() ?? '');
      if (start == null) continue;
      final hailSeconds = math.max(300, (distanceMeters / 9.7).round() + 180);
      final end = start.add(Duration(seconds: hailSeconds));
      final legs = sourceLegs
          .map((leg) => Map<String, dynamic>.from(leg as Map))
          .toList();
      legs[legs.length - 1] = {
        ...legs.last,
        'mode': 'HAIL',
        'startTime': start.toIso8601String(),
        'endTime': end.toIso8601String(),
        'routeShortName': 'E-hailing from nearest stop',
        'pickupDuration': 180,
        'distanceMeters': distanceMeters,
        'paymentMethod': 'Pay in the e-hailing app',
        'isLastMile': true,
        'from': from,
        'to': to,
      };
      final originalDuration = (itinerary['duration'] as num?)?.toInt() ?? 0;
      final originalWalkSeconds =
          (itinerary['walkingSeconds'] as num?)?.toInt() ?? 0;
      final previousFareMin =
          (itinerary['fareMin'] as num?)?.toDouble() ??
          (itinerary['fareAmount'] as num?)?.toDouble() ??
          0;
      final previousFareMax =
          (itinerary['fareMax'] as num?)?.toDouble() ?? previousFareMin;
      final hailFarePerKm = distanceMeters / 1000;
      final includesFirstMile = itinerary['hybridFirstMile'] == true;
      final originalEnd = DateTime.tryParse(last['endTime']?.toString() ?? '');
      final replacedSeconds = originalEnd == null
          ? 0
          : originalEnd.difference(start).inSeconds;
      final updatedDuration = _durationFromLegs(legs, originalDuration);
      alternatives.add({
        ...itinerary,
        'duration': updatedDuration,
        'walkingSeconds': math.max(0, originalWalkSeconds - replacedSeconds),
        'fareMin': previousFareMin + hailFarePerKm,
        'fareMax': previousFareMax + hailFarePerKm * 3,
        'fareLabel': includesFirstMile
            ? 'Estimated first and last-mile e-hailing fare'
            : 'Estimated connecting e-hailing fare',
        'routeCategory': 'hybrid',
        'hybridLastMile': true,
        'optionMessage': includesFirstMile
            ? 'E-hailing to the nearest stop and from the last stop, with public transport for the main journey.'
            : 'Public transport with e-hailing for the final mile because '
                  'the destination is more than 1 km from the last stop.',
        'legs': legs,
      });
    }
    return alternatives;
  }

  Map<String, dynamic> _offlineWalkingItinerary({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    DateTime? departure,
  }) {
    final distanceMeters = Geolocator.distanceBetween(
      fromLat,
      fromLon,
      toLat,
      toLon,
    );
    // Keep a direct walking option for every journey as a full fallback.
    final walkingSeconds = math.max(
      60,
      (distanceMeters / _walkingSpeedMetersPerSecond).round(),
    );
    final start = departure ?? DateTime.now();
    final end = start.add(Duration(seconds: walkingSeconds));
    return {
      'duration': walkingSeconds,
      'distanceMeters': distanceMeters,
      'walkingSeconds': walkingSeconds,
      'transferCount': 0,
      'routeCategory': 'walking',
      'optionMessage': 'Direct walking option using pedestrian paths.',
      'legs': [
        {
          'mode': 'WALK',
          'startTime': start.toIso8601String(),
          'endTime': end.toIso8601String(),
          'routeShortName': 'Walking',
          'from': {'name': 'Start', 'lat': fromLat, 'lon': fromLon},
          'to': {'name': 'Destination', 'lat': toLat, 'lon': toLon},
        },
      ],
    };
  }

  Map<String, dynamic> _offlineEhailingItinerary({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    DateTime? departure,
  }) {
    final distanceMeters = Geolocator.distanceBetween(
      fromLat,
      fromLon,
      toLat,
      toLon,
    );
    // A planning estimate only: OSRM supplies the actual line geometry later.
    final drivingSeconds = math.max(300, (distanceMeters / 9.7).round() + 180);
    final start = departure ?? DateTime.now();
    final end = start.add(Duration(seconds: drivingSeconds));
    return {
      'duration': drivingSeconds,
      'distanceMeters': distanceMeters,
      'walkingSeconds': 0,
      'transferCount': 0,
      'fareMin': distanceMeters / 1000,
      'fareMax': distanceMeters / 1000 * 3,
      'fareLabel': 'Estimated e-hailing fare',
      'routeCategory': 'ehailing',
      'optionMessage':
          'Direct e-hailing option — fare and traffic are determined by the booking provider.',
      'legs': [
        {
          'mode': 'HAIL',
          'startTime': start.toIso8601String(),
          'endTime': end.toIso8601String(),
          'routeShortName': 'E-hailing',
          'pickupDuration': 180,
          'paymentMethod': 'Pay in the e-hailing app',
          'from': {'name': 'Pickup', 'lat': fromLat, 'lon': fromLon},
          'to': {'name': 'Destination', 'lat': toLat, 'lon': toLon},
        },
      ],
    };
  }

  Future<void> _drawItinerary(
    List<Map<String, dynamic>> legs,
    int renderGeneration,
  ) async {
    if (!_isCurrentItineraryRender(renderGeneration)) return;
    // 1. Clear any old routing layers and sources to keep the canvas clean
    for (final layerId in [
      'route_transit_layer',
      'route_walk_layer',
      // Remove the legacy e-hailing layer so a hot reload cannot leave its
      // stale straight-line geometry on the map.
      'route_ehailing_layer',
      'route_ehailing',
      'ehailing_layer',
      'hail_layer',
    ]) {
      try {
        await _mapController?.removeLayer(layerId);
      } catch (_) {}
    }
    for (final sourceId in [
      'route_transit_source',
      'route_walk_source',
      'route_ehailing_source',
      'route_ehailing',
      'ehailing_source',
      'hail_source',
    ]) {
      try {
        await _mapController?.removeSource(sourceId);
      } catch (_) {}
    }

    final walkFeatures = <Map<String, dynamic>>[];
    final transitFeatures = <Map<String, dynamic>>[];
    final hailFeatures = <Map<String, dynamic>>[];
    final routeCoordinates = <List<double>>[];
    bool hasGeometry = false;

    // 2. Loop through legs and separate geometries by transport mode
    for (final leg in legs) {
      if (!_isCurrentItineraryRender(renderGeneration)) return;
      final mode = leg['mode'] as String? ?? 'WALK';
      final legCoordinates = <List<double>>[];
      final isStreetLeg = _isStreetLegMode(mode);
      // Transit geometry comes from GTFS. Walking and e-hailing geometry must
      // follow the street network between the user's actual coordinates.
      if (isStreetLeg) {
        if (mode.toUpperCase() == 'WALK' &&
            (leg['isTransferWalk'] == true ||
                leg['isDirectPedestrian'] == true)) {
          // A station interchange or direct pedestrian walkway connects the
          // points directly instead of routing around the road network.
          final from = leg['from'];
          final to = leg['to'];
          if (from is Map &&
              to is Map &&
              from['lon'] is num &&
              from['lat'] is num &&
              to['lon'] is num &&
              to['lat'] is num) {
            legCoordinates.addAll([
              [
                (from['lon'] as num).toDouble(),
                (from['lat'] as num).toDouble(),
              ],
              [(to['lon'] as num).toDouble(), (to['lat'] as num).toDouble()],
            ]);
          }
        } else {
          legCoordinates.addAll(await _fetchRoadGeometry(leg));
        }
        if (!_isCurrentItineraryRender(renderGeneration)) return;
      }
      final geometry = leg['legGeometry'];
      if (leg['geometryQuality'] == 'unverified' &&
          mode.toUpperCase() == 'BUS') {
        legCoordinates.addAll(await _fetchBusRoadGeometry(leg));
      }
      if (legCoordinates.isEmpty &&
          !isStreetLeg &&
          leg['geometryQuality'] != 'unverified' &&
          geometry is Map &&
          geometry['points'] is String) {
        final points = geometry['points'] as String;
        final precision = geometry['precision'] is num
            ? (geometry['precision'] as num).toInt()
            : 5;
        legCoordinates.addAll(_decodePolyline(points, precision: precision));
      } else if (legCoordinates.isEmpty &&
          !isStreetLeg &&
          leg['geometryQuality'] != 'unverified' &&
          geometry is Map &&
          geometry['coordinates'] is List) {
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
      }

      if (isStreetLeg && legCoordinates.isEmpty) {
        final from = leg['from'];
        final to = leg['to'];
        if (from is Map &&
            to is Map &&
            from['lat'] is num &&
            from['lon'] is num &&
            to['lat'] is num &&
            to['lon'] is num) {
          legCoordinates.addAll([
            [(from['lon'] as num).toDouble(), (from['lat'] as num).toDouble()],
            [(to['lon'] as num).toDouble(), (to['lat'] as num).toDouble()],
          ]);
        } else {
          print(
            '[JomRide][route] Omitted ${mode.toUpperCase()} line because road '
            'geometry was unavailable',
          );
          continue;
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
      } else if (mode.toUpperCase() == 'HAIL') {
        hailFeatures.add(feature);
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
      if (!_isCurrentItineraryRender(renderGeneration)) return;
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
      if (!_isCurrentItineraryRender(renderGeneration)) return;
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

    if (hailFeatures.isNotEmpty &&
        _isCurrentItineraryRender(renderGeneration)) {
      await _mapController?.addSource(
        'route_ehailing_source',
        GeojsonSourceProperties(
          data: {"type": "FeatureCollection", "features": hailFeatures},
        ),
      );
      if (!_isCurrentItineraryRender(renderGeneration)) return;
      await _mapController?.addLineLayer(
        'route_ehailing_source',
        'route_ehailing_layer',
        const LineLayerProperties(
          lineColor: '#7C3AED',
          lineWidth: 5.0,
          lineOpacity: 0.9,
          lineCap: 'round',
          lineJoin: 'round',
        ),
      );
    }

    if (_isCurrentItineraryRender(renderGeneration) &&
        !_itineraryUserInteracted) {
      await _focusItineraryOnMap(routeCoordinates);
    }
  }

  bool _isStreetLegMode(String mode) {
    final normalized = mode.toUpperCase().replaceAll(RegExp(r'[-_ ]'), '');
    return normalized == 'WALK' ||
        normalized == 'HAIL' ||
        normalized == 'EHAILING' ||
        normalized == 'TAXI' ||
        normalized == 'CAR';
  }

  Future<List<List<double>>> _fetchRoadGeometry(
    Map<String, dynamic> leg,
  ) async {
    final from = leg['from'];
    final to = leg['to'];
    if (from is! Map ||
        to is! Map ||
        from['lat'] is! num ||
        from['lon'] is! num ||
        to['lat'] is! num ||
        to['lon'] is! num) {
      print('[JomRide][route] Street leg has invalid from/to coordinates');
      return const [];
    }

    final fromLon = (from['lon'] as num).toDouble();
    final fromLat = (from['lat'] as num).toDouble();
    final toLon = (to['lon'] as num).toDouble();
    final toLat = (to['lat'] as num).toDouble();
    if (!_isSupportedCoordinate(fromLat, fromLon) ||
        !_isSupportedCoordinate(toLat, toLon)) {
      print(
        '[JomRide][route] Rejected street leg outside Klang Valley '
        '(from=$fromLat,$fromLon to=$toLat,$toLon)',
      );
      return const [];
    }
    final normalizedMode = leg['mode']?.toString().toUpperCase() ?? '';
    final isWalking = normalizedMode == 'WALK';
    // The OSM routing service exposes separate pedestrian and vehicle
    // profiles. Using the vehicle profile for WALK can create long road
    // detours that do not reflect a usable pedestrian path.
    final routerBase = isWalking
        ? 'https://routing.openstreetmap.de/routed-foot'
        : 'https://router.project-osrm.org';
    final profile = isWalking ? 'foot' : 'driving';
    final uri = Uri.parse(
      '$routerBase/route/v1/$profile/'
      '$fromLon,$fromLat;$toLon,$toLat'
      '?overview=full&alternatives=true&geometries=geojson&steps=false',
    );
    print(
      '[JomRide][route] Requesting OSM '
      '${isWalking ? 'pedestrian' : 'street'} geometry '
      '($normalizedMode): $uri',
    );
    try {
      final response = await _httpClient
          .get(uri)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        print(
          '[JomRide][route] OSM road router failed '
          '(${response.statusCode}): ${response.body}',
        );
        return const [];
      }
      final decoded = jsonDecode(response.body);
      final routes = decoded is Map ? decoded['routes'] : null;
      final route = _shortestRouterRoute(routes);
      dynamic coordinates;
      if (route != null) {
        final geometry = route['geometry'];
        coordinates = geometry is Map ? geometry['coordinates'] : null;
      }
      if (coordinates is! List) {
        print('[JomRide][route] OSM road router returned no geometry');
        return const [];
      }
      final result = <List<double>>[];
      for (final coordinate in coordinates) {
        if (coordinate is List &&
            coordinate.length >= 2 &&
            coordinate[0] is num &&
            coordinate[1] is num) {
          result.add([
            (coordinate[0] as num).toDouble(),
            (coordinate[1] as num).toDouble(),
          ]);
        }
      }
      if (result.length < 2 ||
          result.any((point) => !_isSupportedCoordinate(point[1], point[0]))) {
        print(
          '[JomRide][route] Rejected OSM road geometry outside Klang Valley '
          '(points=${result.length})',
        );
        return const [];
      }
      final routedDistance = _polylineDistanceMeters(result);
      final straightDistance = Geolocator.distanceBetween(
        fromLat,
        fromLon,
        toLat,
        toLon,
      );
      if (isWalking &&
          ((straightDistance <= 1200 &&
                  (routedDistance > straightDistance * 2.2 ||
                      routedDistance > straightDistance + 400)) ||
              (routedDistance > straightDistance * 3.0))) {
        print(
          '[JomRide][route] Suppressed off-road highway detour for pedestrian leg '
          '(straight=${straightDistance.toStringAsFixed(1)}m, routed=${routedDistance.toStringAsFixed(1)}m). '
          'Using direct pedestrian connection.',
        );
        return [
          [fromLon, fromLat],
          [toLon, toLat],
        ];
      }
      final privateConnector = _sunwayPrivatePedestrianConnector(
        fromLat: fromLat,
        fromLon: fromLon,
        toLat: toLat,
        toLon: toLon,
        routedDistance: routedDistance,
      );
      if (privateConnector != null) {
        print(
          '[JomRide][route] Using curated Sunway pedestrian connector '
          '(points=${privateConnector.length})',
        );
        return privateConnector;
      }
      print(
        '[JomRide][route] SUCCESS OSM road geometry '
        '(points=${result.length})',
      );
      return result;
    } catch (error) {
      print('[JomRide][route] OSM road geometry request failed: $error');
      return const [];
    }
  }

  Future<List<List<double>>> _fetchBusRoadGeometry(
    Map<String, dynamic> leg,
  ) async {
    final points = <Map<String, dynamic>>[];
    final from = leg['from'];
    final intermediate = leg['intermediateStops'];
    final to = leg['to'];
    if (from is Map) points.add(Map<String, dynamic>.from(from));
    if (intermediate is List) {
      points.addAll(
        intermediate.whereType<Map>().map(Map<String, dynamic>.from),
      );
    }
    if (to is Map) points.add(Map<String, dynamic>.from(to));
    if (points.length < 2 ||
        points.any(
          (point) =>
              point['lat'] is! num ||
              point['lon'] is! num ||
              !_isSupportedCoordinate(
                (point['lat'] as num).toDouble(),
                (point['lon'] as num).toDouble(),
              ),
        )) {
      return const [];
    }
    final coordinates = points
        .map(
          (point) =>
              '${(point['lon'] as num).toDouble()},${(point['lat'] as num).toDouble()}',
        )
        .join(';');
    final uri = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/$coordinates'
      '?overview=full&geometries=geojson&steps=false',
    );
    try {
      final response = await _httpClient
          .get(uri)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(response.body);
      final route = _shortestRouterRoute(
        decoded is Map ? decoded['routes'] : null,
      );
      if (route == null) return const [];
      final geometry = route['geometry'];
      final rawCoordinates = geometry is Map ? geometry['coordinates'] : null;
      if (rawCoordinates is! List) return const [];
      final result = rawCoordinates
          .whereType<List>()
          .where(
            (point) => point.length >= 2 && point[0] is num && point[1] is num,
          )
          .map(
            (point) => [
              (point[0] as num).toDouble(),
              (point[1] as num).toDouble(),
            ],
          )
          .where((point) => _isSupportedCoordinate(point[1], point[0]))
          .toList();
      return result.length >= 2 ? result : const [];
    } catch (error) {
      debugPrint('Bus road geometry request failed: $error');
      return const [];
    }
  }

  Map<String, dynamic>? _shortestRouterRoute(dynamic routes) {
    if (routes is! List) return null;
    Map<String, dynamic>? best;
    var bestDistance = double.infinity;
    for (final candidate in routes) {
      if (candidate is! Map) continue;
      final distance = (candidate['distance'] as num?)?.toDouble();
      if (distance == null || distance < bestDistance) {
        best = Map<String, dynamic>.from(candidate);
        bestDistance = distance ?? bestDistance;
      }
    }
    return best;
  }

  double _polylineDistanceMeters(List<List<double>> coordinates) {
    var distance = 0.0;
    for (var index = 1; index < coordinates.length; index++) {
      distance += Geolocator.distanceBetween(
        coordinates[index - 1][1],
        coordinates[index - 1][0],
        coordinates[index][1],
        coordinates[index][0],
      );
    }
    return distance;
  }

  List<List<double>>? _sunwayPrivatePedestrianConnector({
    required double fromLat,
    required double fromLon,
    required double toLat,
    required double toLon,
    required double routedDistance,
  }) {
    // OSM's public graph does not consistently contain the controlled
    // pedestrian links around Sunway Pyramid, Sunway University and the
    // Sunway Lagoon/BRT interchange. Only use these bounded, curated
    // corridors when both endpoints are close to the same corridor and the
    // public-footway result is clearly an outside-road detour.
    if (fromLat < 3.060 ||
        fromLat > 3.078 ||
        toLat < 3.060 ||
        toLat > 3.078 ||
        fromLon < 101.600 ||
        fromLon > 101.620 ||
        toLon < 101.600 ||
        toLon > 101.620) {
      return null;
    }

    const corridors = <List<List<double>>>[
      [
        [101.60590, 3.07360], // Sunway Pyramid
        [101.60715, 3.07255],
        [101.60855, 3.07165],
        [101.60965, 3.07095],
        [101.61065, 3.07084], // Sunway Lagoon BRT
      ],
      [
        [101.60386, 3.06717], // Sunway University
        [101.60620, 3.06655],
        [101.60960, 3.06575],
        [101.61335, 3.06455],
        [101.61706, 3.06328], // Taylor's Lakeside
      ],
    ];

    List<List<double>>? best;
    var bestDistance = double.infinity;
    for (final corridor in corridors) {
      final endpointDistance = _distanceToPolylineMeters(
        fromLat,
        fromLon,
        corridor,
      );
      final destinationDistance = _distanceToPolylineMeters(
        toLat,
        toLon,
        corridor,
      );
      if (endpointDistance > 900 || destinationDistance > 900) continue;

      final candidate = <List<double>>[
        [fromLon, fromLat],
        ...corridor,
        [toLon, toLat],
      ];
      final candidateDistance = _polylineDistanceMeters(candidate);
      if (candidateDistance < bestDistance) {
        best = candidate;
        bestDistance = candidateDistance;
      }
    }
    if (best == null || routedDistance < bestDistance * 1.35) return null;
    return best;
  }

  double _distanceToPolylineMeters(
    double lat,
    double lon,
    List<List<double>> polyline,
  ) {
    var best = double.infinity;
    for (final point in polyline) {
      best = math.min(
        best,
        Geolocator.distanceBetween(lat, lon, point[1], point[0]),
      );
    }
    return best;
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

  void _onMapCreated(MapLibreMapController controller, int styleVersion) {
    ++_mapGeneration;
    _mapController = controller;
    _mapControllerStyleVersion = styleVersion;
    // Annotation handles belong to a specific MapLibre instance. Recreate
    // the blue location marker when the map view is rebuilt.
    _userLocationMarker = null;
    _userLocationHalo = null;
    print(
      '[JomRide][map] MapLibre controller created '
      '(web=$kIsWeb, generation=$_mapGeneration, styleReady=${_dynamicStyleString != null})',
    );
    print(
      '[JomRide][map] Initial camera target=3.1390,101.6868 zoom=12; '
      'source=Protomaps PMTiles',
    );
  }

  void _onMapStyleLoaded(int styleVersion) {
    if (styleVersion != _mapStyleVersion ||
        styleVersion != _mapControllerStyleVersion) {
      return;
    }
    final controller = _mapController;
    final generation = _mapGeneration;
    if (controller == null || _initializedMapGeneration == generation) return;
    _initializedMapGeneration = generation;
    unawaited(_initializeMapStyle(controller, generation));
  }

  Future<void> _initializeMapStyle(
    MapLibreMapController controller,
    int generation,
  ) async {
    if (!mounted || generation != _mapGeneration) return;
    print('[JomRide][map] MapLibre style reported as loaded');
    await _loadAndRenderOfflineRailLines(controller);
    if (!mounted || generation != _mapGeneration) return;
    await _loadAndRenderOfflineStops(controller);
    if (!mounted || generation != _mapGeneration) return;
    await _loadAndRenderStationPerimeters(controller);
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
    if (_currentRawItinerary != null) {
      final legs = _itineraryLegs(_currentRawItinerary!);
      unawaited(_renderItinerary(legs, _itineraryRenderGeneration));
    }
  }

  Future<Position?> _startLocationTracking() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _showMessage('Turn on location services to show your position.');
      return null;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      _showMessage('Location permission was not granted.');
      return null;
    }
    if (permission == LocationPermission.deniedForever) {
      _showMessage('Enable location permission in your device settings.');
      return null;
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
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      await _updateUserLocation(position);
      return position;
    } catch (_) {
      _showMessage('Could not get your current location.');
      return null;
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
    // Keep the station card's distance in sync with every GPS update, even
    // when the nearest station itself has not changed.
    _updateNearestTransitStop(position);
    // GPS can emit several updates per second on some devices. Station
    // presence tracking and interchange prompts do not need that frequency;
    // keep those more expensive operations to one pass every five seconds.
    final now = DateTime.now();
    final shouldRunLocationWork =
        _lastLocationWorkAt == null ||
        now.difference(_lastLocationWorkAt!) >= const Duration(seconds: 5);
    if (shouldRunLocationWork) {
      _lastLocationWorkAt = now;
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

  void _updateNearestTransitStop(Position position) {
    if (_transitStopsById.isEmpty || !mounted) return;
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
    setState(() => _nearestTransitStop = stop);
  }

  TransitStop? _nearestTransitStopWithin(
    double lat,
    double lon,
    double maxDistanceMeters,
  ) {
    if (_transitStopsById.isEmpty) return null;
    TransitStop? closest;
    var closestDist = maxDistanceMeters;
    for (final stop in _transitStopsById.values) {
      final dist = Geolocator.distanceBetween(lat, lon, stop.lat, stop.lon);
      if (dist <= closestDist) {
        closest = stop;
        closestDist = dist;
      }
    }
    return closest;
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

  Future<void> _logAnonymousStationPresence(TransitStop stop) async {
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
        // Safe recovery
      }
    }
    if (auth.currentSession == null) {
      _showMessage('Your sign-in session has expired. Please sign in again.');
      return;
    }
    if (_lastKnownPosition == null) await _startLocationTracking();
    if (!mounted) return;
    final position = _lastKnownPosition;
    if (position == null) {
      _showMessage('Your location is needed to report an incident.');
      return;
    }
    if (_transitStopsById.isEmpty) {
      _showMessage('Nearby transit data is still loading. Please try again.');
      return;
    }

    _updateNearestTransitStop(position);
    final stop = _nearestTransitStop;
    if (stop == null) {
      _showMessage('No nearby transit stations or stops found.');
      return;
    }

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

    final submission = await showModalBottomSheet<IncidentReportSubmission>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => IncidentTypeSelectionSheet(
        isBusStop: isBusStop,
        stopName: stop.name,
        affectedRoute: affectedRoute,
      ),
    );
    if (submission == null) return;
    final report = submission.type;
    final comment = submission.comment;

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
          if (comment != null && comment.isNotEmpty) 'comment': comment,
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

  Future<void> _focusNearestTransitStop() async {
    final stop = _nearestTransitStop;
    if (stop == null) return;
    await _mapController?.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(stop.lat, stop.lon), 16),
    );
    if (!mounted) return;
    _showStopDetails(
      stopId: stop.id,
      stopName: stop.name,
      routes: stop.routes,
      transitType: stop.transitType,
      stop: stop,
    );
  }

  Future<void> _showMyLocation() async {
    final controller = _mapController;
    if (controller == null) return;

    // The position stream is started with the map and continually keeps this
    // value fresh. Use it immediately so a button tap recentres without
    // waiting for another high-accuracy GPS fix (which can be slow on mobile).
    var position = _lastKnownPosition;
    if (position == null) {
      // iOS may have a recent system fix even before the app's position stream
      // has delivered its first event.
      try {
        position = await Geolocator.getLastKnownPosition();
        if (position != null) _lastKnownPosition = position;
      } catch (error) {
        debugPrint('[JomRide][location] Last-known lookup failed: $error');
      }
    }
    if (position == null) {
      try {
        // First use still needs to request permission and obtain a fix.
        position = await _startLocationTracking() ?? _lastKnownPosition;
      } catch (error) {
        debugPrint('[JomRide][location] Show-my-location failed: $error');
      }
    }
    if (!mounted ||
        position == null ||
        !identical(controller, _mapController)) {
      return;
    }

    try {
      // iOS MapLibre's move API is synchronous at the platform boundary;
      // using it avoids animation requests being dropped while the native
      // map is resuming location/render work after a touch.
      await controller.moveCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(position.latitude, position.longitude),
          16,
        ),
      );
      // The GPS stream also renders this marker; keep an explicit render here
      // for the first tap if its initial stream event has not arrived yet.
      await _renderUserLocation(controller, position);
    } catch (error) {
      debugPrint('[JomRide][location] Center-on-location failed: $error');
      if (mounted) _showMessage('Could not move the map to your location.');
    }
  }

  Future<void> _showNorth() async {
    final controller = _mapController;
    if (controller == null) return;
    try {
      // maplibre_gl's web implementation throws UnimplementedError for
      // queryCameraPosition, so web must use the camera callback we track.
      // Native versions can query the live camera and fall back to that cache.
      // The tracked camera is available on all platforms and avoids a native
      // query round-trip that can race with iOS touch/camera updates.
      final camera =
          _lastCameraPosition ??
          const CameraPosition(target: LatLng(3.1390, 101.6868), zoom: 12);
      await controller.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: camera.target,
            zoom: camera.zoom,
            bearing: 0,
            tilt: camera.tilt,
          ),
        ),
      );
    } catch (error) {
      debugPrint('[JomRide][map] Reset-north failed: $error');
      if (mounted) _showMessage('Could not reset the map direction.');
    }
  }

  Future<void> _loadAndRenderOfflineRailLines(
    MapLibreMapController controller,
  ) async {
    try {
      final geoJson = jsonDecode(
        await rootBundle.loadString('assets/transit/rail_lines.geojson'),
      );
      if (geoJson is! Map<String, dynamic>) {
        _showMessage('The bundled rail-line data is invalid.');
        return;
      }

      if (!mounted || !identical(controller, _mapController)) return;
      await controller.addSource(
        'offline_rail_lines_source',
        GeojsonSourceProperties(data: geoJson),
      );
      if (!mounted || !identical(controller, _mapController)) return;
      await controller.addLineLayer(
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
    if (_currentItinerary != null ||
        _isCardExpanded ||
        _isStationDetailsOpen ||
        _isRouteChoicesOpen ||
        _suppressMapTapFromOverlay) {
      return;
    }
    final features = await _mapController?.queryRenderedFeatures(point, [
      'rail_stop_hit_targets_layer',
      'bus_stop_hit_targets_layer',
      'rail_stops_layer',
      'transit_stops_layer',
    ], null);
    if (features == null || features.isEmpty) return;

    final stopsAtTap = <String, TransitStop>{};
    for (final feature in features) {
      if (feature is! Map || feature['properties'] is! Map) continue;
      final id = (feature['properties'] as Map)['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final stop = _transitStopsById[id] ?? TransitStop.fromGeoJson(feature);
      if (stop != null) stopsAtTap.putIfAbsent(stop.id, () => stop);
    }
    if (stopsAtTap.isEmpty) return;

    final railStops = stopsAtTap.values
        .where((candidate) => candidate.transitType == 'rail')
        .toList();
    final firstRailStop = railStops.isEmpty ? null : railStops.first;
    var stop = firstRailStop ?? stopsAtTap.values.first;
    if (firstRailStop != null) {
      final normalizedName = firstRailStop.name.trim().toLowerCase();
      final sameStationLines = stopsAtTap.values
          .where(
            (candidate) =>
                candidate.transitType == 'rail' &&
                candidate.name.trim().toLowerCase() == normalizedName,
          )
          .toList();
      if (sameStationLines.length > 1) {
        final selectedStop = await showModalBottomSheet<TransitStop>(
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
                    firstRailStop.name,
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  const Text('Choose the rail line for this station.'),
                  const SizedBox(height: 12),
                  ...sameStationLines.map(
                    (candidate) => ListTile(
                      leading: const Icon(Icons.train),
                      title: Text(candidate.routes),
                      subtitle: Text(candidate.id),
                      onTap: () => Navigator.of(sheetContext).pop(candidate),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        if (selectedStop == null) return;
        stop = selectedStop;
      }
    }

    await _showStopDetails(
      stopId: stop.id,
      stopName: stop.name,
      routes: stop.routes.isEmpty
          ? 'Route information unavailable'
          : stop.routes,
      transitType: stop.transitType,
      stop: stop,
    );
  }

  Future<void> _showStopDetails({
    required String stopId,
    required String stopName,
    required String routes,
    required String transitType,
    TransitStop? stop,
  }) async {
    if (_isStationDetailsOpen || !mounted) return;
    setState(() => _isStationDetailsOpen = true);
    try {
      await showModalBottomSheet<void>(
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
            Navigator.of(context).pop();
            if (stop != null) {
              _getDirectionsToPlace(stop.asPlaceSearchResult());
            }
          },
          fetchDepartures: () => _fetchNextDepartures(stopId),
          fetchCrowd: () => _getStationCrowd(stopId),
          fetchCongestion: () => stop == null
              ? Future<TrafficCongestion?>.value(null)
              : _fetchTrafficCongestion(stopId, stop.lat, stop.lon),
          fetchIncidents: () => _fetchStopIncidents(stopId, stop),
        ),
      );
    } finally {
      if (mounted) setState(() => _isStationDetailsOpen = false);
    }
    return;
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
    _departureCache[stopId] = TimedCache(departures);
    return departures;
  }

  Future<List<StationIncident>> _fetchStopIncidents(
    String stopId,
    TransitStop? stop,
  ) async {
    final response = await _httpClient
        .get(
          Uri.parse('$_backendBaseUrl/api/incidents/recent'),
          headers: await backendHeaders(),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw StateError('Could not load incident reports.');
    }

    final data = jsonDecode(response.body);
    if (data is! Map || data['incidents'] is! List) {
      throw const FormatException('Invalid incident report response.');
    }

    final now = DateTime.now().toUtc();
    final grouped = <String, StationIncident>{};
    for (final raw in data['incidents'] as List) {
      if (raw is! Map) continue;
      final reportedAt = DateTime.tryParse(
        raw['reported_at']?.toString() ?? '',
      );
      if (reportedAt == null ||
          now.difference(reportedAt.toUtc()) > const Duration(minutes: 15)) {
        continue;
      }

      final reportStopId = raw['station_id']?.toString();
      final matchesStopId = reportStopId == stopId;
      final reportLat = (raw['station_lat'] as num?)?.toDouble();
      final reportLon = (raw['station_lon'] as num?)?.toDouble();
      final nearStop =
          stop != null &&
          reportLat != null &&
          reportLon != null &&
          Geolocator.distanceBetween(
                stop.lat,
                stop.lon,
                reportLat,
                reportLon,
              ) <=
              180;
      if (!matchesStopId && !nearStop) continue;

      final type = raw['report_type']?.toString() ?? 'disruption';
      final route = raw['service_route']?.toString();
      final key = '${type.toLowerCase()}|${route?.toLowerCase() ?? ''}';
      final previous = grouped[key];
      grouped[key] = StationIncident(
        type: type,
        route: route,
        count: (previous?.count ?? 0) + 1,
      );
    }
    return grouped.values.toList();
  }

  Future<TrafficCongestion?> _fetchTrafficCongestion(
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
      final congestion = TrafficCongestion.fromJson(
        Map<String, dynamic>.from(data),
      );
      _trafficCache[cacheKey] = TimedCache(congestion);
      return congestion;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadAndRenderOfflineStops(
    MapLibreMapController controller,
  ) async {
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
      final stops = stopFeatures
          .map((feature) => TransitStop.fromGeoJson(feature))
          .whereType<TransitStop>()
          .toList();
      final stopsById = <String, TransitStop>{
        for (final stop in stops) stop.id: stop,
      };
      if (mounted) {
        setState(() {
          _transitStopsById = stopsById;
        });
        final position = _lastKnownPosition;
        if (position != null) _updateNearestTransitStop(position);
      }

      // Prefer the current FastAPI catalogue; bundled stops keep the map useful
      // when the service is unavailable.
      await controller.addSource(
        "offline_stops_source",
        GeojsonSourceProperties(data: geoJson),
      );

      await controller.addCircleLayer(
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
      await controller.addCircleLayer(
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
      await controller.addCircleLayer(
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
      await controller.addCircleLayer(
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

  Future<void> _loadAndRenderStationPerimeters(
    MapLibreMapController controller,
  ) async {
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
      if (features.isEmpty || !identical(controller, _mapController)) return;

      // A map may be recreated after a hot restart, so layers are replaced
      // defensively rather than assuming this method only runs once.
      for (final layer in const [
        'station_perimeter_outline',
        'station_perimeter_fill',
      ]) {
        try {
          await controller.removeLayer(layer);
        } catch (_) {}
      }
      try {
        await controller.removeSource('station_perimeter_source');
      } catch (_) {}
      await controller.addSource(
        'station_perimeter_source',
        GeojsonSourceProperties(
          data: {'type': 'FeatureCollection', 'features': features},
        ),
      );
      await controller.addFillLayer(
        'station_perimeter_source',
        'station_perimeter_fill',
        const FillLayerProperties(fillColor: '#94A3B8', fillOpacity: 0.22),
        minzoom: 14,
      );
      await controller.addLineLayer(
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

  Future<void> _openGrab({ItineraryLeg? leg}) async {
    double? pickupLat = leg?.fromPlace?.lat;
    double? pickupLon = leg?.fromPlace?.lon;
    String? pickupName = leg?.fromPlace?.name;

    double? dropoffLat = leg?.toPlace?.lat;
    double? dropoffLon = leg?.toPlace?.lon;
    String? dropoffName = leg?.toPlace?.name;

    if (pickupLat == null && _lastKnownPosition != null) {
      pickupLat = _lastKnownPosition!.latitude;
      pickupLon = _lastKnownPosition!.longitude;
      pickupName ??= 'Current Location';
    }
    if (dropoffLat == null && _selectedPlace != null) {
      dropoffLat = _selectedPlace!.lat;
      dropoffLon = _selectedPlace!.lon;
      dropoffName ??= _selectedPlace!.name;
    }

    final queryParams = <String, String>{
      'screenType': 'RIDES',
      if (dropoffLat != null) 'dropoff_lat': dropoffLat.toString(),
      if (dropoffLon != null) 'dropoff_lng': dropoffLon.toString(),
      if (dropoffLat != null) 'destination_lat': dropoffLat.toString(),
      if (dropoffLon != null) 'destination_lng': dropoffLon.toString(),
      if (dropoffName != null && dropoffName.isNotEmpty) ...{
        'dropoff_name': dropoffName,
        'destination_name': dropoffName,
        'dropoff[address]': dropoffName,
      },
      if (pickupLat != null) 'pickup_lat': pickupLat.toString(),
      if (pickupLon != null) 'pickup_lng': pickupLon.toString(),
      if (pickupName != null && pickupName.isNotEmpty) ...{
        'pickup_name': pickupName,
        'pickup[address]': pickupName,
      },
    };

    final appUri = Uri(
      scheme: 'grab',
      host: 'open',
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );
    final webUri = Uri.parse(
      'https://r.grab.com/open',
    ).replace(queryParameters: queryParams.isNotEmpty ? queryParams : null);
    final isIos = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final storeUri = Uri.parse(
      isIos
          ? 'https://apps.apple.com/app/grab-taxi-ride-food-delivery/id647268330'
          : 'https://play.google.com/store/apps/details?id=com.grabtaxi.passenger',
    );

    try {
      // 1. Attempt to launch native Grab app
      final opened = await launchUrl(
        appUri,
        mode: LaunchMode.externalApplication,
      );
      if (opened) return;

      // 2. Attempt universal link fallback
      final webOpened = await launchUrl(
        webUri,
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: kIsWeb ? '_blank' : null,
      );
      if (webOpened) return;

      // 3. Fallback to app store / web transport page
      if (kIsWeb) {
        await launchUrl(
          Uri.parse('https://www.grab.com/my/transport/'),
          mode: LaunchMode.externalApplication,
          webOnlyWindowName: '_blank',
        );
      } else {
        await launchUrl(storeUri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      try {
        if (kIsWeb) {
          await launchUrl(
            Uri.parse('https://www.grab.com/my/transport/'),
            mode: LaunchMode.externalApplication,
            webOnlyWindowName: '_blank',
          );
        } else {
          await launchUrl(storeUri, mode: LaunchMode.externalApplication);
        }
      } catch (_) {
        _showMessage('Could not open Grab.');
      }
    }
  }

  Future<void> _openEhailingStore() async {
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    await showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (modalContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Choose E-hailing Service',
                      style: Theme.of(modalContext).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(modalContext).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Connect your route seamlessly with an e-hailing ride:',
                  style: Theme.of(
                    modalContext,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFF00B14F),
                    foregroundColor: Colors.white,
                    child: Icon(Icons.local_taxi),
                  ),
                  title: const Text(
                    'Grab',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Klang Valley’s primary e-hailing ride network',
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    final hailLeg = _currentItinerary?.legs
                        .where((l) => l.mode == 'HAIL')
                        .firstOrNull;
                    await _openGrab(leg: hailLeg);
                  },
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFED1C24),
                    foregroundColor: Colors.white,
                    child: Icon(Icons.directions_car),
                  ),
                  title: const Text(
                    'AirAsia Move (AirAsia Ride)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Affordable e-hailing fares and transfers',
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    final webUri = Uri.parse('https://www.airasia.com/ride/');
                    final storeUri = Uri.parse(
                      isIos
                          ? 'https://apps.apple.com/app/airasia-move/id329124503'
                          : 'https://play.google.com/store/apps/details?id=com.airasia.mobile',
                    );
                    try {
                      if (!await launchUrl(
                        webUri,
                        mode: LaunchMode.externalApplication,
                        webOnlyWindowName: kIsWeb ? '_self' : null,
                      )) {
                        await launchUrl(
                          storeUri,
                          mode: LaunchMode.externalApplication,
                          webOnlyWindowName: kIsWeb ? '_self' : null,
                        );
                      }
                    } catch (_) {
                      await launchUrl(
                        storeUri,
                        mode: LaunchMode.externalApplication,
                        webOnlyWindowName: kIsWeb ? '_self' : null,
                      );
                    }
                  },
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.blueGrey.shade100,
                    foregroundColor: Colors.blueGrey.shade800,
                    child: const Icon(Icons.store),
                  ),
                  title: Text(
                    isIos ? 'Search App Store' : 'Search Google Play',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text('Find more Malaysian e-hailing apps'),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onTap: () async {
                    Navigator.of(modalContext).pop();
                    final storeSearchUri = Uri.parse(
                      isIos
                          ? 'https://apps.apple.com/my/search?term=e-hailing'
                          : 'https://play.google.com/store/search?q=e-hailing%20Malaysia&c=apps',
                    );
                    await launchUrl(
                      storeSearchUri,
                      mode: LaunchMode.externalApplication,
                      webOnlyWindowName: kIsWeb ? '_self' : null,
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNearestStationCard() {
    final stop = _nearestTransitStop;
    final position = _lastKnownPosition;
    final hasLocation = position != null;
    final hasStops = _transitStopsById.isNotEmpty;

    final distance = stop == null || position == null
        ? null
        : Geolocator.distanceBetween(
            position.latitude,
            position.longitude,
            stop.lat,
            stop.lon,
          );
    final distanceLabel = distance == null
        ? null
        : distance < 1000
        ? '${distance.round()} m away'
        : '${(distance / 1000).toStringAsFixed(1)} km away';

    final isBus = stop?.transitType == 'bus';
    final cardTitle = stop == null
        ? 'Nearest transit point'
        : isBus
        ? 'Nearest bus stop'
        : 'Nearest station';

    final crowdFuture = (stop == null || isBus)
        ? null
        : _getStationCrowd(stop.id);

    final colorScheme = Theme.of(context).colorScheme;
    final isCompact = MediaQuery.sizeOf(context).width < 400;

    final IconData leadingIcon;
    final Widget subtitleWidget;
    final Widget? trailingWidget;
    final VoidCallback? onTapAction;

    if (!hasLocation) {
      leadingIcon = Icons.location_off_outlined;
      subtitleWidget = Text(
        'Location unavailable • Tap to enable',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCompact ? Theme.of(context).textTheme.bodySmall : null,
      );
      trailingWidget = TextButton(
        onPressed: _startLocationTracking,
        child: const Text('Enable'),
      );
      onTapAction = _startLocationTracking;
    } else if (!hasStops) {
      leadingIcon = Icons.near_me_outlined;
      subtitleWidget = Text(
        'Loading nearby transit data…',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCompact ? Theme.of(context).textTheme.bodySmall : null,
      );
      trailingWidget = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
      onTapAction = null;
    } else if (stop == null) {
      leadingIcon = Icons.location_searching;
      subtitleWidget = Text(
        'No nearby stations or stops found',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCompact ? Theme.of(context).textTheme.bodySmall : null,
      );
      trailingWidget = null;
      onTapAction = null;
    } else {
      leadingIcon = isBus ? Icons.directions_bus : Icons.train;
      onTapAction = _focusNearestTransitStop;
      trailingWidget = distanceLabel != null
          ? TextButton(
              onPressed: _focusNearestTransitStop,
              child: Text(distanceLabel),
            )
          : null;

      if (isBus) {
        final serviceInfo = stop.routes.isNotEmpty
            ? 'Routes: ${stop.routes}'
            : 'Bus service';
        subtitleWidget = Text(
          '${stop.name} • $serviceInfo',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: isCompact ? Theme.of(context).textTheme.bodySmall : null,
        );
      } else {
        subtitleWidget = FutureBuilder<StationCrowd>(
          future: crowdFuture,
          builder: (context, snapshot) {
            final crowd = snapshot.data;
            final info = crowd == null
                ? (stop.routes.isNotEmpty ? stop.routes : 'Low crowd level')
                : crowd.summaryLabel;
            return Text(
              '${stop.name} • $info',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: isCompact ? Theme.of(context).textTheme.bodySmall : null,
            );
          },
        );
      }
    }

    return Material(
      color: colorScheme.surfaceContainerLow,
      child: InkWell(
        onTap: onTapAction,
        child: Padding(
          padding: EdgeInsets.all(isCompact ? 8 : 10),
          child: Row(
            children: [
              CircleAvatar(
                radius: isCompact ? 18 : 20,
                backgroundColor: colorScheme.secondaryContainer,
                foregroundColor: colorScheme.onSecondaryContainer,
                child: Icon(leadingIcon, size: isCompact ? 20 : 24),
              ),
              SizedBox(width: isCompact ? 8 : 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      cardTitle,
                      style: isCompact
                          ? Theme.of(context).textTheme.titleSmall
                          : Theme.of(context).textTheme.titleMedium,
                    ),
                    subtitleWidget,
                  ],
                ),
              ),
              if (trailingWidget != null) ...[
                const SizedBox(width: 8),
                trailingWidget,
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapTopPanel() {
    final isCompact = MediaQuery.sizeOf(context).width < 400;
    final hasSearchContent =
        _isSearchOpen &&
        (_placeSearchResults.isNotEmpty || _selectedPlace != null);

    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 4,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasSearchContent && _placeSearchResults.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _placeSearchResults.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final place = _placeSearchResults[index];
                  return ListTile(
                    dense: isCompact,
                    visualDensity: isCompact ? VisualDensity.compact : null,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
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
          if (hasSearchContent && _selectedPlace != null) ...[
            Container(
              width: double.infinity,
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: isCompact ? 18 : 20,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    foregroundColor: Theme.of(
                      context,
                    ).colorScheme.onPrimaryContainer,
                    child: Icon(Icons.place, size: isCompact ? 20 : 24),
                  ),
                  SizedBox(width: isCompact ? 8 : 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedPlace!.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          _selectedPlace!.address,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _getDirectionsToSelectedPlace,
                    style: isCompact
                        ? FilledButton.styleFrom(
                            minimumSize: const Size(48, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            visualDensity: VisualDensity.compact,
                          )
                        : null,
                    icon: const Icon(Icons.directions, size: 18),
                    label: const Text('Go'),
                  ),
                ],
              ),
            ),
          ],
          if (_placeSearchResults.isNotEmpty) ...[
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Search results © OpenStreetMap contributors',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ),
          ],
          if (_currentItinerary == null) ...[
            if (hasSearchContent) const Divider(height: 1),
            _buildNearestStationCard(),
          ],
        ],
      ),
    );
  }

  Future<StationCrowd> _fetchStationCrowd(String stationId) async {
    final response = await _httpClient
        .get(
          Uri.parse(
            '$_backendBaseUrl/api/stations/${Uri.encodeComponent(stationId)}/crowd',
          ),
          headers: await backendHeaders(),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw StateError('Could not load crowd level');
    }
    final data = jsonDecode(response.body);
    if (data is! Map) throw const FormatException('Invalid crowd response');
    return StationCrowd.fromJson(Map<String, dynamic>.from(data));
  }

  Future<StationCrowd> _getStationCrowd(String stationId) {
    final cached = _stationCrowdCache[stationId];
    if (cached != null &&
        DateTime.now().difference(cached.loadedAt) <
            const Duration(minutes: 1)) {
      return cached.value;
    }

    // Keep the in-flight request as well as its result. The map style reloads
    // and camera updates can rebuild this card several times in quick
    // succession; each build should not issue a duplicate crowd request.
    final request = _fetchStationCrowd(stationId);
    _stationCrowdCache[stationId] = TimedCache(request);
    return request;
  }

  @override
  Widget build(BuildContext context) {
    if (_isOutsideSupportedZone) {
      return const Scaffold(body: UnsupportedZoneScreen());
    }
    final isMapTab = _selectedTab == 0;
    final itineraryIsOpen = _selectedTab == 0 && _currentItinerary != null;
    final mapStyleVersion = _mapStyleVersion;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    return PopScope(
      canPop: !itineraryIsOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && itineraryIsOpen) _dismissItinerary();
      },
      child: Scaffold(
        // Keep the itinerary viewport below the search bar so its top rows
        // remain visible and scrollable on small screens.
        extendBodyBehindAppBar: isMapTab && !itineraryIsOpen,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          toolbarHeight: isMapTab ? 64 : null,
          leadingWidth: isMapTab
              ? viewportWidth < 360
                    ? 128
                    : viewportWidth < 400
                    ? 136
                    : 148
              : null,
          leading: isMapTab
              ? Padding(
                  padding: const EdgeInsets.only(left: 12, top: 10, bottom: 10),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _currentRegion,
                          isExpanded: true,
                          dropdownColor: Theme.of(context).colorScheme.surface,
                          icon: Icon(
                            Icons.expand_more,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                          items: [
                            DropdownMenuItem(
                              value: _currentRegion,
                              child: Text(
                                _currentRegion,
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurface,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          onChanged: (_) {},
                        ),
                      ),
                    ),
                  ),
                )
              : null,
          title: isMapTab
              ? Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 10),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: TextField(
                      key: const ValueKey('place-search-field'),
                      controller: _placeSearchController,
                      focusNode: _placeSearchFocusNode,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _searchPlaces(),
                      onChanged: _onPlaceSearchChanged,
                      decoration: InputDecoration(
                        hintText: 'Search for a location',
                        hintStyle: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                )
              : Text(isMapTab ? 'JomNaik' : 'Profile'),
          actions: const [],
          backgroundColor: isMapTab ? Colors.transparent : null,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: Stack(
          children: [
            IndexedStack(
              index: _selectedTab,
          children: [
            _dynamicStyleString == null
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      IgnorePointer(
                        // A modal station sheet or route choices sheet can
                        // leave the native/web map view in the gesture arena.
                        // IgnorePointer blocks that map view until the sheet is gone.
                        ignoring:
                            _isStationDetailsOpen || _isRouteChoicesOpen,
                        child: MapLibreMap(
                          key: ValueKey('map_style_$_mapStyleVersion'),
                          initialCameraPosition: const CameraPosition(
                            target: LatLng(3.1390, 101.6868),
                            zoom: 12,
                          ),
                          // Weather is keyed to the visible map centre.
                          trackCameraPosition: true,
                          scrollGesturesEnabled:
                              !_isScrollingCard &&
                              !_isCardExpanded &&
                              !_isStationDetailsOpen &&
                              !_isRouteChoicesOpen,
                          zoomGesturesEnabled:
                              !_isScrollingCard &&
                              !_isCardExpanded &&
                              !_isStationDetailsOpen &&
                              !_isRouteChoicesOpen,
                          rotateGesturesEnabled:
                              !_isScrollingCard &&
                              !_isCardExpanded &&
                              !_isStationDetailsOpen &&
                              !_isRouteChoicesOpen,
                          tiltGesturesEnabled:
                              !_isScrollingCard &&
                              !_isCardExpanded &&
                              !_isStationDetailsOpen &&
                              !_isRouteChoicesOpen,
                          doubleClickZoomEnabled:
                              !_isScrollingCard &&
                              !_isCardExpanded &&
                              !_isStationDetailsOpen &&
                              !_isRouteChoicesOpen,
                          onMapCreated: (controller) =>
                              _onMapCreated(controller, mapStyleVersion),
                          onStyleLoadedCallback: () =>
                              _onMapStyleLoaded(mapStyleVersion),
                          onMapClick: (point, coordinate) =>
                              _handleMapStartPick(point, coordinate),
                          featureTapsTriggersMapClick: false,
                          onMapLongClick: (point, coordinate) =>
                              _showLongPressedLocation(point, coordinate),
                          onCameraMove: _onCameraMove,
                          onCameraIdle: _onCameraIdle,
                          styleString: _dynamicStyleString!,
                          compassEnabled: false,
                          compassViewPosition: kIsWeb
                              ? CompassViewPosition.topRight
                              : CompassViewPosition.bottomRight,
                          compassViewMargins: kIsWeb
                              ? null
                              : const Point(16, 160),
                        ),
                      ),
                      if (_isCardExpanded)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {},
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              color: Colors.black.withValues(alpha: 0.54),
                            ),
                          ),
                        ),
                      if (_currentItinerary == null)
                        Positioned(
                          top: 66,
                          left: 16,
                          right: 16,
                          child: NotificationListener<ScrollNotification>(
                            onNotification: (notification) {
                              if (notification is ScrollStartNotification ||
                                  notification is UserScrollNotification) {
                                _setScrollingCard(true);
                              } else if (notification
                                  is ScrollEndNotification) {
                                _setScrollingCard(false);
                              }
                              return false;
                            },
                            child: Listener(
                              behavior: HitTestBehavior.opaque,
                              onPointerDown: (_) {
                                _beginOverlayInteraction();
                                _setScrollingCard(true);
                              },
                              onPointerUp: (_) {
                                _endOverlayInteraction();
                                _setScrollingCard(false);
                              },
                              onPointerCancel: (_) {
                                _endOverlayInteraction();
                                _setScrollingCard(false);
                              },
                              onPointerSignal: (event) {
                                if (event is PointerScrollEvent) {
                                  _setScrollingCard(true);
                                }
                              },
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                // Claim taps on the floating search/station panel
                                // so they cannot fall through to MapLibre beneath it.
                                onTap: () {},
                                child: _buildMapTopPanel(),
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
                        ItinerarySheet(
                          itinerary: _currentItinerary!,
                          initialExtent: _itineraryInitialExtent,
                          weatherReminder: _weatherItineraryReminder(
                            _currentItinerary!,
                          ),
                          guidanceCard: _buildJourneyGuidanceCard(),
                          onDismiss: _dismissItinerary,
                          onFindApps: _openEhailingStore,
                          onOpenGrab: (leg) => _openGrab(leg: leg),
                          onUserInteracted: _markItineraryUserInteracted,
                          onCardInteractionChanged: _setScrollingCard,
                          onExpandedChanged: (expanded) {
                            if (_isCardExpanded != expanded) {
                              setState(() => _isCardExpanded = expanded);
                            }
                          },
                        ),
                    ],
                  ),
            ColoredBox(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF242424)
                  : Theme.of(context).scaffoldBackgroundColor,
              child: ProfilePage(
                isSupabaseConfigured: _isSupabaseConfigured,
                onStationLocationTrackingChanged:
                    _setStationLocationTrackingEnabled,
              ),
            ),
          ],
        ),
        if (_isSearchingRoute)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.55),
              child: Center(
                child: Card(
                  elevation: 8,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 26,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 44,
                          height: 44,
                          child: CircularProgressIndicator(strokeWidth: 3.5),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Searching routes...',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Finding the best options for your journey',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
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
                  Material(
                    color: Theme.of(context).colorScheme.surface,
                    elevation: 3,
                    shape: CircleBorder(
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: PopupMenuButton<_MapLayerAction>(
                      tooltip: 'Map layers',
                      icon: const Icon(Icons.layers_outlined),
                      onSelected: (action) {
                        switch (action) {
                          case _MapLayerAction.satellite:
                            _toggleSatellite();
                            break;
                          case _MapLayerAction.toggleTheme:
                            _toggleTheme();
                            break;
                        }
                      },
                      itemBuilder: (context) {
                        final isDark =
                            Theme.of(context).brightness == Brightness.dark;
                        return [
                          PopupMenuItem(
                            value: _MapLayerAction.satellite,
                            child: Row(
                              children: [
                                const Icon(Icons.satellite_alt_outlined),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Text('Satellite imagery'),
                                ),
                                if (_isSatelliteMode)
                                  const Icon(Icons.check, size: 18),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: _MapLayerAction.toggleTheme,
                            child: Row(
                              children: [
                                Icon(
                                  isDark
                                      ? Icons.light_mode_outlined
                                      : Icons.dark_mode_outlined,
                                ),
                                const SizedBox(width: 12),
                                Text(isDark ? 'Light mode' : 'Dark mode'),
                              ],
                            ),
                          ),
                        ];
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'show-north',
                    onPressed: _mapController == null ? null : _showNorth,
                    tooltip: 'Show north',
                    child: const Icon(Icons.navigation),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'show-location',
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
