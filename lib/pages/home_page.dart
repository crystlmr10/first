import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'emergency_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();

  static const Color _accentColor = Color(0xFF00E4FF);
  static const Color _dangerColor = Color(0xFFFF4C4C);
  static const Color _panelColor = Color(0xFF111A24);
  static const LatLng _cituLocation = LatLng(10.297438, 123.876313);
  static const bool _useFixedCurrentLocation = true;

  late final AnimationController _pulseController;
  late final AnimationController _sosController;
  bool _isAutoCentering = false;
  bool _isRerouting = false;
  bool _pathIsBlocked = false;
  bool _isFloodWarningAhead = false;
  List<Map<String, dynamic>> _cachedVerifiedReports = const [];

  LatLng? _currentPCPos = _cituLocation;
  double _currentHeading = 0.0;

  List<LatLng> _routePoints = [];
  LatLng? _destinationPos;

  static const String _mapboxToken = String.fromEnvironment(
    'MAPBOX_TOKEN',
    defaultValue: '',
  );
  static const String _mapboxStyleId = 'mapbox/streets-v12';
  bool get _useMapbox => _mapboxToken.startsWith('pk.') && _mapboxToken.isNotEmpty;

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
    _fastTrackLocation();
  }

  @override
  void dispose() {
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
      final decision = (r['admin_decision'] ?? '').toString().trim();
      if (decision != 'Impassable' && decision != 'Risky') continue;
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
        final decision = (report['admin_decision'] ?? '').toString();
        final d = distance.as(
          LengthUnit.Meter,
          point,
          LatLng(report['latitude'], report['longitude']),
        );

        if (decision == 'Impassable' && d < 150) {
          hazardFound = true;
          break;
        }

        if (decision == 'Risky' && d < 80) {
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
    final url =
        'https://router.project-osrm.org/route/v1/driving/${_currentPCPos!.longitude},${_currentPCPos!.latitude};${destination.longitude},${destination.latitude}?overview=full&geometries=geojson';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List coords = data['routes'][0]['geometry']['coordinates'];
        setState(() {
          _routePoints = coords
              .map((c) => LatLng(c[1].toDouble(), c[0].toDouble()))
              .toList();
          _pathIsBlocked = false;
        });

        if (_routePoints.isNotEmpty) {
          _mapController.fitCamera(
            CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(_routePoints),
              padding: const EdgeInsets.all(70.0),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Standard Routing Error: $e");
    }
  }

  // --- 3. FASTAPI FLOOD-AWARE REROUTE ---
  Future<void> _getSafeAStarRoute(
    List<Map<String, dynamic>> _verifiedReports,
  ) async {
    if (_currentPCPos == null || _destinationPos == null) return;

    setState(() => _isRerouting = true);

    // Use emulator loopback by default. Override using:
    // flutter run --dart-define=ROUTING_API_URL=http://<your-ip>:8000/route
    const String apiUrlOverride = String.fromEnvironment('ROUTING_API_URL');
    final String apiUrl = apiUrlOverride.isNotEmpty
        ? apiUrlOverride
        : (kIsWeb
              ? 'http://127.0.0.1:8000/route'
              : 'http://10.0.2.2:8000/route');

    // Build a lightweight dynamic graph from current route geometry.
    // This lets FastAPI run safety checks using live Supabase flood reports.
    final List<LatLng> seedPoints = [];
    seedPoints.add(_currentPCPos!);

    if (_routePoints.length > 2) {
      final step = (_routePoints.length / 24).ceil().clamp(1, 10);
      for (int i = step; i < _routePoints.length - 1; i += step) {
        seedPoints.add(_routePoints[i]);
      }
    }

    seedPoints.add(_destinationPos!);

    final hazardPoints = _verifiedReports
        .where((r) => (r['admin_decision'] ?? '').toString() == 'Impassable')
        .where((r) => r['latitude'] is num && r['longitude'] is num)
        .map(
          (r) => LatLng(
            (r['latitude'] as num).toDouble(),
            (r['longitude'] as num).toDouble(),
          ),
        )
        .toList();

    final attemptConfigs = <Map<String, dynamic>>[
      {'maxLane': 2, 'laneStepMeters': 180.0},
      {'maxLane': 3, 'laneStepMeters': 230.0},
      {'maxLane': 4, 'laneStepMeters': 280.0},
    ];

    String lastError = "No safe route found";
    bool connected = false;

    for (int attempt = 0; attempt < attemptConfigs.length; attempt++) {
      final cfg = attemptConfigs[attempt];
      final payload = _buildDetourPayload(
        seedPoints,
        maxLane: cfg['maxLane'] as int,
        laneStepMeters: cfg['laneStepMeters'] as double,
      );

      try {
        final response = await http.post(
          Uri.parse(apiUrl),
          headers: {"Content-Type": "application/json"},
          body: json.encode(payload),
        );
        connected = true;

        if (response.statusCode != 200) {
          lastError = "Routing API error: ${response.statusCode}";
          continue;
        }

        final data = json.decode(response.body);
        final status = (data['status'] ?? '').toString();
        if (status != 'safe' && status != 'rerouted') {
          lastError = (data['message'] ?? "No safe route found").toString();
          continue;
        }

        final List coords = (data['polyline'] ?? []) as List;
        if (coords.isEmpty) {
          lastError = "Routing service returned empty polyline.";
          continue;
        }

        final backendPolyline = coords
            .where((c) => c is Map && c['lat'] is num && c['lng'] is num)
            .map<LatLng>(
              (c) => LatLng(
                (c['lat'] as num).toDouble(),
                (c['lng'] as num).toDouble(),
              ),
            )
            .toList();

        if (backendPolyline.length < 2) {
          lastError = "Routing service returned invalid polyline.";
          continue;
        }

        final shapedPolyline = await _shapePolylineOnRoads(
          backendPolyline,
          hazardPoints,
        );

        if (shapedPolyline.isEmpty) {
          lastError = "No road-following reroute found.";
          continue;
        }
        if (_routeIntersectsHazards(shapedPolyline, hazardPoints, 150.0)) {
          lastError = "No safe reroute found outside 150m hazard radius.";
          continue;
        }

        final cleaned = _removeDeadEndLoops(shapedPolyline);
        if (cleaned.length < 2) {
          lastError = "No road-following reroute found.";
          continue;
        }

        if (!mounted) return;
        setState(() {
          _routePoints = cleaned;
          _isRerouting = false;
          _pathIsBlocked = false;
          _isFloodWarningAhead = false;
        });
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(_routePoints),
            padding: const EdgeInsets.all(70.0),
          ),
        );
        return;
      } catch (e) {
        debugPrint("FastAPI route error (attempt ${attempt + 1}): $e");
        lastError = "Cannot connect to routing backend.";
        break;
      }
    }

    // Final fallback: try a bypass corridor route with offset waypoints.
    final bypassRoute = await _shapeViaBypassCorridor(
      _currentPCPos!,
      _destinationPos!,
      hazardPoints,
    );
    if (bypassRoute.isNotEmpty && mounted) {
      setState(() {
        _routePoints = _removeDeadEndLoops(bypassRoute);
        _isRerouting = false;
        _pathIsBlocked = false;
        _isFloodWarningAhead = false;
      });
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(_routePoints),
          padding: const EdgeInsets.all(70.0),
        ),
      );
      return;
    }

    if (!mounted) return;
    setState(() => _isRerouting = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          connected
              ? "$lastError Tried wider detour but no valid safe route."
              : lastError,
        ),
        backgroundColor: Colors.red,
      ),
    );
  }

  Map<String, dynamic> _buildDetourPayload(
    List<LatLng> seedPoints, {
    required int maxLane,
    required double laneStepMeters,
  }) {
    const Distance dist = Distance();
    final Map<String, dynamic> payloadNodes = {};
    final Map<String, List<Map<String, dynamic>>> payloadGraph = {};

    String nodeId(int lane, int idx) => 'L${lane}_$idx';
    double laneOffsetMeters(int lane) => laneStepMeters * lane.abs();

    LatLng lanePoint(int lane, int idx) {
      final base = seedPoints[idx];
      if (lane == 0) return base;
      final prev = seedPoints[idx == 0 ? idx : idx - 1];
      final next = seedPoints[idx == seedPoints.length - 1 ? idx : idx + 1];
      final bearing = dist.bearing(prev, next);
      final offsetBearing = lane < 0 ? bearing - 90.0 : bearing + 90.0;
      return dist.offset(base, laneOffsetMeters(lane), offsetBearing);
    }

    for (int lane = -maxLane; lane <= maxLane; lane++) {
      for (int i = 0; i < seedPoints.length; i++) {
        final p = lanePoint(lane, i);
        final id = nodeId(lane, i);
        payloadNodes[id] = {'lat': p.latitude, 'lng': p.longitude};
        payloadGraph[id] = [];
      }
    }

    void addEdgeById(String fromId, String toId) {
      final from = payloadNodes[fromId];
      final to = payloadNodes[toId];
      if (from == null || to == null) return;
      final fromPos = LatLng(
        (from['lat'] as num).toDouble(),
        (from['lng'] as num).toDouble(),
      );
      final toPos = LatLng(
        (to['lat'] as num).toDouble(),
        (to['lng'] as num).toDouble(),
      );
      final d = dist.as(LengthUnit.Meter, fromPos, toPos);
      payloadGraph[fromId]!.add({
        'to': toId,
        'distance': d,
        'flood_depth': 0,
        'impassable_sign': false,
      });
    }

    for (int lane = -maxLane; lane <= maxLane; lane++) {
      for (int i = 0; i < seedPoints.length - 1; i++) {
        final a = nodeId(lane, i);
        final b = nodeId(lane, i + 1);
        addEdgeById(a, b);
        addEdgeById(b, a);
      }
    }

    for (int i = 0; i < seedPoints.length; i++) {
      for (int lane = -maxLane; lane < maxLane; lane++) {
        addEdgeById(nodeId(lane, i), nodeId(lane + 1, i));
        addEdgeById(nodeId(lane + 1, i), nodeId(lane, i));
      }
      if (i < seedPoints.length - 1) {
        for (int lane = -maxLane; lane <= maxLane; lane++) {
          if (lane - 1 >= -maxLane) {
            addEdgeById(nodeId(lane, i), nodeId(lane - 1, i + 1));
          }
          if (lane + 1 <= maxLane) {
            addEdgeById(nodeId(lane, i), nodeId(lane + 1, i + 1));
          }
        }
      }
    }

    return {
      "start": nodeId(0, 0),
      "goal": nodeId(0, seedPoints.length - 1),
      "nodes": payloadNodes,
      "graph": payloadGraph,
    };
  }

  Future<List<LatLng>> _shapePolylineOnRoads(
    List<LatLng> controlPoints,
    List<LatLng> hazardPoints,
  ) async {
    if (controlPoints.length < 2) return controlPoints;

    // Keep request size reasonable while preserving route shape.
    final reduced = <LatLng>[];
    final step = (controlPoints.length / 30).ceil().clamp(1, 4);
    for (int i = 0; i < controlPoints.length; i += step) {
      reduced.add(controlPoints[i]);
    }
    if (reduced.last != controlPoints.last) {
      reduced.add(controlPoints.last);
    }

    // Snap control points to nearest drivable road first to improve segment routing.
    final snapped = <LatLng>[];
    for (final p in reduced) {
      snapped.add(await _snapToNearestRoad(p));
    }

    final stitched = <LatLng>[];
    bool segmentFailed = false;

    try {
      // Route each segment separately to reduce odd global loops/dead-ends.
      for (int i = 0; i < snapped.length - 1; i++) {
        final a = snapped[i];
        final b = snapped[i + 1];
        final segUrl = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/'
          '${a.longitude},${a.latitude};${b.longitude},${b.latitude}'
          '?overview=full&geometries=geojson',
        );
        final response = await http.get(segUrl);
        if (response.statusCode != 200) {
          debugPrint('OSRM segment shaping failed: ${response.statusCode}');
          segmentFailed = true;
          break;
        }
        final data = json.decode(response.body);
        final routes = data['routes'];
        if (routes is! List || routes.isEmpty) {
          segmentFailed = true;
          break;
        }
        final coordinates = routes[0]['geometry']['coordinates'];
        if (coordinates is! List || coordinates.isEmpty) {
          segmentFailed = true;
          break;
        }

        final segPoints = coordinates
            .map<LatLng>(
              (c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
            )
            .toList();

        if (stitched.isEmpty) {
          stitched.addAll(segPoints);
        } else {
          // avoid duplicate join point between consecutive segments
          stitched.addAll(segPoints.skip(1));
        }
      }

      if (!segmentFailed && stitched.isNotEmpty) {
        if (_routeIntersectsHazards(stitched, hazardPoints, 150.0)) {
          // Try a waypoint-based fallback if stitched path clips hazard radius.
          final viaWaypoint = await _shapeViaSafeWaypoint(
            snapped,
            hazardPoints,
          );
          if (viaWaypoint.isNotEmpty) {
            return viaWaypoint;
          }
          return _shapeDirectRoadRoute(
            snapped.first,
            snapped.last,
            hazardPoints,
          );
        }
        return stitched;
      }

      // Segment chain failed: fallback through one "safest" waypoint.
      final viaWaypoint = await _shapeViaSafeWaypoint(snapped, hazardPoints);
      if (viaWaypoint.isNotEmpty) {
        return viaWaypoint;
      }
      return _shapeDirectRoadRoute(
        snapped.first,
        snapped.last,
        hazardPoints,
      );
    } catch (e) {
      debugPrint('OSRM shaping error: $e');
      final viaWaypoint = await _shapeViaSafeWaypoint(snapped, hazardPoints);
      if (viaWaypoint.isNotEmpty) {
        return viaWaypoint;
      }
      return _shapeDirectRoadRoute(
        snapped.first,
        snapped.last,
        hazardPoints,
      );
    }
  }

  Future<List<LatLng>> _shapeDirectRoadRoute(
    LatLng start,
    LatLng end,
    List<LatLng> hazards,
  ) async {
    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '${start.longitude},${start.latitude};${end.longitude},${end.latitude}'
      '?overview=full&geometries=geojson',
    );
    try {
      final response = await http.get(url);
      if (response.statusCode != 200) return [];
      final data = json.decode(response.body);
      final routes = data['routes'];
      if (routes is! List || routes.isEmpty) return [];
      final coordinates = routes[0]['geometry']['coordinates'];
      if (coordinates is! List || coordinates.isEmpty) return [];
      final route = coordinates
          .map<LatLng>(
            (c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
          )
          .toList();
      if (_routeIntersectsHazards(route, hazards, 150.0)) return [];
      return route;
    } catch (_) {
      return [];
    }
  }

  Future<List<LatLng>> _shapeViaBypassCorridor(
    LatLng start,
    LatLng end,
    List<LatLng> hazards,
  ) async {
    const Distance dist = Distance();
    final baseBearing = dist.bearing(start, end);
    final leftBearing = baseBearing - 90.0;
    final rightBearing = baseBearing + 90.0;

    final candidates = <List<LatLng>>[];
    for (final offset in [250.0, 350.0, 500.0, 650.0]) {
      for (final side in [leftBearing, rightBearing]) {
        final p1 = _interpolateLatLng(start, end, 0.35);
        final p2 = _interpolateLatLng(start, end, 0.70);
        candidates.add([
          await _snapToNearestRoad(start),
          await _snapToNearestRoad(dist.offset(p1, offset, side)),
          await _snapToNearestRoad(dist.offset(p2, offset, side)),
          await _snapToNearestRoad(end),
        ]);
      }
    }

    for (final c in candidates) {
      final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/'
        '${c[0].longitude},${c[0].latitude};'
        '${c[1].longitude},${c[1].latitude};'
        '${c[2].longitude},${c[2].latitude};'
        '${c[3].longitude},${c[3].latitude}'
        '?overview=full&geometries=geojson',
      );
      try {
        final response = await http.get(url);
        if (response.statusCode != 200) continue;
        final data = json.decode(response.body);
        final routes = data['routes'];
        if (routes is! List || routes.isEmpty) continue;
        final coordinates = routes[0]['geometry']['coordinates'];
        if (coordinates is! List || coordinates.isEmpty) continue;
        final route = coordinates
            .map<LatLng>(
              (v) => LatLng((v[1] as num).toDouble(), (v[0] as num).toDouble()),
            )
            .toList();
        if (!_routeIntersectsHazards(route, hazards, 150.0)) {
          return route;
        }
      } catch (_) {
        continue;
      }
    }
    return [];
  }

  LatLng _interpolateLatLng(LatLng a, LatLng b, double t) {
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  Future<List<LatLng>> _shapeViaSafeWaypoint(
    List<LatLng> points,
    List<LatLng> hazards,
  ) async {
    if (points.length < 3) return [];
    const Distance dist = Distance();

    // Pick the internal point that is farthest from all hazards.
    LatLng? best;
    double bestScore = -1.0;
    final start = points.first;
    final end = points.last;

    for (int i = 1; i < points.length - 1; i++) {
      final p = points[i];
      final fromStart = dist.as(LengthUnit.Meter, start, p);
      final toEnd = dist.as(LengthUnit.Meter, p, end);
      if (fromStart < 120 || toEnd < 120) continue;

      double minHz = double.infinity;
      for (final hz in hazards) {
        final d = dist.as(LengthUnit.Meter, p, hz);
        if (d < minHz) minHz = d;
      }
      if (hazards.isEmpty) minHz = 999999;
      if (minHz > bestScore) {
        bestScore = minHz;
        best = p;
      }
    }

    if (best == null) return [];

    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '${start.longitude},${start.latitude};'
      '${best.longitude},${best.latitude};'
      '${end.longitude},${end.latitude}'
      '?overview=full&geometries=geojson',
    );
    try {
      final response = await http.get(url);
      if (response.statusCode != 200) return [];
      final data = json.decode(response.body);
      final routes = data['routes'];
      if (routes is! List || routes.isEmpty) return [];
      final coordinates = routes[0]['geometry']['coordinates'];
      if (coordinates is! List || coordinates.isEmpty) return [];
      final route = coordinates
          .map<LatLng>(
            (c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
          )
          .toList();
      if (_routeIntersectsHazards(route, hazards, 150.0)) return [];
      return route;
    } catch (_) {
      return [];
    }
  }

  Future<LatLng> _snapToNearestRoad(LatLng point) async {
    final url = Uri.parse(
      'https://router.project-osrm.org/nearest/v1/driving/'
      '${point.longitude},${point.latitude}?number=1',
    );
    try {
      final response = await http.get(url);
      if (response.statusCode != 200) return point;
      final data = json.decode(response.body);
      final waypoints = data['waypoints'];
      if (waypoints is! List || waypoints.isEmpty) return point;
      final location = waypoints[0]['location'];
      if (location is! List || location.length < 2) return point;
      return LatLng(
        (location[1] as num).toDouble(),
        (location[0] as num).toDouble(),
      );
    } catch (_) {
      return point;
    }
  }

  bool _routeIntersectsHazards(
    List<LatLng> route,
    List<LatLng> hazards,
    double radiusMeters,
  ) {
    if (route.length < 2 || hazards.isEmpty) return false;
    const Distance dist = Distance();

    for (int i = 0; i < route.length - 1; i++) {
      final a = route[i];
      final b = route[i + 1];
      final segmentLength = dist.as(LengthUnit.Meter, a, b);
      final samples = (segmentLength / 20.0).ceil().clamp(1, 40);

      for (int s = 0; s <= samples; s++) {
        final t = s / samples;
        final sample = LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        );
        for (final hz in hazards) {
          if (dist.as(LengthUnit.Meter, sample, hz) <= radiusMeters) {
            return true;
          }
        }
      }
    }
    return false;
  }

  List<LatLng> _removeDeadEndLoops(List<LatLng> points) {
    if (points.length < 3) return points;
    const Distance dist = Distance();
    final cleaned = <LatLng>[points.first];

    for (int i = 1; i < points.length - 1; i++) {
      final prev = cleaned.last;
      final current = points[i];
      final next = points[i + 1];
      final prevToCurrent = dist.as(LengthUnit.Meter, prev, current);
      final currentToNext = dist.as(LengthUnit.Meter, current, next);
      final prevToNext = dist.as(LengthUnit.Meter, prev, next);

      // If this point creates a tiny out-and-back detour, skip it.
      final isLoopish = prevToCurrent < 45 &&
          currentToNext < 45 &&
          prevToNext < 30;
      if (!isLoopish) cleaned.add(current);
    }

    cleaned.add(points.last);
    return _prunePolylineLoops(cleaned);
  }

  List<LatLng> _prunePolylineLoops(List<LatLng> points) {
    if (points.length < 4) return points;
    const Distance dist = Distance();
    final output = List<LatLng>.from(points);

    // Pass 1: remove branch-like loops where path comes back near an older point.
    bool changed = true;
    int guard = 0;
    while (changed && output.length > 6 && guard < 5) {
      changed = false;
      guard++;
      bool broke = false;

      for (int i = 0; i < output.length - 8; i++) {
        for (int j = i + 6; j < output.length - 1; j++) {
          final nearReturn = dist.as(LengthUnit.Meter, output[i], output[j]) < 60;
          if (!nearReturn) continue;

          double branchLength = 0;
          for (int k = i; k < j; k++) {
            branchLength += dist.as(LengthUnit.Meter, output[k], output[k + 1]);
          }

          // Drop only local detour branches, keep long legitimate route sections.
          if (branchLength < 700) {
            output.removeRange(i + 1, j);
            changed = true;
            broke = true;
            break;
          }
        }
        if (broke) break;
      }
    }

    // Final pass: remove obvious sharp out-and-back zigzags.
    if (output.length < 3) return output;
    final finalClean = <LatLng>[output.first];
    for (int i = 1; i < output.length - 1; i++) {
      final a = finalClean.last;
      final b = output[i];
      final c = output[i + 1];

      final ab = dist.as(LengthUnit.Meter, a, b);
      final bc = dist.as(LengthUnit.Meter, b, c);
      final ac = dist.as(LengthUnit.Meter, a, c);
      final isBacktrackSpike = ab < 140 && bc < 140 && ac < 55;

      if (!isBacktrackSpike) {
        finalClean.add(b);
      }
    }
    finalClean.add(output.last);
    return finalClean;
  }

  void _clearRoute() {
    setState(() {
      _routePoints = [];
      _destinationPos = null;
      _pathIsBlocked = false;
      _isFloodWarningAhead = false;
      _isRerouting = false;
      _searchController.clear();
      _isAutoCentering = true;
    });
    if (_currentPCPos != null) _animatedMapMove(_currentPCPos!, 15.0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D141D),
      body: Stack(
        children: [
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: Supabase.instance.client
                .from('user_reports')
                .stream(primaryKey: ['id']),
            builder: (context, reportSnapshot) {
              final allReports = reportSnapshot.data ?? [];
              final verifiedReports = _normalizeVerifiedReports(allReports);

              // Keep warnings persistent even if stream briefly returns empty.
              final displayReports = verifiedReports.isNotEmpty
                  ? verifiedReports
                  : _cachedVerifiedReports;
              if (verifiedReports.isNotEmpty &&
                  verifiedReports.length != _cachedVerifiedReports.length) {
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

              return FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _currentPCPos ?? _cituLocation,
                  initialZoom: 15.0,
                  onPositionChanged: (pos, hasGesture) {
                    if (hasGesture && _isAutoCentering) {
                      setState(() => _isAutoCentering = false);
                    }
                  },
                ),
                children: [
                  if (_useMapbox)
                    TileLayer(
                      urlTemplate:
                          'https://api.mapbox.com/styles/v1/$_mapboxStyleId/tiles/256/{z}/{x}/{y}@2x?access_token=$_mapboxToken',
                      additionalOptions: const {'accessToken': _mapboxToken},
                      userAgentPackageName: 'com.floote.app',
                    )
                  else
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.floote.app',
                    ),

                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _routePoints,
                        color: _pathIsBlocked
                            ? _dangerColor.withAlpha(180)
                            : _accentColor,
                        strokeWidth: _pathIsBlocked ? 6.0 : 5.0,
                        borderColor: Colors.black.withAlpha(80),
                        borderStrokeWidth: 1.2,
                      ),
                      ..._buildHazardRadiusRings(displayReports),
                    ],
                  ),

                  MarkerLayer(
                    markers: [
                      ...displayReports.map(
                        (r) => Marker(
                          point: LatLng(r['latitude'], r['longitude']),
                          width: 52,
                          height: 52,
                          child: GestureDetector(
                            onTap: () => _showReportDetails(r),
                            child: AnimatedBuilder(
                              animation: _pulseController,
                              builder: (context, child) {
                                final glow =
                                    0.35 + (0.65 * _pulseController.value);
                                return Transform.scale(
                                  scale: 0.92 + (0.16 * _pulseController.value),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: _getDecisionColor(
                                            r['admin_decision'],
                                          ).withAlpha((120 * glow).toInt()),
                                          blurRadius: 16,
                                          spreadRadius: 2,
                                        ),
                                      ],
                                    ),
                                    child: child,
                                  ),
                                );
                              },
                              child: Icon(
                                Icons.warning_rounded,
                                color: _getDecisionColor(r['admin_decision']),
                                size: 36,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_destinationPos != null)
                        Marker(
                          point: _destinationPos!,
                          width: 44,
                          height: 44,
                          child: AnimatedBuilder(
                            animation: _pulseController,
                            builder: (context, child) => Transform.translate(
                              offset: Offset(0, -3 * _pulseController.value),
                              child: child,
                            ),
                            child: const Icon(
                              Icons.location_on,
                              color: Colors.red,
                              size: 42,
                            ),
                          ),
                        ),
                      if (_currentPCPos != null)
                        Marker(
                          point: _currentPCPos!,
                          width: 70,
                          height: 70,
                          child: AnimatedBuilder(
                            animation: _pulseController,
                            builder: (context, child) => Transform.rotate(
                              angle: (_currentHeading * (3.14159 / 180)),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Container(
                                    width: 56 + (8 * _pulseController.value),
                                    height: 56 + (8 * _pulseController.value),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: _accentColor.withAlpha(35),
                                    ),
                                  ),
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFF061018,
                                      ).withAlpha(180),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: _accentColor.withAlpha(200),
                                        width: 1.6,
                                      ),
                                    ),
                                  ),
                                  const Icon(
                                    Icons.navigation,
                                    color: _accentColor,
                                    size: 32,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),

                  RichAttributionWidget(
                    attributions: [
                      if (_useMapbox)
                        TextSourceAttribution(
                          'Mapbox',
                          onTap: () => debugPrint('Mapbox attribution tapped'),
                        )
                      else
                        TextSourceAttribution(
                          'OpenStreetMap contributors',
                          onTap: () =>
                              debugPrint('OpenStreetMap attribution tapped'),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),

          _buildMapMoodOverlay(),

          _buildTopSearchBar(),
          _buildStatusStrip(),
          _buildWaterLevelStrip(),
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
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  // --- HELPER METHODS ---
  Widget _buildMapMoodOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Column(
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF0B141D).withAlpha(110),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      const Color(0xFF0B141D).withAlpha(135),
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

  Widget _buildTopSearchBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(232),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withAlpha(145), width: 1),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: TypeAheadField<Map<String, dynamic>>(
            builder: (context, controller, focusNode) {
              _searchController.value = controller.value;
              return TextField(
                controller: controller,
                focusNode: focusNode,
                decoration: InputDecoration(
                  hintText: "Search destination",
                  hintStyle: TextStyle(
                    color: Colors.blueGrey.shade400,
                    fontSize: 14,
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: _accentColor,
                  ),
                  suffixIcon: _destinationPos != null
                      ? IconButton(
                          icon: const Icon(Icons.close, color: Colors.red),
                          onPressed: _clearRoute,
                        )
                      : const Icon(
                          Icons.place_outlined,
                          color: Colors.blueGrey,
                        ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 15),
                ),
              );
            },
            suggestionsCallback: (pattern) async =>
                await _getSearchSuggestions(pattern),
            itemBuilder: (context, suggestion) => ListTile(
              leading: const Icon(
                Icons.pin_drop_outlined,
                color: _accentColor,
                size: 18,
              ),
              title: Text(
                suggestion['display_name'] ?? "Unknown",
                style: const TextStyle(fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            onSelected: (suggestion) {
              final dest = LatLng(
                double.parse(suggestion['lat']),
                double.parse(suggestion['lon']),
              );
              setState(() {
                _destinationPos = dest;
                _isAutoCentering = false;
                _searchController.text = suggestion['display_name'] ?? "";
              });
              _getInitialRoute(dest);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildStatusStrip() {
    if (_destinationPos == null) {
      return const SizedBox.shrink();
    }

    final routeStatus = _pathIsBlocked
        ? "IMPASSABLE / ROAD CLOSED (Half-Tire Deep)"
        : (_isFloodWarningAhead
              ? "CAUTION: WATER ON ROAD (Gutter Deep)"
              : "NO FLOOD / CLEAR");
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

  Widget _buildWaterLevelStrip() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: Supabase.instance.client
          .from('user_reports')
          .stream(primaryKey: ['id']),
      builder: (context, snapshot) {
        final reports = snapshot.data ?? const <Map<String, dynamic>>[];
        final bestReport = _pickWaterLevelReport(reports);
        if (bestReport == null) {
          return const SizedBox.shrink();
        }

        final waterLevelCm = _readWaterLevelCm(bestReport);
        final decision = (bestReport['admin_decision'] ?? '').toString();
        final location =
            (bestReport['location_name'] ?? 'Nearby area').toString();

        final Color levelColor =
            waterLevelCm >= 80 ? _dangerColor : (waterLevelCm >= 40 ? Colors.orangeAccent : _accentColor);

        return Positioned(
          top: MediaQuery.of(context).padding.top + 130,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: _panelColor.withAlpha(200),
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
                Icon(Icons.water_drop, color: levelColor, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Water Level: ${waterLevelCm.toStringAsFixed(1)} cm',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$location • $decision',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.blueGrey.shade100,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Polyline> _buildHazardRadiusRings(List<Map<String, dynamic>> reports) {
    const Distance distance = Distance();
    final List<Polyline> rings = [];

    for (final report in reports) {
      final decision = (report['admin_decision'] ?? '').toString();
      if (decision != 'Impassable' && decision != 'Risky') continue;

      final lat = (report['latitude'] as num?)?.toDouble();
      final lng = (report['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;

      final center = LatLng(lat, lng);
      final radiusMeters = decision == 'Impassable' ? 150.0 : 80.0;
      final ringColor = decision == 'Impassable'
          ? _dangerColor.withAlpha(220)
          : Colors.orangeAccent.withAlpha(220);

      // Draw a broken circle using many short arc segments.
      const int segments = 36; // 10 degrees each around the circle
      for (int i = 0; i < segments; i++) {
        if (i.isOdd) continue; // every other segment is skipped (gap)

        final startBearing = i * (360.0 / segments);
        final midBearing = startBearing + 4.0;
        final endBearing = startBearing + 8.0;

        final p1 = distance.offset(center, radiusMeters, startBearing);
        final p2 = distance.offset(center, radiusMeters, midBearing);
        final p3 = distance.offset(center, radiusMeters, endBearing);

        rings.add(
          Polyline(
            points: [p1, p2, p3],
            color: ringColor,
            strokeWidth: 3.0,
            borderColor: Colors.black.withAlpha(80),
            borderStrokeWidth: 0.8,
          ),
        );
      }
    }

    return rings;
  }

  Map<String, dynamic>? _pickWaterLevelReport(List<Map<String, dynamic>> reports) {
    if (reports.isEmpty) return null;

    final withLevels = reports
        .where((r) => _readWaterLevelCm(r) > 0)
        .toList();
    if (withLevels.isNotEmpty) {
      withLevels.sort((a, b) => _readWaterLevelCm(b).compareTo(_readWaterLevelCm(a)));
      return withLevels.first;
    }

    final impassable = reports.firstWhere(
      (r) => (r['admin_decision'] ?? '').toString() == 'Impassable',
      orElse: () => reports.first,
    );
    return impassable;
  }

  double _readWaterLevelCm(Map<String, dynamic> report) {
    const keys = ['water_level_cm', 'water_level', 'depth_cm', 'flood_depth_cm'];
    for (final key in keys) {
      final value = report[key];
      if (value is num) return value.toDouble();
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return 0;
  }

  void _showReportDetails(Map<String, dynamic> report) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Color(0xFF2D3848),
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (report['image_url'] != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: Image.network(
                  report['image_url'],
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            const SizedBox(height: 15),
            Text(
              report['location_name'] ?? "Flood Report",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            _buildDetailRow(
              Icons.comment,
              "Note",
              report['user_comments'] ?? "No description.",
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF00FBFF), size: 20),
          const SizedBox(width: 12),
          Text(
            "$label: ",
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getDecisionColor(String? decision) {
    if (decision == 'Impassable') return Colors.red;
    if (decision == 'Risky') return Colors.orange;
    return Colors.transparent;
  }

  // Search destinations with Mapbox when a token is provided; otherwise use OSM.
  Future<List<Map<String, dynamic>>> _getSearchSuggestions(String query) async {
    if (query.length < 3) return [];

    try {
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
          headers: const {
            'User-Agent': 'floote-app/1.0 (flutter_map_search)',
          },
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

  Future<void> _fastTrackLocation() async {
    if (_useFixedCurrentLocation) {
      if (mounted) {
        setState(() => _currentPCPos = _cituLocation);
      }
      _mapController.move(_cituLocation, 15.0);
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    Position? lastPos = await Geolocator.getLastKnownPosition();
    if (lastPos != null && mounted) {
      setState(
        () => _currentPCPos = LatLng(lastPos.latitude, lastPos.longitude),
      );
      _mapController.move(_currentPCPos!, 15.0);
    }
    _initLocationTracking();
  }

  void _animatedMapMove(LatLng destLocation, double destZoom) {
    final latTween = Tween<double>(
      begin: _mapController.camera.center.latitude,
      end: destLocation.latitude,
    );
    final lngTween = Tween<double>(
      begin: _mapController.camera.center.longitude,
      end: destLocation.longitude,
    );
    final zoomTween = Tween<double>(
      begin: _mapController.camera.zoom,
      end: destZoom,
    );
    final controller = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    final animation = CurvedAnimation(
      parent: controller,
      curve: Curves.fastOutSlowIn,
    );
    controller.addListener(
      () => _mapController.move(
        LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)),
        zoomTween.evaluate(animation),
      ),
    );
    animation.addStatusListener((status) {
      if (status == AnimationStatus.completed) controller.dispose();
    });
    controller.forward();
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
          _mapController.move(_currentPCPos!, _mapController.camera.zoom);
        }
      }
    });
  }

  Widget _buildSOSButton() {
    return Positioned(
      bottom: _pathIsBlocked ? 78 : 28,
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
    return Positioned(
      bottom: _pathIsBlocked ? 170 : 125,
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
    return Positioned(
      bottom: _pathIsBlocked ? 170 : 125,
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
                final currentZoom = _mapController.camera.zoom;
                final targetZoom = (currentZoom + 1.0).clamp(3.0, 19.0);
                _mapController.move(_mapController.camera.center, targetZoom);
              },
            ),
            Container(height: 1, width: 38, color: Colors.white24),
            IconButton(
              tooltip: 'Zoom out',
              icon: const Icon(Icons.remove, color: Colors.white),
              onPressed: () {
                final currentZoom = _mapController.camera.zoom;
                final targetZoom = (currentZoom - 1.0).clamp(3.0, 19.0);
                _mapController.move(_mapController.camera.center, targetZoom);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101A24),
        border: Border(top: BorderSide(color: Colors.white.withAlpha(26))),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 18)],
      ),
      child: BottomNavigationBar(
        backgroundColor: const Color(0xFF101A24),
        elevation: 0,
        selectedItemColor: _accentColor,
        unselectedItemColor: Colors.blueGrey.shade300,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.explore), label: "Map"),
          BottomNavigationBarItem(
            icon: Icon(Icons.notifications),
            label: "Alerts",
          ),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: "Profile"),
        ],
      ),
    );
  }
}
