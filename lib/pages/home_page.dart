import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart' as gnav;
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:first/services/flood_route_service.dart';

import 'emergency_page.dart';
import 'incident_report_page.dart';
import 'alerts_page.dart';
import 'user_navigation_page.dart';
import 'profile_page.dart';
import 'rescuer_historical_logs_page.dart';
import 'rescuer_navigation_page.dart';
import 'rescuer_rescue_center_page.dart';
import 'rescuer_sensor_network_page.dart';
import 'widgets/home_tab_widgets.dart';

part 'home_page_map_layers.dart';
part 'home_page_route_service.dart';
part 'home_page_hazard_widgets.dart';

class HomePage extends StatefulWidget {
  final bool isRescuerAccount;

  const HomePage({super.key, this.isRescuerAccount = false});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  static const MethodChannel _appControlChannel = MethodChannel(
    'floote/app_control',
  );
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  gnav.GoogleMapViewController? _androidMapController;
  gnav.ImageDescriptor? _androidBluePinDescriptor;

  static const Color _accentColor = Color(0xFF00E4FF);
  static const Color _dangerColor = Color(0xFFFF4C4C);
  static const Color _panelColor = Color(0xFF111A24);
  /// Light basemap used as the `flutter_map` fallback (non-Android / Nav SDK init failure).
  /// Kept light to match the Navigation SDK's `MapColorScheme.light` and avoid the
  /// dark CartoDB `dark_all` tiles that previously bled through on the Map tab.
  static const String _darkTileUrl =
      'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';

  /// Fallback camera / search bias before first GPS fix (Google Map needs a valid point).
  /// Approximate center of Metro Cebu (not a single campus)—tweak zoom in code for island-wide views.
  static const LatLng _cebuLocation = LatLng(10.2926, 123.9022);

  /// Wider zoom when showing [_cebuLocation] before any GPS fix (Metro Cebu context).
  static const double _cebuFallbackZoom = 11.0;

  /// Live GPS for position and map; set [true] only to pin the map to [_cebuLocation] (e.g. emulator).
  static const bool _useFixedCurrentLocation = false;

  LatLng _mapCenter = _cebuLocation;
  double _mapZoom = 15.0;

  late final AnimationController _pulseController;
  late final AnimationController _sosController;
  bool _isAutoCentering = false;
  bool _isRerouting = false;
  bool _pathIsBlocked = false;
  bool _isFloodWarningAhead = false;
  bool _isActiveDuty = false;
  /// Bumps on each duty persist so late async loads cannot overwrite the switch after user action.
  int _dutySyncGeneration = 0;
  bool _isMapReady = false;
  bool _androidNavMapReady = false;
  String? _androidNavMapError;
  Timer? _rescuerPresenceTimer;

  /// First bottom-nav item: Dashboard (rescuer) or Map (regular user).
  int _bottomNavIndex = 0;

  /// After accepting an SOS from Rescue Center: show bottom "Start" on map (UI only for now).
  bool _showRescuerNavStartBar = false;
  bool _showUserNavStartBar = false;
  String? _activeRescueDispatchId;
  String? _activeRescueTicketNumber;
  LatLng? _activeRescueDestination;
  List<Map<String, dynamic>> _cachedVerifiedReports = const [];
  String _androidOverlayDigest = '';
  final Map<String, Map<String, dynamic>> _androidHazardReportByMarkerId = {};

  LatLng? _currentPCPos;
  double _currentHeading = 0.0;

  List<LatLng> _routePoints = [];
  LatLng? _destinationPos;

  static const String _mapboxToken = String.fromEnvironment(
    'MAPBOX_TOKEN',
    defaultValue: '',
  );
  static const String _googlePlacesApiKey = String.fromEnvironment(
    'GOOGLE_PLACES_API_KEY',
    defaultValue: '',
  );
  static const bool _allowLegacySearchFallback = bool.fromEnvironment(
    'ALLOW_LEGACY_GEOCODER_FALLBACK',
    defaultValue: false,
  );
  /// Default to the Navigation SDK map layer on Android so the Map tab matches
  /// the other map screens. Override at build time with
  /// `--dart-define=USE_ANDROID_NAV_MAP_LAYER=false` to fall back to `flutter_map`.
  static const bool _useAndroidNavigationMapLayer = bool.fromEnvironment(
    'USE_ANDROID_NAV_MAP_LAYER',
    defaultValue: true,
  );
  bool get _useMapbox =>
      _mapboxToken.startsWith('pk.') && _mapboxToken.isNotEmpty;
  bool get _useGooglePlaces => _googlePlacesApiKey.isNotEmpty;
  bool get _useNavigationMapLayer =>
      _useAndroidNavigationMapLayer &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _sosController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    unawaited(_prepareAndroidNavigationMapLayer());
    _fastTrackLocation();
    if (widget.isRescuerAccount) {
      unawaited(_loadRescuerDutyFromProfile().then((_) {
        if (_isActiveDuty) {
          unawaited(_pushRescuerLocationToProfile());
        }
        _startRescuerPresenceTimer();
      }));
    }
  }

  Future<void> _prepareAndroidNavigationMapLayer() async {
    if (!_useNavigationMapLayer) return;
    try {
      final accepted = await gnav.GoogleMapsNavigator.areTermsAccepted();
      if (!accepted) {
        await gnav.GoogleMapsNavigator.showTermsAndConditionsDialog(
          'Floote Navigation',
          'Floote',
        );
      }
      final initialized = await gnav.GoogleMapsNavigator.isInitialized();
      if (!initialized) {
        await gnav.GoogleMapsNavigator.initializeNavigationSession(
          taskRemovedBehavior: gnav.TaskRemovedBehavior.continueService,
        );
      }
      if (!mounted) return;
      setState(() {
        _androidNavMapReady = true;
        _androidNavMapError = null;
        _isMapReady = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _androidNavMapReady = false;
        _androidNavMapError = 'Navigation map failed to load: $e';
      });
    }
  }

  Future<void> _loadRescuerDutyFromProfile() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    final generationAtStart = _dutySyncGeneration;
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('is_on_duty')
          .eq('id', uid)
          .maybeSingle();
      if (!mounted || generationAtStart != _dutySyncGeneration) return;
      final parsed = _dutyBoolFromRaw(row?['is_on_duty']);
      if (parsed != null) {
        setState(() => _isActiveDuty = parsed);
      }
    } catch (e) {
      debugPrint('load rescuer duty: $e');
    }
  }

  void _startRescuerPresenceTimer() {
    _rescuerPresenceTimer?.cancel();
    _rescuerPresenceTimer =
        Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted || !widget.isRescuerAccount || !_isActiveDuty) return;
      unawaited(_pushRescuerLocationToProfile());
    });
  }

  static const String _dutySaveFailedUserMessage =
      'Could not save duty. Please try again.';
  static const String _dutySessionUserMessage =
      'Please sign in again, then try once more.';

  void _showDutySnackBar(String message, {bool isError = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? _dangerColor : null,
      ),
    );
  }

  /// [profiles.is_on_duty] may arrive as bool, string, or int depending on client/Postgres.
  bool? _dutyBoolFromRaw(dynamic raw) {
    if (raw == null) return null;
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      final t = raw.toLowerCase().trim();
      if (t == 'true' || t == 't' || t == '1' || t == 'yes') return true;
      if (t == 'false' || t == 'f' || t == '0' || t == 'no') return false;
    }
    return null;
  }

  /// PostgREST RPC scalars are usually a bare JSON value; unwrap single-element lists defensively.
  dynamic _unwrapRpcScalar(dynamic raw) {
    if (raw is List && raw.length == 1) return raw[0];
    return raw;
  }

  bool _dutyBoolMatches(dynamic raw, bool expected) {
    final v = _dutyBoolFromRaw(_unwrapRpcScalar(raw));
    if (v == null) return false;
    return v == expected;
  }

  Future<void> _persistDutyToggle(bool value) async {
    _dutySyncGeneration++;
    final generationAtWrite = _dutySyncGeneration;
    final previous = _isActiveDuty;
    setState(() => _isActiveDuty = value);

    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      if (mounted && generationAtWrite == _dutySyncGeneration) {
        setState(() => _isActiveDuty = previous);
        _showDutySnackBar(_dutySessionUserMessage);
      }
      return;
    }

    try {
      try {
        await Supabase.instance.client.auth.refreshSession();
      } catch (e) {
        debugPrint('duty persist: refreshSession skipped: $e');
      }

      // Prefer SECURITY DEFINER RPC so duty persists even when direct UPDATE is blocked by RLS.
      // Deploy: supabase/sql/set_rescuer_on_duty_rpc.sql
      final rpcResult = await Supabase.instance.client.rpc(
        'set_rescuer_on_duty',
        params: {'p_on_duty': value},
      );

      if (!mounted || generationAtWrite != _dutySyncGeneration) return;

      final persisted = _dutyBoolMatches(rpcResult, value);
      if (!persisted) {
        setState(() => _isActiveDuty = previous);
        debugPrint(
          'duty persist: RPC unexpected value (expected $value got $rpcResult)',
        );
        _showDutySnackBar(_dutySaveFailedUserMessage);
        return;
      }

      if (value) {
        _startRescuerPresenceTimer();
        await _pushRescuerLocationToProfile();
      } else {
        _rescuerPresenceTimer?.cancel();
      }
    } catch (e, st) {
      debugPrint('duty persist: $e\n$st');
      if (!mounted || generationAtWrite != _dutySyncGeneration) return;
      setState(() => _isActiveDuty = previous);
      _showDutySnackBar(_dutySaveFailedUserMessage);
    }
  }

  Future<void> _pushRescuerLocationToProfile() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null || !widget.isRescuerAccount || !_isActiveDuty) return;
    try {
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        );
      } catch (e) {
        debugPrint('rescuer location push: getCurrentPosition: $e');
      }
      pos ??= await Geolocator.getLastKnownPosition();
      // DB location is always from the device (current or last-known GPS), never a map placeholder.
      if (pos == null) {
        debugPrint('rescuer location push: no position (GPS off or denied?)');
        return;
      }
      if (!mounted) return;
      try {
        await Supabase.instance.client.auth.refreshSession();
      } catch (e) {
        debugPrint('rescuer location push: refreshSession skipped: $e');
      }
      await Supabase.instance.client.rpc(
        'set_rescuer_last_location',
        params: {
          'p_latitude': pos.latitude,
          'p_longitude': pos.longitude,
        },
      );
    } catch (e, st) {
      debugPrint('rescuer location push: $e\n$st');
    }
  }

  @override
  void dispose() {
    _rescuerPresenceTimer?.cancel();
    final descriptor = _androidBluePinDescriptor;
    if (descriptor != null) {
      unawaited(gnav.unregisterImage(descriptor));
    }
    _pulseController.dispose();
    _sosController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  List<Map<String, dynamic>> _normalizeVerifiedReports(
    List<Map<String, dynamic>> allReports,
  ) {
    final normalized = <Map<String, dynamic>>[];
    for (final r in allReports) {
      final decision = (r['admin_decision'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (decision != 'impassable' && decision != 'risky') continue;
      final lat = _toDouble(r['latitude']);
      final lng = _toDouble(r['longitude']);
      if (lat == null || lng == null) continue;

      normalized.add({...r, 'latitude': lat, 'longitude': lng});
    }
    return normalized;
  }

  // --- 1. DETECT IF CURRENT PATH HAS HAZARDS ---
  void _checkRouteForFloods(List<Map<String, dynamic>> reports) {
    if (_routePoints.isEmpty || _destinationPos == null || _isRerouting) return;

    const Distance distance = Distance();
    bool hazardFound = false;
    bool warningFound = false;

    for (var point in _routePoints) {
      for (var report in reports) {
        final decision = (report['admin_decision'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        final d = distance.as(
          LengthUnit.Meter,
          point,
          LatLng(report['latitude'], report['longitude']),
        );

        if (decision == 'impassable' && d < 150) {
          hazardFound = true;
          break;
        }

        if (decision == 'risky' && d < 80) {
          warningFound = true;
        }
      }
      if (hazardFound) break;
    }

    if (hazardFound != _pathIsBlocked || warningFound != _isFloodWarningAhead) {
      setState(() {
        _pathIsBlocked = hazardFound;
        _isFloodWarningAhead = warningFound;
      });
    }
  }

  // --- 2. IMMEDIATE STANDARD ROUTE (OSRM) ---
  Future<void> _getInitialRoute(LatLng destination) async {
    if (_currentPCPos == null) return;
    try {
      final initialRoute = await _HomePageRouteService.shapeDirectRoadRoute(
        this,
        _currentPCPos!,
        destination,
        const [],
      );
      if (initialRoute.length >= 2) {
        setState(() {
          _routePoints = initialRoute;
          _pathIsBlocked = false;
        });

        if (_routePoints.isNotEmpty) {
          _fitMapToPoints(_routePoints);
        }
      }
    } catch (e) {
      debugPrint("Standard Routing Error: $e");
    }
  }

  // --- 3. FASTAPI FLOOD-AWARE REROUTE ---
  Future<void> _getSafeAStarRoute(
    List<Map<String, dynamic>> verifiedReports,
  ) async {
    return _HomePageRouteService.getSafeAStarRoute(this, verifiedReports);
  }

  void _clearRoute() {
    setState(() {
      _routePoints = [];
      _destinationPos = null;
      _pathIsBlocked = false;
      _isFloodWarningAhead = false;
      _isRerouting = false;
      _showUserNavStartBar = false;
      _showRescuerNavStartBar = false;
      _searchController.clear();
      _isAutoCentering = true;
    });
    if (_currentPCPos != null) _animatedMapMove(_currentPCPos!, 15.0);
  }

  void _setReroutingState(bool value) {
    if (!mounted) return;
    setState(() => _isRerouting = value);
  }

  void _applyRerouteSuccess(List<LatLng> points) {
    if (!mounted) return;
    setState(() {
      _routePoints = points;
      _isRerouting = false;
      _pathIsBlocked = false;
      _isFloodWarningAhead = false;
      if (!widget.isRescuerAccount && _destinationPos != null) {
        _showUserNavStartBar = true;
      }
    });
    _fitMapToPoints(_routePoints);
  }

  void _showRerouteFailure(String message, {required bool connected}) {
    if (!mounted) return;
    setState(() {
      _isRerouting = false;
      // Keep Start visible so users can still begin guidance on the
      // latest available route, even if no alternate reroute was found.
      if (widget.isRescuerAccount) {
        _showRescuerNavStartBar = _destinationPos != null;
      } else {
        _showUserNavStartBar = _destinationPos != null;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          connected
              ? "$message Tried wider detour but no valid safe route."
              : message,
        ),
        backgroundColor: Colors.red,
      ),
    );
  }

  List<Polyline> _buildMapPolylines() {
    if (_routePoints.length < 2) return const <Polyline>[];
    return [
      Polyline(
        points: _routePoints,
        color: _pathIsBlocked ? _dangerColor.withAlpha(180) : _accentColor,
        strokeWidth: _pathIsBlocked ? 7 : 6,
      ),
    ];
  }

  List<CircleMarker> _buildHazardCircles(List<Map<String, dynamic>> reports) {
    final circles = <CircleMarker>[];
    for (final report in reports) {
      final decision = (report['admin_decision'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (decision != 'impassable' && decision != 'risky') continue;
      final lat = _toDouble(report['latitude']);
      final lng = _toDouble(report['longitude']);
      if (lat == null || lng == null) continue;
      final isImpassable = decision == 'impassable';
      final radius = isImpassable ? 150.0 : 80.0;
      final stroke = isImpassable
          ? _dangerColor.withAlpha(220)
          : Colors.orangeAccent.withAlpha(220);
      circles.add(
        CircleMarker(
          point: LatLng(lat, lng),
          radius: radius,
          useRadiusInMeter: true,
          borderColor: stroke,
          borderStrokeWidth: 2,
          color: stroke.withAlpha(50),
        ),
      );
    }
    return circles;
  }

  Color _markerColorForDecision(String? decision) {
    final value = (decision ?? '').trim().toLowerCase();
    if (value == 'impassable') return Colors.redAccent;
    if (value == 'risky') return Colors.orangeAccent;
    return Colors.lightBlueAccent;
  }

  List<Marker> _buildMapMarkers(List<Map<String, dynamic>> reports) {
    final markers = <Marker>[];
    for (final r in reports) {
      final lat = _toDouble(r['latitude']);
      final lng = _toDouble(r['longitude']);
      if (lat == null || lng == null) continue;
      markers.add(
        Marker(
          point: LatLng(lat, lng),
          width: 38,
          height: 38,
          child: GestureDetector(
            onTap: () => _showReportDetails(r),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _markerColorForDecision(r['admin_decision']?.toString()),
                border: Border.all(color: Colors.white, width: 1.8),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
            ),
          ),
        ),
      );
    }

    if (_destinationPos != null) {
      markers.add(
        Marker(
          point: _destinationPos!,
          width: 40,
          height: 40,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF1E88E5),
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(Icons.flag, color: Colors.white, size: 20),
          ),
        ),
      );
    }

    if (_currentPCPos != null) {
      markers.add(
        Marker(
          point: _currentPCPos!,
          width: 44,
          height: 44,
          child: Transform.rotate(
            angle: _currentHeading * 3.1415926535897932 / 180.0,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF00B8FF),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 10,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(Icons.navigation, color: Colors.white, size: 24),
            ),
          ),
        ),
      );
    }

    return markers;
  }

  Widget _buildMap(List<Map<String, dynamic>> displayReports) {
    if (_useNavigationMapLayer) {
      return _buildAndroidNavigationMap(displayReports);
    }
    final initial = _currentPCPos ?? _cebuLocation;
    final initialZoom =
        _currentPCPos == null ? _cebuFallbackZoom : _mapZoom;
    _isMapReady = true;
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: initial,
        initialZoom: initialZoom,
        onPositionChanged: (position, hasGesture) {
          _mapCenter = position.center;
          _mapZoom = position.zoom;
        },
      ),
      children: [
        TileLayer(
          urlTemplate: _darkTileUrl,
          subdomains: const ['a', 'b', 'c', 'd'],
          userAgentPackageName: 'com.example.first',
        ),
        CircleLayer(circles: _buildHazardCircles(displayReports)),
        PolylineLayer(polylines: _buildMapPolylines()),
        MarkerLayer(markers: _buildMapMarkers(displayReports)),
      ],
    );
  }

  Widget _buildAndroidNavigationMap(List<Map<String, dynamic>> displayReports) {
    final initial = _currentPCPos ?? _cebuLocation;
    final initialZoom =
        _currentPCPos == null ? _cebuFallbackZoom : _mapZoom;
    if (!_androidNavMapReady) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: _accentColor),
              const SizedBox(height: 12),
              Text(
                _androidNavMapError ?? 'Preparing Navigation SDK map layer...',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      );
    }
    _isMapReady = true;
    final digest = _buildAndroidOverlayDigest(displayReports);
    if (digest != _androidOverlayDigest) {
      _androidOverlayDigest = digest;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_syncAndroidNavigationMapOverlays(displayReports));
      });
    }
    return Stack(
      children: [
        gnav.GoogleMapsMapView(
          onViewCreated: (controller) {
            _androidMapController = controller;
            _androidOverlayDigest = '';
            unawaited(_syncAndroidNavigationMapOverlays(displayReports));
            unawaited(() async {
              try {
                await controller.setMyLocationEnabled(true);
                await controller.setMapType(mapType: gnav.MapType.normal);
                await controller.setMapColorScheme(gnav.MapColorScheme.light);
                await controller.setMapStyle('[]');
                await Future<void>.delayed(const Duration(milliseconds: 700));
                await controller.setMapType(mapType: gnav.MapType.normal);
                await controller.setMapColorScheme(gnav.MapColorScheme.light);
                await controller.setMapStyle('[]');
              } catch (e) {
                debugPrint('home map style apply failed: $e');
              }
            }());
          },
          onCameraMove: (position) {
            _mapCenter = LatLng(
              position.target.latitude,
              position.target.longitude,
            );
            _mapZoom = position.zoom;
          },
          onCameraIdle: (position) {
            _mapCenter = LatLng(
              position.target.latitude,
              position.target.longitude,
            );
            _mapZoom = position.zoom;
          },
          onMarkerClicked: _handleAndroidMapMarkerClicked,
          initialMapType: gnav.MapType.normal,
          initialMapColorScheme: gnav.MapColorScheme.light,
          initialCameraPosition: gnav.CameraPosition(
            target: gnav.LatLng(
              latitude: initial.latitude,
              longitude: initial.longitude,
            ),
            zoom: initialZoom,
          ),
        ),
        Positioned(
          right: 14,
          bottom: 14,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xC6111A24),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text(
                'Reports: ${displayReports.length}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _fitMapToPoints(List<LatLng> points) async {
    if (!_isMapReady || points.isEmpty) return;
    if (points.length == 1) {
      _safeMapMove(points.first, 17.0);
      return;
    }

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final point in points) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    final center = LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
    final latSpan = (maxLat - minLat).abs().clamp(0.0001, 180.0);
    final zoom = latSpan > 1.5
        ? 9.5
        : latSpan > 0.8
            ? 10.5
            : latSpan > 0.4
                ? 11.5
                : latSpan > 0.2
                    ? 12.5
                    : latSpan > 0.1
                        ? 13.5
                        : latSpan > 0.05
                            ? 14.5
                            : latSpan > 0.02
                                ? 15.5
                                : 16.4;
    _safeMapMove(center, zoom);
  }

  String _buildAndroidOverlayDigest(List<Map<String, dynamic>> reports) {
    final b = StringBuffer()
      ..write('r=')
      ..write(reports.length)
      ..write('|p=')
      ..write(_routePoints.length)
      ..write('|d=')
      ..write(_destinationPos?.latitude.toStringAsFixed(5) ?? '-')
      ..write(',')
      ..write(_destinationPos?.longitude.toStringAsFixed(5) ?? '-')
      ..write('|c=')
      ..write(_currentPCPos?.latitude.toStringAsFixed(5) ?? '-')
      ..write(',')
      ..write(_currentPCPos?.longitude.toStringAsFixed(5) ?? '-')
      ..write('|h=')
      ..write(_currentHeading.toStringAsFixed(1));
    for (final report in reports) {
      final lat = _toDouble(report['latitude']);
      final lng = _toDouble(report['longitude']);
      final decision = (report['admin_decision'] ?? '').toString();
      b
        ..write('|')
        ..write(report['id'] ?? '')
        ..write(':')
        ..write(lat?.toStringAsFixed(5) ?? '-')
        ..write(',')
        ..write(lng?.toStringAsFixed(5) ?? '-')
        ..write(':')
        ..write(decision);
    }
    if (_routePoints.isNotEmpty) {
      final first = _routePoints.first;
      final last = _routePoints.last;
      b
        ..write('|rf=')
        ..write(first.latitude.toStringAsFixed(5))
        ..write(',')
        ..write(first.longitude.toStringAsFixed(5))
        ..write('|rl=')
        ..write(last.latitude.toStringAsFixed(5))
        ..write(',')
        ..write(last.longitude.toStringAsFixed(5));
    }
    return b.toString();
  }

  Future<void> _syncAndroidNavigationMapOverlays(
    List<Map<String, dynamic>> reports,
  ) async {
    if (!_useNavigationMapLayer || !_androidNavMapReady) return;
    final controller = _androidMapController;
    if (controller == null) return;
    try {
      final bluePin = await _ensureAndroidBluePinDescriptor();
      await controller.clear();
      _androidHazardReportByMarkerId.clear();

      final hazardMarkerOptions = <gnav.MarkerOptions>[];
      final hazardMarkerReports = <Map<String, dynamic>>[];
      for (final report in reports) {
        final lat = _toDouble(report['latitude']);
        final lng = _toDouble(report['longitude']);
        if (lat == null || lng == null) continue;
        hazardMarkerReports.add(report);
        hazardMarkerOptions.add(
          gnav.MarkerOptions(
            position: gnav.LatLng(latitude: lat, longitude: lng),
            infoWindow: gnav.InfoWindow(
              title: 'Flood report',
              snippet: (report['admin_decision'] ?? '').toString(),
            ),
          ),
        );
      }

      if (hazardMarkerOptions.isNotEmpty) {
        final addedHazardMarkers = await controller.addMarkers(
          hazardMarkerOptions,
        );
        for (var i = 0; i < addedHazardMarkers.length; i++) {
          final marker = addedHazardMarkers[i];
          if (marker == null || i >= hazardMarkerReports.length) continue;
          _androidHazardReportByMarkerId[marker.markerId] =
              hazardMarkerReports[i];
        }
      }

      final markerOptions = <gnav.MarkerOptions>[];
      if (_destinationPos != null) {
        markerOptions.add(
          gnav.MarkerOptions(
            position: gnav.LatLng(
              latitude: _destinationPos!.latitude,
              longitude: _destinationPos!.longitude,
            ),
            icon: bluePin,
            infoWindow: const gnav.InfoWindow(title: 'Destination'),
          ),
        );
      }

      if (_currentPCPos != null) {
        markerOptions.add(
          gnav.MarkerOptions(
            position: gnav.LatLng(
              latitude: _currentPCPos!.latitude,
              longitude: _currentPCPos!.longitude,
            ),
            icon: bluePin,
            rotation: _currentHeading,
            infoWindow: const gnav.InfoWindow(title: 'You'),
          ),
        );
      }

      if (markerOptions.isNotEmpty) {
        await controller.addMarkers(markerOptions);
      }

      final circleOptions = <gnav.CircleOptions>[];
      for (final report in reports) {
        final decision = (report['admin_decision'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        if (decision != 'impassable' && decision != 'risky') continue;
        final lat = _toDouble(report['latitude']);
        final lng = _toDouble(report['longitude']);
        if (lat == null || lng == null) continue;
        final isImpassable = decision == 'impassable';
        final stroke = isImpassable
            ? _dangerColor.withAlpha(220)
            : Colors.orangeAccent.withAlpha(220);
        circleOptions.add(
          gnav.CircleOptions(
            position: gnav.LatLng(latitude: lat, longitude: lng),
            radius: isImpassable ? 150.0 : 80.0,
            strokeColor: stroke,
            strokeWidth: 2,
            fillColor: stroke.withAlpha(50),
            zIndex: 1,
          ),
        );
      }
      if (circleOptions.isNotEmpty) {
        await controller.addCircles(circleOptions);
      }

      if (_routePoints.length >= 2) {
        await controller.addPolylines([
          gnav.PolylineOptions(
            points: _routePoints
                .map(
                  (point) => gnav.LatLng(
                    latitude: point.latitude,
                    longitude: point.longitude,
                  ),
                )
                .toList(),
            strokeColor: _pathIsBlocked
                ? _dangerColor.withAlpha(180)
                : _accentColor,
            strokeWidth: _pathIsBlocked ? 7 : 6,
            zIndex: 2,
          ),
        ]);
      }
    } catch (e) {
      debugPrint('home map overlay sync failed: $e');
    }
  }

  Future<gnav.ImageDescriptor> _ensureAndroidBluePinDescriptor() async {
    final existing = _androidBluePinDescriptor;
    if (existing != null) return existing;
    final byteData = await _buildBluePinIconByteData();
    final descriptor = await gnav.registerBitmapImage(
      bitmap: byteData,
      imagePixelRatio: 2,
      width: 36,
      height: 44,
    );
    _androidBluePinDescriptor = descriptor;
    return descriptor;
  }

  Future<ByteData> _buildBluePinIconByteData() async {
    const width = 72.0;
    const height = 88.0;
    const cx = width / 2;
    const circleRadius = 24.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, width, height));

    final fill = Paint()
      ..color = const Color(0xFF1E88E5)
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..isAntiAlias = true;

    canvas.drawCircle(const Offset(cx, 30), circleRadius, fill);
    canvas.drawCircle(const Offset(cx, 30), circleRadius, stroke);

    final tail = ui.Path()
      ..moveTo(cx, 80)
      ..lineTo(cx - 13, 47)
      ..lineTo(cx + 13, 47)
      ..close();
    canvas.drawPath(tail, fill);
    canvas.drawPath(tail, stroke);

    canvas.drawCircle(
      const Offset(cx, 30),
      8,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..isAntiAlias = true,
    );

    final image = await recorder.endRecording().toImage(
      width.toInt(),
      height.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      throw Exception('Could not encode blue pin icon.');
    }
    return bytes;
  }

  void _handleAndroidMapMarkerClicked(String markerId) {
    final report = _androidHazardReportByMarkerId[markerId];
    if (report != null) {
      _showReportDetails(report);
    }
  }

  Future<void> _minimizeAppToBackground() async {
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        await _appControlChannel.invokeMethod<bool>('moveTaskToBack');
        return;
      }
      await SystemNavigator.pop();
    } catch (_) {
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mapTabIndex = widget.isRescuerAccount ? 1 : 0;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (_bottomNavIndex != mapTabIndex) {
          setState(() => _bottomNavIndex = mapTabIndex);
        } else {
          unawaited(_minimizeAppToBackground());
        }
      },
      child: Scaffold(
      backgroundColor: const Color(0xFF0D141D),
      body: _bottomNavIndex == mapTabIndex
          ? Stack(
              children: [
                StreamBuilder<List<Map<String, dynamic>>>(
                  stream: Supabase.instance.client
                      .from('user_reports')
                      .stream(primaryKey: ['id']),
                  builder: (context, reportSnapshot) {
                    final allReports = reportSnapshot.data ?? [];
                    final verifiedReports = _normalizeVerifiedReports(
                      allReports,
                    );

                    // Keep warnings persistent even if stream briefly returns empty.
                    final displayReports = verifiedReports.isNotEmpty
                        ? verifiedReports
                        : _cachedVerifiedReports;
                    if (verifiedReports.isNotEmpty &&
                        verifiedReports.length !=
                            _cachedVerifiedReports.length) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          setState(() {
                            _cachedVerifiedReports = verifiedReports;
                          });
                        }
                      });
                    }

                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _checkRouteForFloods(displayReports),
                    );

                    return _buildMap(displayReports);
                  },
                ),

                _buildMapMoodOverlay(),

                _buildTopSearchBar(),
                _buildStatusStrip(),
                _buildSOSButton(),
                _buildFollowToggle(),
                _buildZoomControls(),

                // WARNING BAR (RED)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  bottom: _pathIsBlocked ? 0 : -96,
                  left: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () async {
                      final response = await Supabase.instance.client
                          .from('user_reports')
                          .select();
                      final reports = _normalizeVerifiedReports(
                        List<Map<String, dynamic>>.from(response),
                      );
                      _getSafeAStarRoute(reports);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 16,
                        horizontal: 22,
                      ),
                      decoration: BoxDecoration(
                        color: _dangerColor,
                        boxShadow: [
                          BoxShadow(
                            color: _dangerColor.withAlpha(110),
                            blurRadius: 24,
                            offset: const Offset(0, -4),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.alt_route, color: Colors.white, size: 20),
                          SizedBox(width: 15),
                          Flexible(
                            child: Text(
                              "Hazard ahead! Tap to get an alternate route.",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                if (_isRerouting)
                  Container(
                    color: Colors.black45,
                    child: const Center(
                      child: CircularProgressIndicator(color: _accentColor),
                    ),
                  ),

                if (widget.isRescuerAccount && _showRescuerNavStartBar)
                  _buildRescuerNavigationStartBar(),
                if (!widget.isRescuerAccount && _showUserNavStartBar)
                  _buildUserNavigationStartBar(),
              ],
            )
          : widget.isRescuerAccount
          ? _buildRescuerNonMapBody()
          : _buildUserNonMapBody(),
      bottomNavigationBar: _buildBottomNav(),
    ),
    );
  }

  // --- HELPER METHODS ---
  Widget _buildMapMoodOverlay() {
    return _HomePageMapLayers.buildMapMoodOverlay();
  }

  Widget _buildTopSearchBar() {
    return _HomePageMapLayers.buildTopSearchBar(this);
  }

  Widget _buildStatusStrip() {
    if (_destinationPos == null) {
      return const SizedBox.shrink();
    }

    final routeStatus = _pathIsBlocked
        ? "IMPASSABLE / ROAD CLOSED"
        : (_isFloodWarningAhead ? "CAUTION: WATER ON ROAD" : "NO FLOOD / CLEAR");
    final statusColor = _pathIsBlocked
        ? _dangerColor
        : (_isFloodWarningAhead ? Colors.orangeAccent : _accentColor);

    return Positioned(
      top: MediaQuery.of(context).padding.top + 80,
      left: 16,
      right: 16,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _panelColor.withAlpha(185),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white24),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: statusColor.withAlpha(160), blurRadius: 10),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                routeStatus,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _routePoints.isEmpty ? "0 pts" : "${_routePoints.length} pts",
              style: TextStyle(color: Colors.blueGrey.shade100, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  void _showReportDetails(Map<String, dynamic> report) {
    _HomePageHazardWidgets.showReportDetails(this, report);
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return _HomePageHazardWidgets.buildDetailRow(icon, label, value);
  }

  // Search destinations with Mapbox when a token is provided; otherwise use OSM.
  Future<List<Map<String, dynamic>>> _getSearchSuggestions(String query) async {
    if (query.length < 3) return [];

    try {
      if (_useGooglePlaces) {
        final placesSuggestions = await _getGooglePlaceSuggestions(query);
        if (placesSuggestions.isNotEmpty) return placesSuggestions;
      }

      if (!_allowLegacySearchFallback) {
        return [];
      }

      if (_useMapbox) {
        final encodedQuery = Uri.encodeComponent(query);
        final String mapboxUrl =
            'https://api.mapbox.com/geocoding/v5/mapbox.places/$encodedQuery.json?'
            'access_token=$_mapboxToken&'
            'proximity=${_currentPCPos?.longitude},${_currentPCPos?.latitude}&'
            'bbox=123.75,10.22,124.0,10.45&country=ph&limit=10';

        final mapboxResponse = await http.get(Uri.parse(mapboxUrl));
        if (mapboxResponse.statusCode == 200) {
          final data = json.decode(mapboxResponse.body);
          final List features = data['features'];
          return features
              .map(
                (f) => {
                  'display_name': f['place_name'],
                  'lat': f['geometry']['coordinates'][1].toString(),
                  'lon': f['geometry']['coordinates'][0].toString(),
                },
              )
              .toList();
        }
      } else {
        final encodedQuery = Uri.encodeComponent(query);
        final String nominatimUrl =
            'https://nominatim.openstreetmap.org/search?'
            'q=$encodedQuery&format=jsonv2&limit=10&countrycodes=ph&'
            'viewbox=123.75,10.45,124.0,10.22&bounded=1';

        final response = await http.get(
          Uri.parse(nominatimUrl),
          headers: const {'User-Agent': 'floote-app/1.0 (flutter_map_search)'},
        );
        if (response.statusCode == 200) {
          final List data = json.decode(response.body);
          return data
              .map(
                (f) => {
                  'display_name': f['display_name'],
                  'lat': f['lat'],
                  'lon': f['lon'],
                },
              )
              .toList();
        }
      }
    } catch (e) {
      debugPrint("Search provider error: $e");
    }
    return [];
  }

  Future<List<Map<String, dynamic>>> _getGooglePlaceSuggestions(
    String query,
  ) async {
    final center = _currentPCPos ?? _cebuLocation;
    final uri = Uri.https('places.googleapis.com', '/v1/places:autocomplete');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': _googlePlacesApiKey,
        'X-Goog-FieldMask':
            'suggestions.placePrediction.placeId,suggestions.placePrediction.text.text',
      },
      body: json.encode({
        'input': query,
        'languageCode': 'en',
        'regionCode': 'PH',
        'locationBias': {
          'circle': {
            'center': {
              'latitude': center.latitude,
              'longitude': center.longitude,
            },
            'radius': 50000.0,
          },
        },
      }),
    );

    if (response.statusCode != 200) {
      debugPrint('Google Places autocomplete error: ${response.statusCode}');
      return [];
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    final suggestions = (data['suggestions'] as List?) ?? const [];
    return suggestions
        .map((entry) => entry['placePrediction'])
        .whereType<Map>()
        .map<Map<String, dynamic>>((prediction) {
          final placeId = prediction['placeId']?.toString();
          final text = (prediction['text'] as Map?)?['text']?.toString();
          if (placeId == null ||
              placeId.isEmpty ||
              text == null ||
              text.isEmpty) {
            return const <String, dynamic>{};
          }
          return {'display_name': text, 'place_id': placeId};
        })
        .where((entry) => entry.isNotEmpty)
        .toList();
  }

  Future<LatLng?> _fetchGooglePlaceLocation(String placeId) async {
    final encodedPlaceId = Uri.encodeComponent(placeId);
    final uri = Uri.https(
      'places.googleapis.com',
      '/v1/places/$encodedPlaceId',
    );
    final response = await http.get(
      uri,
      headers: {
        'X-Goog-Api-Key': _googlePlacesApiKey,
        'X-Goog-FieldMask': 'location',
      },
    );

    if (response.statusCode != 200) {
      debugPrint('Google Place details error: ${response.statusCode}');
      return null;
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    final location = data['location'];
    if (location is! Map) return null;
    final lat = _toDouble(location['latitude']);
    final lng = _toDouble(location['longitude']);
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  Future<void> _fastTrackLocation() async {
    if (_useFixedCurrentLocation) {
      if (mounted) {
        setState(() => _currentPCPos = _cebuLocation);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _safeMapMove(_cebuLocation, 15.0);
      });
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) setState(() {});
      return;
    }

    Position? lastPos = await Geolocator.getLastKnownPosition();
    if (lastPos == null) {
      try {
        lastPos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        );
      } catch (e) {
        debugPrint('fastTrack getCurrentPosition: $e');
      }
    }

    if (lastPos != null && mounted) {
      final here = LatLng(lastPos.latitude, lastPos.longitude);
      setState(() {
        _currentPCPos = here;
        _mapCenter = here;
      });
      _safeMapMove(here, 15.0);
    }
    _initLocationTracking();
  }

  void _applySelectedDestination(LatLng dest, String displayName) {
    setState(() {
      _destinationPos = dest;
      _isAutoCentering = false;
      if (widget.isRescuerAccount) {
        _showRescuerNavStartBar = true;
      } else {
        _showUserNavStartBar = true;
      }
      _searchController.text = displayName;
    });
    _getInitialRoute(dest);
  }

  Future<void> _applySuggestionSelection(
    Map<String, dynamic> suggestion,
  ) async {
    final lat = _toDouble(suggestion['lat']);
    final lng = _toDouble(suggestion['lon']);
    final displayName = (suggestion['display_name'] ?? 'Selected destination')
        .toString();
    if (lat != null && lng != null) {
      _applySelectedDestination(LatLng(lat, lng), displayName);
      return;
    }

    final placeId = suggestion['place_id']?.toString();
    if (_useGooglePlaces && placeId != null && placeId.isNotEmpty) {
      final destination = await _fetchGooglePlaceLocation(placeId);
      if (destination != null) {
        _applySelectedDestination(destination, displayName);
        return;
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Unable to resolve selected place. Please try another.'),
        backgroundColor: Colors.redAccent,
      ),
    );
  }

  void _animatedMapMove(LatLng destLocation, double destZoom) {
    _safeMapMove(destLocation, destZoom);
  }

  Future<void> _initLocationTracking() async {
    if (_useFixedCurrentLocation) return;

    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 2,
      ),
    ).listen((pos) {
      if (mounted) {
        final newPos = LatLng(pos.latitude, pos.longitude);
        const Distance distance = Distance();
        setState(() {
          _currentPCPos = newPos;
          if (_routePoints.isNotEmpty) {
            int closestIndex = 0;
            double minDistance = double.infinity;
            for (int i = 0; i < _routePoints.length; i++) {
              double d = distance.as(LengthUnit.Meter, newPos, _routePoints[i]);
              if (d < minDistance) {
                minDistance = d;
                closestIndex = i;
              }
            }
            if (minDistance < 25) {
              _currentPCPos = _routePoints[closestIndex];
              if (closestIndex < _routePoints.length - 1) {
                _currentHeading = distance.bearing(
                  _routePoints[closestIndex],
                  _routePoints[closestIndex + 1],
                );
              }
            } else {
              _currentHeading = pos.heading;
            }
          } else {
            _currentHeading = pos.heading;
          }
        });
        if (_isAutoCentering) {
          _safeMapMove(_currentPCPos!, _mapZoom);
        }
      }
    });
  }

  void _safeMapMove(LatLng center, double zoom) {
    if (!_isMapReady) return;
    try {
      _mapCenter = center;
      _mapZoom = zoom;
      if (_useNavigationMapLayer) {
        final controller = _androidMapController;
        if (controller != null) {
          unawaited(
            controller.moveCamera(
              gnav.CameraUpdate.newLatLngZoom(
                gnav.LatLng(
                  latitude: center.latitude,
                  longitude: center.longitude,
                ),
                zoom,
              ),
            ),
          );
        }
        return;
      }
      _mapController.move(center, zoom);
    } catch (e) {
      debugPrint('Map move skipped until map is ready: $e');
    }
  }

  Widget _buildSOSButton() {
    final hasBottomStartBar =
        widget.isRescuerAccount ? _showRescuerNavStartBar : _showUserNavStartBar;
    return Positioned(
      bottom: hasBottomStartBar ? 92 : (_pathIsBlocked ? 78 : 28),
      right: 20,
      child: AnimatedBuilder(
        animation: _sosController,
        builder: (context, child) {
          final scale = 0.95 + (0.08 * _sosController.value);
          return Transform.scale(scale: scale, child: child);
        },
        child: GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const EmergencyPage()),
          ),
          child: Container(
            height: 70,
            width: 70,
            decoration: BoxDecoration(
              color: const Color(0xFFE43B2C),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFE43B2C).withAlpha(140),
                  blurRadius: 20,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Icon(
              Icons.emergency_share,
              color: Colors.white,
              size: 32,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFollowToggle() {
    final hasBottomStartBar =
        widget.isRescuerAccount ? _showRescuerNavStartBar : _showUserNavStartBar;
    return Positioned(
      bottom: hasBottomStartBar ? 190 : (_pathIsBlocked ? 170 : 125),
      left: 18,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _isAutoCentering
                  ? _accentColor.withAlpha(200)
                  : Colors.black54,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              _isAutoCentering ? "FOLLOW ON" : "FOLLOW OFF",
              style: TextStyle(
                color: _isAutoCentering ? Colors.black87 : Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            mini: true,
            backgroundColor: _isAutoCentering
                ? _accentColor
                : const Color(0xFF243242),
            onPressed: () {
              setState(() {
                _isAutoCentering = !_isAutoCentering;
                if (_isAutoCentering && _currentPCPos != null) {
                  _animatedMapMove(_currentPCPos!, 17.0);
                }
              });
            },
            child: Icon(
              _isAutoCentering ? Icons.gps_fixed : Icons.gps_not_fixed,
              color: _isAutoCentering ? Colors.black87 : Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildZoomControls() {
    final hasBottomStartBar =
        widget.isRescuerAccount ? _showRescuerNavStartBar : _showUserNavStartBar;
    return Positioned(
      bottom: hasBottomStartBar ? 190 : (_pathIsBlocked ? 170 : 125),
      right: 18,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A2432).withAlpha(220),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
          boxShadow: const [
            BoxShadow(
              color: Colors.black38,
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Zoom in',
              icon: const Icon(Icons.add, color: Colors.white),
              onPressed: () {
                if (!_isMapReady) return;
                final currentZoom = _mapZoom;
                final targetZoom = (currentZoom + 1.0).clamp(3.0, 19.0);
                _safeMapMove(_mapCenter, targetZoom);
              },
            ),
            Container(height: 1, width: 38, color: Colors.white24),
            IconButton(
              tooltip: 'Zoom out',
              icon: const Icon(Icons.remove, color: Colors.white),
              onPressed: () {
                if (!_isMapReady) return;
                final currentZoom = _mapZoom;
                final targetZoom = (currentZoom - 1.0).clamp(3.0, 19.0);
                _safeMapMove(_mapCenter, targetZoom);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Placeholder for flood-aware navigation start (wire to FastAPI / route later).
  Future<void> _handleRescuerStartNavigation() async {
    final dispatchId = _activeRescueDispatchId;
    final destination = _activeRescueDestination ?? _destinationPos;
    if (destination == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a destination before starting navigation.'),
        ),
      );
      return;
    }
    if (_currentPCPos == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Current GPS is not ready yet. Please try again.'),
        ),
      );
      return;
    }

    List<Map<String, dynamic>> verifiedReports = _cachedVerifiedReports;
    try {
      final response = await Supabase.instance.client.from('user_reports').select();
      verifiedReports = _normalizeVerifiedReports(
        List<Map<String, dynamic>>.from(response),
      );
      if (verifiedReports.isNotEmpty) {
        _cachedVerifiedReports = verifiedReports;
      }
    } catch (e) {
      debugPrint('start rescuer nav: user_reports fetch failed: $e');
    }

    if (!mounted) return;
    if (dispatchId != null && _activeRescueDestination != null) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => RescuerNavigationPage(
            dispatchId: dispatchId,
            ticketNumber: _activeRescueTicketNumber,
            initialOrigin: _currentPCPos!,
            initialDestination: destination,
            initialHazardReports: verifiedReports,
            initialPreferredPolyline: _routePoints,
          ),
        ),
      );
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UserNavigationPage(
          initialOrigin: _currentPCPos!,
          destination: destination,
          destinationLabel: _searchController.text.trim().isEmpty
              ? 'Destination'
              : _searchController.text.trim(),
          initialHazardReports: verifiedReports,
          initialPreferredPolyline: _routePoints,
        ),
      ),
    );
  }

  Future<void> _handleUserStartNavigation() async {
    final destination = _destinationPos;
    if (destination == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a destination before starting navigation.'),
        ),
      );
      return;
    }
    if (_currentPCPos == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Current GPS is not ready yet. Please try again.'),
        ),
      );
      return;
    }

    List<Map<String, dynamic>> verifiedReports = _cachedVerifiedReports;
    try {
      final response = await Supabase.instance.client.from('user_reports').select();
      verifiedReports = _normalizeVerifiedReports(
        List<Map<String, dynamic>>.from(response),
      );
      if (verifiedReports.isNotEmpty) {
        _cachedVerifiedReports = verifiedReports;
      }
    } catch (e) {
      debugPrint('start user nav: user_reports fetch failed: $e');
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => UserNavigationPage(
          initialOrigin: _currentPCPos!,
          destination: destination,
          destinationLabel: _searchController.text.trim().isEmpty
              ? null
              : _searchController.text.trim(),
          initialHazardReports: verifiedReports,
          initialPreferredPolyline: _routePoints,
        ),
      ),
    );
  }

  Widget _buildRescuerNavigationStartBar() {
    final hasActiveDispatch =
        _activeRescueDispatchId != null && _activeRescueDestination != null;
    final label = hasActiveDispatch ? 'Start Rescue' : 'Start to Destination';

    return Positioned(
      left: 14,
      right: 14,
      bottom: 14,
      child: SafeArea(
        top: false,
        left: false,
        right: false,
        child: Material(
          elevation: 10,
          borderRadius: BorderRadius.circular(14),
          color: const Color(0xFF111A24),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _handleRescuerStartNavigation,
              style: FilledButton.styleFrom(
                backgroundColor: _accentColor,
                foregroundColor: const Color(0xFF0D141D),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.navigation_rounded, size: 22),
              label: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUserNavigationStartBar() {
    return Positioned(
      left: 14,
      right: 14,
      bottom: 14,
      child: SafeArea(
        top: false,
        left: false,
        right: false,
        child: Material(
          elevation: 10,
          borderRadius: BorderRadius.circular(14),
          color: const Color(0xFF111A24),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _handleUserStartNavigation,
              style: FilledButton.styleFrom(
                backgroundColor: _accentColor,
                foregroundColor: const Color(0xFF0D141D),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.navigation_rounded, size: 22),
              label: const Text(
                'Start',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return HomeBottomNav(
      isRescuerAccount: widget.isRescuerAccount,
      currentIndex: _bottomNavIndex,
      onTap: (index) => setState(() => _bottomNavIndex = index),
      accentColor: _accentColor,
    );
  }

  Widget _buildRescuerNonMapBody() {
    switch (_bottomNavIndex) {
      case 0:
        return _buildDashboardTabPage();
      case 2:
        return RescuerRescueCenterPage(
          onDispatchAccepted: ({
            required String dispatchId,
            required double latitude,
            required double longitude,
            String? ticketNumber,
          }) {
            if (!mounted) return;
            setState(() {
              _activeRescueDispatchId = dispatchId;
              _activeRescueTicketNumber = ticketNumber;
              _activeRescueDestination = LatLng(latitude, longitude);
              _destinationPos = _activeRescueDestination;
              _bottomNavIndex = 1;
              _showRescuerNavStartBar = true;
            });
          },
        );
      case 3:
        return const ProfilePage(
          isRescuerAccount: true,
          embeddedInShell: true,
        );
      default:
        return _buildBlankTabPage();
    }
  }

  Widget _buildUserNonMapBody() {
    switch (_bottomNavIndex) {
      case 1:
        return _buildUserAlertsTabPage();
      case 2:
        return const IncidentReportPage();
      case 3:
        return const ProfilePage(
          isRescuerAccount: false,
          embeddedInShell: true,
        );
      default:
        return _buildBlankTabPage();
    }
  }

  Widget _buildUserAlertsTabPage() {
    return const AlertsPage();
  }

  Widget _buildBlankTabPage() {
    return const ColoredBox(color: Colors.black);
  }

  Widget _buildDashboardTabPage() {
    return ColoredBox(
      color: const Color(0xFF0D141D),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF101A24),
                border: Border(
                  bottom: BorderSide(color: Colors.white.withAlpha(26)),
                ),
              ),
              child: const Text(
                'RESCUER DASHBOARD',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            RescuerDashboardHeaderCard(
              isActiveDuty: _isActiveDuty,
              onDutyChanged: (value) => unawaited(_persistDutyToggle(value)),
              accentColor: _accentColor,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RescuerSensorNetworkPage(),
                    ),
                  );
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _panelColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withAlpha(26)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.sensors, color: Color(0xFF00E4FF)),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Sensor Network',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: Colors.white70),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RescuerHistoricalLogsPage(),
                    ),
                  );
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _panelColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withAlpha(26)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.history, color: Color(0xFF00E4FF)),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Historical Data Logs',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: Colors.white70),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
