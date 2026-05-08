import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FloodRouteResult {
  const FloodRouteResult({
    required this.status,
    required this.message,
    required this.polyline,
    required this.routeNodeIds,
    this.targetMode = 'exact',
    this.proxyReason,
    this.targetPoint,
    this.victimPoint,
    this.victimOffsetMeters = 0,
  });

  final String status;
  final String message;
  final List<LatLng> polyline;
  final List<String> routeNodeIds;
  final String targetMode;
  final String? proxyReason;
  final LatLng? targetPoint;
  final LatLng? victimPoint;
  final int victimOffsetMeters;

  bool get isUsable =>
      status == 'safe' || status == 'rerouted' || status == 'best_effort';

  bool get isSafeProxyTarget => targetMode == 'safe_proxy';

  /// True when the route was vetted clear of flood hazards. False when the
  /// service had to fall back to the cleanest available road route that may
  /// still cross a reported flood (status `best_effort`).
  bool get isFloodSafe => status == 'safe' || status == 'rerouted';

  /// Navigation SDK gets ordered waypoints. The SDK computes road-level turns
  /// between these points while staying anchored to the flood-safe corridor.
  List<LatLng> get intermediatePolylineWaypoints {
    if (polyline.length <= 2) return const <LatLng>[];
    return polyline.sublist(1, polyline.length - 1);
  }
}

class FloodRouteService {
  static const String _apiUrlOverride = String.fromEnvironment('ROUTING_API_URL');
  static const String _googleApiKey = String.fromEnvironment(
    'GOOGLE_MAPS_WEB_SERVICES_API_KEY',
    defaultValue: '',
  );
  static const double _impassableRadiusMeters = 220.0;
  static const double _endpointToleranceMeters = 260.0;
  static final http.Client _http = http.Client();

  /// Avoid over-ignoring route safety checks near endpoints.
  ///
  /// A large fixed endpoint tolerance can accidentally suppress hazard checks
  /// across almost the whole path on short routes. We cap tolerance by both:
  ///  - absolute ceiling (meters), and
  ///  - fraction of total route length per endpoint.
  static double _effectiveEndpointTolerance({
    required double requestedMeters,
    required double totalRouteMeters,
  }) {
    if (requestedMeters <= 0 || totalRouteMeters <= 0) return 0.0;
    const double absoluteCapMeters = 120.0;
    const double perEndpointRouteFraction = 0.25; // max 25% each side
    final byLength = totalRouteMeters * perEndpointRouteFraction;
    return math.max(
      0.0,
      math.min(requestedMeters, math.min(absoluteCapMeters, byLength)),
    );
  }

  static String get apiUrl =>
      _apiUrlOverride.isNotEmpty
          ? _apiUrlOverride
          : (kIsWeb ? 'http://127.0.0.1:8000/route' : 'http://10.0.2.2:8000/route');

  static Future<List<Map<String, dynamic>>> fetchVerifiedHazardReports() async {
    final List<dynamic> rows = await Supabase.instance.client
        .from('user_reports')
        .select();
    return rows
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((r) {
          final decision = (r['admin_decision'] ?? '').toString().trim().toLowerCase();
          return decision == 'impassable' || decision == 'risky';
        })
        .toList();
  }

  static List<LatLng> extractHazardPoints(
    List<Map<String, dynamic>> hazardReports, {
    Set<String> decisions = const {'impassable', 'risky'},
  }) {
    final out = <LatLng>[];
    for (final report in hazardReports) {
      final decision = (report['admin_decision'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (!decisions.contains(decision)) continue;
      final lat = (report['latitude'] as num?)?.toDouble();
      final lng = (report['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      out.add(LatLng(lat, lng));
    }
    return out;
  }

  /// Returns true when the route passes within [radiusMeters] of any hazard.
  ///
  /// Set [endpointToleranceMeters] > 0 to ignore violations that occur only
  /// because the route's first/last points are themselves near a hazard
  /// (e.g. the user-reported flood is at the destination). Mid-route
  /// crossings are still flagged.
  static bool routeIntersectsHazards(
    List<LatLng> route,
    List<LatLng> hazards,
    double radiusMeters, {
    double endpointToleranceMeters = 0.0,
  }) {
    if (route.length < 2 || hazards.isEmpty) return false;
    const Distance dist = Distance();

    final cumulative = <double>[0];
    for (int i = 1; i < route.length; i++) {
      cumulative.add(
        cumulative.last + dist.as(LengthUnit.Meter, route[i - 1], route[i]),
      );
    }
    final total = cumulative.last;
    final effectiveEndpointToleranceMeters = _effectiveEndpointTolerance(
      requestedMeters: endpointToleranceMeters,
      totalRouteMeters: total,
    );

    for (int i = 0; i < route.length - 1; i++) {
      final a = route[i];
      final b = route[i + 1];
      final segmentLength = dist.as(LengthUnit.Meter, a, b);
      if (segmentLength <= 0) continue;
      final samples = (segmentLength / 20.0).ceil().clamp(1, 40);
      for (int s = 0; s <= samples; s++) {
        final t = s / samples;
        final distAlong = cumulative[i] + segmentLength * t;
        if (effectiveEndpointToleranceMeters > 0) {
          if (distAlong <= effectiveEndpointToleranceMeters) continue;
          if (total - distAlong <= effectiveEndpointToleranceMeters) continue;
        }
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

  static Future<FloodRouteResult> fetchSafestRoute({
    required LatLng origin,
    required LatLng destination,
    required List<Map<String, dynamic>> hazardReports,
    String routeMode = 'normal',
    bool isSos = false,
    LatLng? victimLocation,
  }) async {
    final seedPoints = <LatLng>[origin, destination];
    final attemptConfigs = <Map<String, dynamic>>[
      {'maxLane': 2, 'laneStepMeters': 180.0},
      {'maxLane': 3, 'laneStepMeters': 250.0},
      {'maxLane': 4, 'laneStepMeters': 350.0},
    ];

    String message = 'No safe route found.';
    for (final cfg in attemptConfigs) {
      final payload = buildDetourPayload(
        seedPoints,
        hazardReports: hazardReports,
        maxLane: cfg['maxLane'] as int,
        laneStepMeters: cfg['laneStepMeters'] as double,
        routeMode: routeMode,
        isSos: isSos,
        victimLocation: victimLocation,
      );
      try {
        final response = await _http.post(
          Uri.parse(apiUrl),
          headers: const {'Content-Type': 'application/json'},
          body: json.encode(payload),
        );
        if (response.statusCode != 200) {
          message = 'Routing API error: ${response.statusCode}';
          continue;
        }
        final dynamic raw = json.decode(response.body);
        if (raw is! Map) {
          message = 'Routing API returned invalid JSON payload.';
          continue;
        }
        final data = Map<String, dynamic>.from(raw);
        final status = (data['status'] ?? '').toString();
        final messageRaw = (data['message'] ?? '').toString();
        final routeNodes = (data['route'] is List)
            ? (data['route'] as List).map((e) => e.toString()).toList()
            : const <String>[];
        final polyline = _parsePolyline(data['polyline']);
        final targetMode = (data['target_mode'] ?? 'exact').toString();
        final proxyReason = data['proxy_reason']?.toString();
        final targetPoint = _parseLatLngPair(
          data['target_lat'],
          data['target_lng'],
        );
        final victimPoint = _parseLatLngPair(
          data['victim_lat'],
          data['victim_lng'],
        );
        final victimOffsetMeters =
            (data['victim_offset_m'] as num?)?.round() ?? 0;
        if ((status == 'safe' || status == 'rerouted') && polyline.length >= 2) {
          return FloodRouteResult(
            status: status,
            message: messageRaw.isNotEmpty ? messageRaw : 'Route ready.',
            polyline: polyline,
            routeNodeIds: routeNodes,
            targetMode: targetMode,
            proxyReason: proxyReason,
            targetPoint: targetPoint,
            victimPoint: victimPoint,
            victimOffsetMeters: victimOffsetMeters,
          );
        }
        message = messageRaw.isNotEmpty ? messageRaw : 'No safe route found.';
      } catch (e) {
        message = 'Cannot connect to routing backend.';
        break;
      }
    }
    return FloodRouteResult(
      status: 'no_route',
      message: message,
      polyline: const <LatLng>[],
      routeNodeIds: const <String>[],
    );
  }

  /// Returns a *road-following* safe route by:
  ///  1. Confirming with FastAPI that any safe path exists.
  ///  2. Calling Google Routes API directly origin -> destination.
  ///  3. If that route crosses a flood mid-trip, retrying with a deflection
  ///     waypoint placed perpendicular to the direct line, on the safer side.
  ///  4. Falling back to FastAPI's synthetic polyline if no clean road route
  ///     can be found (the SDK still road-routes between the dense waypoints).
  ///
  /// Endpoint hits (origin/destination already inside a hazard) are tolerated
  /// because the user explicitly chose that endpoint.
  static Future<FloodRouteResult> fetchRoadFollowingSafestRoute({
    required LatLng origin,
    required LatLng destination,
    required List<Map<String, dynamic>> hazardReports,
    String routeMode = 'normal',
    bool isSos = false,
    LatLng? victimLocation,
  }) async {
    final base = await fetchSafestRoute(
      origin: origin,
      destination: destination,
      hazardReports: hazardReports,
      routeMode: routeMode,
      isSos: isSos,
      victimLocation: victimLocation,
    );
    if (!base.isUsable) return base;
    final effectiveDestination = base.targetPoint ?? destination;

    final impassableHazards = extractHazardPoints(
      hazardReports,
      decisions: const {'impassable'},
    );

    if (_googleApiKey.isEmpty || impassableHazards.isEmpty) {
      // Without Google Routes API we trust FastAPI; the SDK will road-route
      // between the dense waypoints we hand it.
      return base;
    }

    final direct = await _requestGoogleRoadRoute(<LatLng>[
      origin,
      effectiveDestination,
    ]);
    debugPrint(
      'fetchRoadFollowingSafestRoute: direct route points=${direct.length}',
    );
    if (direct.length >= 2 &&
        !routeIntersectsHazards(
          direct,
          impassableHazards,
          _impassableRadiusMeters,
          endpointToleranceMeters: _endpointToleranceMeters,
        )) {
      return FloodRouteResult(
        status: 'safe',
        message: 'Road-following safe route confirmed.',
        polyline: direct,
        routeNodeIds: base.routeNodeIds,
        targetMode: base.targetMode,
        proxyReason: base.proxyReason,
        targetPoint: base.targetPoint,
        victimPoint: base.victimPoint,
        victimOffsetMeters: base.victimOffsetMeters,
      );
    }

    if (direct.length < 2) {
      debugPrint(
        'fetchRoadFollowingSafestRoute: Google Routes API returned no route, '
        'falling back to FastAPI synthetic polyline.',
      );
      return base;
    }

    // Direct route intersects a flood -> try perpendicular deflections around
    // every offending hazard, varying offset magnitude and side.
    final hazardsOnRoute = _hazardsOnRoute(direct, impassableHazards);
    debugPrint(
      'fetchRoadFollowingSafestRoute: ${hazardsOnRoute.length} hazards '
      'on direct route. Trying deflection retries.',
    );

    const offsets = <double>[350.0, 600.0, 900.0, 1300.0, 1700.0];
    const sides = <int>[1, -1];
    for (final hazard in hazardsOnRoute) {
      for (final offset in offsets) {
        for (final side in sides) {
          final waypoint = _perpendicularDeflectionWaypoint(
            origin: origin,
            destination: effectiveDestination,
            hazard: hazard,
            offsetMeters: offset,
            side: side,
          );
          final retry = await _requestGoogleRoadRoute(<LatLng>[
            origin,
            waypoint,
            effectiveDestination,
          ]);
          if (retry.length >= 2 &&
              !routeIntersectsHazards(
                retry,
                impassableHazards,
                _impassableRadiusMeters,
                endpointToleranceMeters: _endpointToleranceMeters,
              )) {
            debugPrint(
              'fetchRoadFollowingSafestRoute: deflection succeeded with '
              'offset=$offset side=$side',
            );
            return FloodRouteResult(
              status: 'safe',
              message: 'Road-following route deflected around flood zone.',
              polyline: retry,
              routeNodeIds: base.routeNodeIds,
              targetMode: base.targetMode,
              proxyReason: base.proxyReason,
              targetPoint: base.targetPoint,
              victimPoint: base.victimPoint,
              victimOffsetMeters: base.victimOffsetMeters,
            );
          }
        }
      }
    }

    // For SOS proxy-target flow, prefer the backend's verified safe-proxy
    // corridor over a best-effort route that could drift toward the victim pin.
    if (base.isSafeProxyTarget) {
      return base;
    }

    // No clean alternative exists. Return the direct Google road route as a
    // best-effort fallback so the user can still navigate, with a warning.
    debugPrint(
      'fetchRoadFollowingSafestRoute: no clean alternative; returning '
      'best-effort direct road route with warning.',
    );
    return FloodRouteResult(
      status: 'best_effort',
      message:
          'No fully safe route found. Showing best road route - it may pass '
          'near reported flood zones. Drive with caution.',
      polyline: direct,
      routeNodeIds: base.routeNodeIds,
      targetMode: base.targetMode,
      proxyReason: base.proxyReason,
      targetPoint: base.targetPoint,
      victimPoint: base.victimPoint,
      victimOffsetMeters: base.victimOffsetMeters,
    );
  }

  static LatLng? _parseLatLngPair(dynamic rawLat, dynamic rawLng) {
    final lat = rawLat is num ? rawLat.toDouble() : null;
    final lng = rawLng is num ? rawLng.toDouble() : null;
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  static List<LatLng> _hazardsOnRoute(
    List<LatLng> route,
    List<LatLng> hazards,
  ) {
    if (route.length < 2 || hazards.isEmpty) return const <LatLng>[];
    const Distance dist = Distance();

    final cumulative = <double>[0];
    for (int i = 1; i < route.length; i++) {
      cumulative.add(
        cumulative.last + dist.as(LengthUnit.Meter, route[i - 1], route[i]),
      );
    }
    final total = cumulative.last;
    final effectiveEndpointToleranceMeters = _effectiveEndpointTolerance(
      requestedMeters: _endpointToleranceMeters,
      totalRouteMeters: total,
    );

    final hits = <LatLng>{};
    for (int i = 0; i < route.length - 1; i++) {
      final a = route[i];
      final b = route[i + 1];
      final segmentLength = dist.as(LengthUnit.Meter, a, b);
      if (segmentLength <= 0) continue;
      final samples = (segmentLength / 20.0).ceil().clamp(1, 40);
      for (int s = 0; s <= samples; s++) {
        final t = s / samples;
        final distAlong = cumulative[i] + segmentLength * t;
        if (distAlong <= effectiveEndpointToleranceMeters) continue;
        if (total - distAlong <= effectiveEndpointToleranceMeters) continue;
        final sample = LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        );
        for (final hz in hazards) {
          if (dist.as(LengthUnit.Meter, sample, hz) <=
              _impassableRadiusMeters) {
            hits.add(hz);
          }
        }
      }
    }
    return hits.toList(growable: false);
  }

  /// Builds a waypoint placed [offsetMeters] perpendicular to the direct
  /// origin->destination line, on [side] (+1 = left, -1 = right), starting
  /// from the projection of [hazard] onto that line.
  static LatLng _perpendicularDeflectionWaypoint({
    required LatLng origin,
    required LatLng destination,
    required LatLng hazard,
    required double offsetMeters,
    required int side,
  }) {
    const Distance dist = Distance();
    final bearingOd = dist.bearing(origin, destination);
    final perpBearing = (bearingOd + (side >= 0 ? 90.0 : -90.0)) % 360.0;
    return dist.offset(hazard, offsetMeters, perpBearing);
  }

  static Future<List<LatLng>> _requestGoogleRoadRoute(
    List<LatLng> waypoints,
  ) async {
    if (_googleApiKey.isEmpty || waypoints.length < 2) return const <LatLng>[];
    final origin = waypoints.first;
    final destination = waypoints.last;
    final intermediates = waypoints.length > 2
        ? waypoints
              .sublist(1, waypoints.length - 1)
              .map(
                (p) => {
                  'location': {
                    'latLng': {
                      'latitude': p.latitude,
                      'longitude': p.longitude,
                    },
                  },
                },
              )
              .toList()
        : const <Map<String, dynamic>>[];

    final body = {
      'origin': {
        'location': {
          'latLng': {
            'latitude': origin.latitude,
            'longitude': origin.longitude,
          },
        },
      },
      'destination': {
        'location': {
          'latLng': {
            'latitude': destination.latitude,
            'longitude': destination.longitude,
          },
        },
      },
      'travelMode': 'DRIVE',
      'routingPreference': 'TRAFFIC_AWARE',
      'polylineEncoding': 'ENCODED_POLYLINE',
      if (intermediates.isNotEmpty) 'intermediates': intermediates,
    };

    try {
      final response = await _http.post(
        Uri.https('routes.googleapis.com', '/directions/v2:computeRoutes'),
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': _googleApiKey,
          'X-Goog-FieldMask':
              'routes.polyline.encodedPolyline,routes.distanceMeters',
        },
        body: json.encode(body),
      );
      if (response.statusCode != 200) {
        debugPrint(
          'Routes API error ${response.statusCode}: ${response.body}',
        );
        return const <LatLng>[];
      }
      final data = json.decode(response.body) as Map<String, dynamic>;
      final routes = data['routes'];
      if (routes is! List || routes.isEmpty) return const <LatLng>[];
      final encoded = (routes.first as Map?)?['polyline']?['encodedPolyline'];
      if (encoded is! String || encoded.isEmpty) return const <LatLng>[];
      return _decodePolyline(encoded);
    } catch (e) {
      debugPrint('Routes API call failed: $e');
      return const <LatLng>[];
    }
  }

  static List<LatLng> _decodePolyline(String encoded) {
    final List<LatLng> points = <LatLng>[];
    int index = 0;
    int lat = 0;
    int lng = 0;
    while (index < encoded.length) {
      int result = 0;
      int shift = 0;
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dLat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dLat;
      result = 0;
      shift = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dLng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dLng;
      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  static List<LatLng> _parsePolyline(dynamic raw) {
    if (raw is! List) return const <LatLng>[];
    return raw
        .whereType<Map>()
        .map((c) => Map<String, dynamic>.from(c))
        .where((c) => c['lat'] is num && c['lng'] is num)
        .map((c) => LatLng((c['lat'] as num).toDouble(), (c['lng'] as num).toDouble()))
        .toList();
  }

  static Map<String, dynamic> buildDetourPayload(
    List<LatLng> seedPoints, {
    required List<Map<String, dynamic>> hazardReports,
    required int maxLane,
    required double laneStepMeters,
    String routeMode = 'normal',
    bool isSos = false,
    LatLng? victimLocation,
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
      final w = dist.as(LengthUnit.Meter, fromPos, toPos);
      payloadGraph[fromId]!.add({
        'to': toId,
        'distance': w <= 0 ? 0.01 : w,
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

    for (int lane = -maxLane; lane <= maxLane; lane++) {
      for (int i = 0; i < seedPoints.length; i++) {
        final here = nodeId(lane, i);
        if (lane - 1 >= -maxLane) {
          final left = nodeId(lane - 1, i);
          addEdgeById(here, left);
          addEdgeById(left, here);
        }
        if (lane + 1 <= maxLane) {
          final right = nodeId(lane + 1, i);
          addEdgeById(here, right);
          addEdgeById(right, here);
        }
      }
    }

    final blockedNodes = <String>[];
    for (final hz in hazardReports) {
      final decision = (hz['admin_decision'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (decision != 'impassable') continue;
      final hzLat = (hz['latitude'] as num?)?.toDouble();
      final hzLng = (hz['longitude'] as num?)?.toDouble();
      if (hzLat == null || hzLng == null) continue;
      final h = LatLng(hzLat, hzLng);
      payloadNodes.forEach((id, p) {
        final pnt = LatLng(
          (p['lat'] as num).toDouble(),
          (p['lng'] as num).toDouble(),
        );
        if (dist.as(LengthUnit.Meter, pnt, h) < 150.0) blockedNodes.add(id);
      });
    }

    // Keep full candidate graph for SOS so backend can compute nearest safe
    // proxy targets even when the victim pin is inside a blocked circle.
    if (!isSos) {
      for (final b in blockedNodes.toSet()) {
        payloadGraph.remove(b);
        for (final edges in payloadGraph.values) {
          edges.removeWhere((e) => e['to'] == b);
        }
      }
    }

    final start = nodeId(0, 0);
    final end = nodeId(0, seedPoints.length - 1);
    return {
      'nodes': payloadNodes,
      'graph': payloadGraph,
      'start': start,
      'goal': end,
      'route_mode': routeMode,
      'is_sos': isSos,
      if (victimLocation != null) 'victim_lat': victimLocation.latitude,
      if (victimLocation != null) 'victim_lng': victimLocation.longitude,
    };
  }
}
