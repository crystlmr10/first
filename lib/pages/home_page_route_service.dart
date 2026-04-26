part of 'home_page.dart';

class _HomePageRouteService {
  static const bool _useGoogleRouting = bool.fromEnvironment(
    'USE_GOOGLE_ROUTING',
    defaultValue: true,
  );
  static const bool _allowLegacyRoutingFallback = bool.fromEnvironment(
    'ALLOW_LEGACY_ROUTING_FALLBACK',
    defaultValue: true,
  );
  static const bool _routingDebug = bool.fromEnvironment(
    'ROUTING_DEBUG',
    defaultValue: false,
  );
  static const String _googleRoutesApiKey = String.fromEnvironment(
    'GOOGLE_MAPS_WEB_SERVICES_API_KEY',
    defaultValue: '',
  );

  static final Map<String, List<LatLng>> _routeCache = <String, List<LatLng>>{};
  static final Map<String, LatLng> _snapCache = <String, LatLng>{};

  /// Long-lived client so TCP connections can be reused (Directions, Roads, OSRM).
  static final http.Client _routingHttpClient = http.Client();

  static Future<void> getSafeAStarRoute(
    _HomePageState state,
    List<Map<String, dynamic>> verifiedReports,
  ) async {
    if (state._currentPCPos == null || state._destinationPos == null) return;

    state._setReroutingState(true);

    debugPrint('[routing-diag] useGoogle=$_useGoogleRouting '
        'legacyFallback=$_allowLegacyRoutingFallback '
        'debug=$_routingDebug '
        'apiKeyPresent=${_googleRoutesApiKey.isNotEmpty} '
        'apiKeyLen=${_googleRoutesApiKey.length}');

    const String apiUrlOverride = String.fromEnvironment('ROUTING_API_URL');
    final String apiUrl = apiUrlOverride.isNotEmpty
        ? apiUrlOverride
        : (kIsWeb
              ? 'http://127.0.0.1:8000/route'
              : 'http://10.0.2.2:8000/route');

    final List<LatLng> seedPoints = [state._currentPCPos!];
    if (state._routePoints.length > 2) {
      final step = (state._routePoints.length / 24).ceil().clamp(1, 10);
      for (int i = step; i < state._routePoints.length - 1; i += step) {
        seedPoints.add(state._routePoints[i]);
      }
    }
    seedPoints.add(state._destinationPos!);

    final hazardPoints = verifiedReports
        .where(
          (r) =>
              (r['admin_decision'] ?? '').toString().trim().toLowerCase() ==
              'impassable',
        )
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
      {'maxLane': 3, 'laneStepMeters': 250.0},
      {'maxLane': 4, 'laneStepMeters': 350.0},
      {'maxLane': 5, 'laneStepMeters': 500.0},
    ];

    String lastError = "No safe route found";
    bool connected = false;

    for (int attempt = 0; attempt < attemptConfigs.length; attempt++) {
      final cfg = attemptConfigs[attempt];
      final payload = buildDetourPayload(
        seedPoints,
        maxLane: cfg['maxLane'] as int,
        laneStepMeters: cfg['laneStepMeters'] as double,
      );

      try {
        final response = await _routingHttpClient.post(
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
        debugPrint('[routing-diag] FastAPI response status=$status');
        if (status != 'safe' && status != 'rerouted') {
          lastError = (data['message'] ?? "No safe route found").toString();
          debugPrint('[routing-diag] FastAPI rejected: $lastError');
          continue;
        }

        final List coords = (data['polyline'] ?? []) as List;
        if (coords.isEmpty) {
          lastError = "Routing service returned empty polyline.";
          debugPrint('[routing-diag] FastAPI returned empty polyline');
          continue;
        }
        debugPrint('[routing-diag] FastAPI polyline has ${coords.length} coords');

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

        final shapedPolyline = await shapePolylineOnRoads(
          state,
          backendPolyline,
          hazardPoints,
        );
        _logRouteQuality('shapedPolyline', shapedPolyline);

        if (shapedPolyline.isEmpty) {
          debugPrint('[routing-diag] shapePolylineOnRoads returned empty');
          lastError = "No road-following reroute found.";
          continue;
        }

        if (routeIntersectsHazards(shapedPolyline, hazardPoints, 150.0)) {
          final minDist = _minHazardDistance(shapedPolyline, hazardPoints);
          debugPrint('[routing-diag] shaped route too close: '
              'minHazardDist=${minDist.toStringAsFixed(1)}m');
          lastError = "Road route passes within 150m of flood zone.";
          continue;
        }

        final cleaned = removeDeadEndLoops(state, shapedPolyline);
        _logRouteQuality('cleanedPolyline', cleaned);
        if (cleaned.length < 2) {
          lastError = "No road-following reroute found.";
          continue;
        }

        state._applyRerouteSuccess(cleaned);
        return;
      } catch (e) {
        debugPrint("FastAPI route error (attempt ${attempt + 1}): $e");
        lastError = "Cannot connect to routing backend.";
        break;
      }
    }

    final bypassRoute = await shapeViaBypassCorridor(
      state,
      state._currentPCPos!,
      state._destinationPos!,
      hazardPoints,
    );
    if (bypassRoute.isNotEmpty) {
      state._applyRerouteSuccess(removeDeadEndLoops(state, bypassRoute));
      return;
    }

    state._showRerouteFailure(lastError, connected: connected);
  }

  static double _minHazardDistance(List<LatLng> route, List<LatLng> hazards) {
    if (route.isEmpty || hazards.isEmpty) return double.infinity;
    const Distance dist = Distance();
    double minDist = double.infinity;
    for (final p in route) {
      for (final hz in hazards) {
        final d = dist.as(LengthUnit.Meter, p, hz);
        if (d < minDist) minDist = d;
      }
    }
    return minDist;
  }

  static void _logRouteQuality(String label, List<LatLng> points) {
    if (!_routingDebug || points.length < 2) return;
    const Distance dist = Distance();
    double total = 0;
    double maxSegment = 0;
    int maxIndex = 0;
    for (int i = 0; i < points.length - 1; i++) {
      final segment = dist.as(LengthUnit.Meter, points[i], points[i + 1]);
      total += segment;
      if (segment > maxSegment) {
        maxSegment = segment;
        maxIndex = i;
      }
    }
    debugPrint(
      '[route-quality] $label points=${points.length} total_m=${total.toStringAsFixed(1)} '
      'max_seg_m=${maxSegment.toStringAsFixed(1)} idx=$maxIndex '
      'from=${points[maxIndex].latitude.toStringAsFixed(6)},${points[maxIndex].longitude.toStringAsFixed(6)} '
      'to=${points[maxIndex + 1].latitude.toStringAsFixed(6)},${points[maxIndex + 1].longitude.toStringAsFixed(6)}',
    );
  }

  static Map<String, dynamic> buildDetourPayload(
    List<LatLng> seedPoints, {
    required int maxLane,
    required double laneStepMeters,
  }) {
    return FloodRouteService.buildDetourPayload(
      seedPoints,
      hazardReports: const [],
      maxLane: maxLane,
      laneStepMeters: laneStepMeters,
    );
  }

  static String _coordKey(LatLng p) {
    return '${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)}';
  }

  static String _routeKey(List<LatLng> points) {
    if (points.isEmpty) return '';
    final sb = StringBuffer(_coordKey(points.first));
    for (int i = 1; i < points.length; i++) {
      sb.write('>');
      sb.write(_coordKey(points[i]));
    }
    return sb.toString();
  }

  static String _googleRoutingKey() {
    return _googleRoutesApiKey;
  }

  static String _hazardKey(List<LatLng> hazards) {
    if (hazards.isEmpty) return '';
    final keys = hazards.map(_coordKey).toList()..sort();
    return keys.join('|');
  }

  static Future<List<LatLng>> _requestGoogleRoute(
    List<LatLng> points, {
    List<LatLng>? hazardPoints,
  }) async {
    if (points.length < 2) return points;
    final hazardKey = (hazardPoints != null && hazardPoints.isNotEmpty)
        ? '|hz:${_hazardKey(hazardPoints)}'
        : '';
    final key = '${_routeKey(points)}$hazardKey';
    final cached = _routeCache[key];
    if (cached != null) return cached;

    final apiKey = _googleRoutingKey();
    if (apiKey.isEmpty) {
      debugPrint('[routing-diag] Google Routes API key is EMPTY – '
          'cannot call Google. Check --dart-define=GOOGLE_MAPS_WEB_SERVICES_API_KEY');
      return [];
    }

    final uri = Uri.https(
      'routes.googleapis.com',
      '/directions/v2:computeRoutes',
    );
    final candidateSets = <List<LatLng>>[
      points,
      if (points.length > 12) _thinRouteWaypoints(points, 12),
      if (points.length > 6) _thinRouteWaypoints(points, 6),
      [points.first, points.last],
    ];

    for (final routePoints in candidateSets) {
      final uniqueKey = '${_routeKey(routePoints)}$hazardKey';
      final fromCache = _routeCache[uniqueKey];
      if (fromCache != null) return fromCache;

      final origin = routePoints.first;
      final destination = routePoints.last;
      final intermediates = routePoints.length > 2
          ? routePoints
                .sublist(1, routePoints.length - 1)
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
        'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
        // Alternatives help pick a hazard-safe leg; otherwise use Google's
        // primary route only to avoid odd parking-lot shortcuts globally.
        'computeAlternativeRoutes':
            hazardPoints != null && hazardPoints.isNotEmpty,
        'polylineQuality': 'HIGH_QUALITY',
        'polylineEncoding': 'ENCODED_POLYLINE',
        if (intermediates.isNotEmpty) 'intermediates': intermediates,
      };

      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          final response = await _routingHttpClient.post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'X-Goog-Api-Key': apiKey,
              'X-Goog-FieldMask': 'routes.polyline.encodedPolyline,routes.distanceMeters',
            },
            body: json.encode(body),
          );
          if (response.statusCode != 200) {
            if (_routingDebug) {
              debugPrint(
                'Google route error ${response.statusCode}: ${response.body}',
              );
            }
            if (!_routingDebug) {
              debugPrint('Google route error ${response.statusCode}');
            }
            continue;
          }
          final data = json.decode(response.body) as Map<String, dynamic>;
          final routes = data['routes'];
          if (routes is! List || routes.isEmpty) {
            if (_routingDebug) {
              debugPrint(
                'Google route empty for waypointCount=${routePoints.length}',
              );
            }
            if (!_routingDebug) {
              debugPrint(
                'Google route empty for waypointCount=${routePoints.length}',
              );
            }
            continue;
          }
          List<LatLng> bestRoute = const <LatLng>[];
          double bestFitness = double.infinity;
          double bestClearance = -1.0;
          bool bestIsSafe = false;
          for (final route in routes) {
            if (route is! Map) continue;
            final encoded = (route['polyline'] as Map?)?['encodedPolyline']
                ?.toString();
            if (encoded == null || encoded.isEmpty) continue;
            final decoded = _decodePolyline(encoded);
            if (decoded.length < 2) continue;
            final fitness = _googleRouteFitness(decoded);
            if (hazardPoints == null || hazardPoints.isEmpty) {
              if (fitness < bestFitness) {
                bestFitness = fitness;
                bestRoute = decoded;
              }
              continue;
            }

            final clearance = _minHazardDistance(decoded, hazardPoints);
            final isSafe = clearance >= 150.0;
            if (isSafe && !bestIsSafe) {
              bestRoute = decoded;
              bestFitness = fitness;
              bestClearance = clearance;
              bestIsSafe = true;
              continue;
            }
            if (isSafe && bestIsSafe) {
              if (fitness < bestFitness ||
                  (fitness == bestFitness && clearance > bestClearance)) {
                bestRoute = decoded;
                bestFitness = fitness;
                bestClearance = clearance;
              }
              continue;
            }
            if (!isSafe && !bestIsSafe) {
              if (clearance > bestClearance ||
                  (clearance == bestClearance && fitness < bestFitness)) {
                bestRoute = decoded;
                bestFitness = fitness;
                bestClearance = clearance;
              }
            }
          }
          if (bestRoute.length >= 2) {
            _routeCache[uniqueKey] = bestRoute;
            _routeCache[key] = bestRoute;
            if (_routeCache.length > 180) {
              _routeCache.remove(_routeCache.keys.first);
            }
            return bestRoute;
          }
        } catch (e) {
          if (_routingDebug) debugPrint('Google route request failed: $e');
        }
        await Future.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
    return [];
  }

  static List<LatLng> _thinRouteWaypoints(List<LatLng> points, int maxPoints) {
    if (points.length <= maxPoints) return points;
    final out = <LatLng>[points.first];
    final middle = points.sublist(1, points.length - 1);
    final takeMiddle = (maxPoints - 2).clamp(1, middle.length);
    final step = (middle.length / takeMiddle).ceil().clamp(1, middle.length);
    for (
      int i = 0;
      i < middle.length && out.length < maxPoints - 1;
      i += step
    ) {
      out.add(middle[i]);
    }
    out.add(points.last);
    return out;
  }

  static List<LatLng> _compressGuidancePoints(
    List<LatLng> points, {
    int maxPoints = 6,
    double minSpacingMeters = 80.0,
  }) {
    if (points.length <= 2) return points;
    const Distance dist = Distance();

    final deduped = <LatLng>[points.first];
    for (int i = 1; i < points.length - 1; i++) {
      final p = points[i];
      if (dist.as(LengthUnit.Meter, deduped.last, p) >= minSpacingMeters) {
        deduped.add(p);
      }
    }
    deduped.add(points.last);

    return _thinRouteWaypoints(deduped, maxPoints);
  }

  static List<List<LatLng>> _buildGuidanceCandidates(
    List<LatLng> snappedRaw,
    List<LatLng> hazardPoints,
  ) {
    if (snappedRaw.length < 2) return const <List<LatLng>>[];
    const Distance dist = Distance();
    final start = snappedRaw.first;
    final end = snappedRaw.last;

    final compressed = _compressGuidancePoints(
      snappedRaw,
      maxPoints: 4,
      minSpacingMeters: 120.0,
    );
    final compressedLite = _compressGuidancePoints(
      snappedRaw,
      maxPoints: 3,
      minSpacingMeters: 180.0,
    );

    LatLng? safestMid;
    double safestScore = -1;
    for (int i = 1; i < snappedRaw.length - 1; i++) {
      final p = snappedRaw[i];
      final ds = dist.as(LengthUnit.Meter, start, p);
      final de = dist.as(LengthUnit.Meter, p, end);
      if (ds < 250 || de < 250) continue;
      double minHz = double.infinity;
      for (final hz in hazardPoints) {
        final d = dist.as(LengthUnit.Meter, p, hz);
        if (d < minHz) minHz = d;
      }
      if (hazardPoints.isEmpty) minHz = 999999;
      if (minHz > safestScore) {
        safestScore = minHz;
        safestMid = p;
      }
    }

    final candidates = <List<LatLng>>[
      [start, end],
      compressedLite,
      compressed,
      if (safestMid != null) [start, safestMid, end],
    ];

    final seen = <String>{};
    final unique = <List<LatLng>>[];
    for (final c in candidates) {
      if (c.length < 2) continue;
      final key = _routeKey(c);
      if (seen.add(key)) unique.add(c);
    }
    return unique;
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

  static double _routeComplexityScore(List<LatLng> points) {
    if (points.length < 2) return double.infinity;
    const Distance dist = Distance();
    double totalDistance = 0;
    double turnPenalty = 0;
    int sharpTurns = 0;

    for (int i = 0; i < points.length - 1; i++) {
      totalDistance += dist.as(LengthUnit.Meter, points[i], points[i + 1]);
    }

    for (int i = 1; i < points.length - 1; i++) {
      final b1 = dist.bearing(points[i - 1], points[i]);
      final b2 = dist.bearing(points[i], points[i + 1]);
      var delta = (b2 - b1).abs();
      if (delta > 180) delta = 360 - delta;
      if (delta > 25) {
        turnPenalty += delta;
      }
      if (delta > 60) {
        sharpTurns++;
      }
    }

    // Lower is better: shorter path, fewer bends, fewer sharp turns.
    return totalDistance + (turnPenalty * 8.0) + (sharpTurns * 220.0);
  }

  /// Long gaps between decoded polyline vertices often indicate a shortcut
  /// through non-mapped roads (lots, drives) or undersampled corners.
  static double _longPolylineEdgePenalty(List<LatLng> points) {
    if (points.length < 2) return 0;
    const Distance dist = Distance();
    double p = 0;
    for (int i = 0; i < points.length - 1; i++) {
      final d = dist.as(LengthUnit.Meter, points[i], points[i + 1]);
      if (d > 72) {
        p += (d - 72) * 4.5;
      }
      if (d > 165) {
        p += 320;
      }
    }
    return p;
  }

  /// Prefer simpler routes and penalize suspicious straight chords everywhere.
  static double _googleRouteFitness(List<LatLng> decoded) {
    return _routeComplexityScore(decoded) + _longPolylineEdgePenalty(decoded);
  }

  static Future<LatLng> _requestNearestRoad(LatLng point) async {
    final key = _coordKey(point);
    final cached = _snapCache[key];
    if (cached != null) return cached;

    final apiKey = _googleRoutingKey();
    if (apiKey.isEmpty) {
      debugPrint('[routing-diag] Roads API key is EMPTY – snap returning raw point');
      return point;
    }
    final uri = Uri.https('roads.googleapis.com', '/v1/nearestRoads', {
      'points': '${point.latitude},${point.longitude}',
      'key': apiKey,
    });
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _routingHttpClient.get(uri);
        if (response.statusCode != 200) continue;
        final data = json.decode(response.body) as Map<String, dynamic>;
        final snapped = data['snappedPoints'];
        if (snapped is! List || snapped.isEmpty) return point;
        final loc = (snapped.first as Map?)?['location'];
        if (loc is! Map) return point;
        final lat = (loc['latitude'] as num?)?.toDouble();
        final lng = (loc['longitude'] as num?)?.toDouble();
        if (lat == null || lng == null) return point;
        final resolved = LatLng(lat, lng);
        _snapCache[key] = resolved;
        if (_snapCache.length > 300) {
          _snapCache.remove(_snapCache.keys.first);
        }
        return resolved;
      } catch (_) {}
      await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
    }
    return point;
  }

  static Future<List<LatLng>> _requestLegacyOsrmRoute(
    List<LatLng> points,
  ) async {
    if (points.length < 2) return points;
    final coords = points.map((p) => '${p.longitude},${p.latitude}').join(';');
    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '$coords?overview=full&geometries=geojson',
    );
    try {
      final response = await _routingHttpClient.get(url);
      if (response.statusCode != 200) return [];
      final data = json.decode(response.body);
      final routes = data['routes'];
      if (routes is! List || routes.isEmpty) return [];
      final coordinates = routes[0]['geometry']['coordinates'];
      if (coordinates is! List || coordinates.isEmpty) return [];
      return coordinates
          .map<LatLng>(
            (c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<LatLng> _requestLegacyNearestRoad(LatLng point) async {
    final url = Uri.parse(
      'https://router.project-osrm.org/nearest/v1/driving/'
      '${point.longitude},${point.latitude}?number=1',
    );
    try {
      final response = await _routingHttpClient.get(url);
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

  static Future<List<LatLng>> _computeRoadRoute(
    List<LatLng> points, {
    List<LatLng>? hazardPoints,
  }) async {
    if (_useGoogleRouting) {
      final google = await _requestGoogleRoute(
        points,
        hazardPoints: hazardPoints,
      );
      if (google.length >= 2) return google;
      debugPrint('[routing-diag] Google route returned ${google.length} points '
          'for ${points.length} waypoints');
      if (!_allowLegacyRoutingFallback) {
        debugPrint('[routing-diag] Legacy fallback disabled – returning empty');
        return [];
      }
    }
    return _requestLegacyOsrmRoute(points);
  }

  static Future<List<LatLng>> shapePolylineOnRoads(
    _HomePageState state,
    List<LatLng> controlPoints,
    List<LatLng> hazardPoints,
  ) async {
    if (controlPoints.length < 2) return controlPoints;
    debugPrint('[routing-diag] shapePolylineOnRoads called with '
        '${controlPoints.length} control points, '
        '${hazardPoints.length} hazards');

    final reduced = <LatLng>[];
    final step = (controlPoints.length / 30).ceil().clamp(1, 4);
    for (int i = 0; i < controlPoints.length; i += step) {
      reduced.add(controlPoints[i]);
    }
    if (reduced.last != controlPoints.last) {
      reduced.add(controlPoints.last);
    }

    final snappedRaw = await Future.wait(
      reduced.map(snapToNearestRoad),
    );
    final guidanceCandidates = _useGoogleRouting
        ? _buildGuidanceCandidates(snappedRaw, hazardPoints)
        : <List<LatLng>>[snappedRaw];
    debugPrint('[routing-diag] snapped guidance points: raw=${snappedRaw.length} '
        'candidateSets=${guidanceCandidates.length}');

    List<LatLng> bestUnsafe = const <LatLng>[];
    double bestUnsafeDist = -1;
    double bestUnsafeScore = double.infinity;

    final wholeRoutes = await Future.wait(
      guidanceCandidates.map(
        (guidance) => _computeRoadRoute(
          guidance,
          hazardPoints: hazardPoints,
        ),
      ),
    );

    for (int idx = 0; idx < guidanceCandidates.length; idx++) {
      final wholeRoute = wholeRoutes[idx];
      if (wholeRoute.length < 2) continue;

      final guidance = guidanceCandidates[idx];
      final wholeDist = _minHazardDistance(wholeRoute, hazardPoints);
      final complexity = _routeComplexityScore(wholeRoute);
      debugPrint('[routing-diag] candidate#$idx guidance=${guidance.length} '
          'routePts=${wholeRoute.length} minHazardDist=${wholeDist.toStringAsFixed(1)}m '
          'complexity=${complexity.toStringAsFixed(1)}');

      if (!routeIntersectsHazards(wholeRoute, hazardPoints, 150.0)) {
        return wholeRoute;
      }

      if (wholeDist > bestUnsafeDist ||
          (wholeDist == bestUnsafeDist && complexity < bestUnsafeScore)) {
        bestUnsafe = wholeRoute;
        bestUnsafeDist = wholeDist;
        bestUnsafeScore = complexity;
      }
    }

    if (bestUnsafe.isNotEmpty) {
      debugPrint('[routing-diag] best unsafe candidate minHazardDist='
          '${bestUnsafeDist.toStringAsFixed(1)}m, trying deflection');
      final deflected = await _deflectRouteAroundHazards(
        _compressGuidancePoints(
          bestUnsafe,
          maxPoints: 4,
          minSpacingMeters: 180.0,
        ),
        hazardPoints,
      );
      if (deflected.isNotEmpty) {
        debugPrint('[routing-diag] deflected route accepted (${deflected.length} pts)');
        return deflected;
      }
    }

    final snapped = _compressGuidancePoints(
      snappedRaw,
      maxPoints: 4,
      minSpacingMeters: 120.0,
    );

    final viaWaypoint = await shapeViaSafeWaypoint(
      state, snapped, hazardPoints,
    );
    if (viaWaypoint.isNotEmpty) {
      debugPrint('[routing-diag] viaWaypoint route accepted');
      return viaWaypoint;
    }

    final direct = await shapeDirectRoadRoute(
      state, snapped.first, snapped.last, hazardPoints,
    );
    if (direct.isNotEmpty) {
      debugPrint('[routing-diag] direct road route accepted');
      return direct;
    }

    debugPrint('[routing-diag] wholeRoute failed, trying segment stitching');
    final stitched = <LatLng>[];
    bool segmentFailed = false;

    try {
      for (int i = 0; i < snapped.length - 1; i++) {
        final a = snapped[i];
        final b = snapped[i + 1];
        final segPoints = await _computeRoadRoute([a, b], hazardPoints: hazardPoints);
        if (segPoints.length < 2) {
          final d = const Distance().as(LengthUnit.Meter, a, b);
          if (d < 35 && _allowLegacyRoutingFallback) {
            final legacySeg = await _requestLegacyOsrmRoute([a, b]);
            if (legacySeg.length >= 2) {
              if (stitched.isEmpty) {
                stitched.addAll(legacySeg);
              } else {
                stitched.addAll(legacySeg.skip(1));
              }
              continue;
            }
          }
          segmentFailed = true;
          debugPrint('[routing-diag] segment $i failed (gap=${d.toStringAsFixed(0)}m)');
          break;
        }
        if (stitched.isEmpty) {
          stitched.addAll(segPoints);
        } else {
          stitched.addAll(segPoints.skip(1));
        }
      }

      if (!segmentFailed && stitched.isNotEmpty) {
        if (!routeIntersectsHazards(stitched, hazardPoints, 150.0)) {
          debugPrint('[routing-diag] stitched route safe: ${stitched.length} pts');
          return stitched;
        }
        debugPrint('[routing-diag] stitched route intersects hazards, deflecting');
        final deflected = await _deflectRouteAroundHazards(snapped, hazardPoints);
        if (deflected.isNotEmpty) return deflected;
      }

      return [];
    } catch (e) {
      debugPrint('[routing-diag] shaping error: $e');
      return [];
    }
  }

  static Future<List<LatLng>> shapeDirectRoadRoute(
    _HomePageState state,
    LatLng start,
    LatLng end,
    List<LatLng> hazards,
  ) async {
    final route = await _computeRoadRoute([start, end], hazardPoints: hazards);
    if (route.length < 2) return [];
    if (routeIntersectsHazards(route, hazards, 150.0)) return [];
    return route;
  }

  static Future<List<LatLng>> shapeViaBypassCorridor(
    _HomePageState state,
    LatLng start,
    LatLng end,
    List<LatLng> hazards,
  ) async {
    const Distance dist = Distance();
    final baseBearing = dist.bearing(start, end);
    final leftBearing = baseBearing - 90.0;
    final rightBearing = baseBearing + 90.0;

    final snappedPair = await Future.wait([
      snapToNearestRoad(start),
      snapToNearestRoad(end),
    ]);
    final snappedStart = snappedPair[0];
    final snappedEnd = snappedPair[1];

    final offsets = [300.0, 500.0, 750.0, 1000.0, 1500.0, 2000.0];
    final tPositions = [
      [0.50],
      [0.33, 0.66],
      [0.25, 0.50, 0.75],
      [0.35, 0.70],
    ];

    debugPrint('[routing-diag] bypass: trying ${offsets.length * 2 * tPositions.length} corridor configs');
    int tried = 0;
    List<LatLng> bestSafe = const <LatLng>[];
    double bestSafeScore = double.infinity;
    double bestSafeClearance = 0;
    String bestTag = '';

    for (final offset in offsets) {
      for (final side in [leftBearing, rightBearing]) {
        for (final tSet in tPositions) {
          tried++;
          final midSnaps = await Future.wait(
            tSet.map((t) {
              final basePoint = interpolateLatLng(start, end, t);
              final pushed = dist.offset(basePoint, offset, side);
              return snapToNearestRoad(pushed);
            }),
          );
          final waypoints = <LatLng>[snappedStart, ...midSnaps, snappedEnd];

          final route = await _computeRoadRoute(waypoints, hazardPoints: hazards);
          if (route.length < 2) continue;

          if (!routeIntersectsHazards(route, hazards, 150.0)) {
            final score = _routeComplexityScore(route);
            final clearance = _minHazardDistance(route, hazards);
            final tag = 'offset=${offset}m config=$tried';
            debugPrint('[routing-diag] bypass: safe candidate $tag '
                'pts=${route.length} score=${score.toStringAsFixed(1)} '
                'clearance=${clearance.toStringAsFixed(1)}m');
            if (score < bestSafeScore ||
                (score == bestSafeScore && clearance > bestSafeClearance)) {
              bestSafe = route;
              bestSafeScore = score;
              bestSafeClearance = clearance;
              bestTag = tag;
            }
          }
        }
      }
    }

    if (bestSafe.isNotEmpty) {
      debugPrint('[routing-diag] bypass: selected $bestTag '
          'score=${bestSafeScore.toStringAsFixed(1)} '
          'clearance=${bestSafeClearance.toStringAsFixed(1)}m '
          'pts=${bestSafe.length}');
      return bestSafe;
    }

    debugPrint('[routing-diag] bypass: all $tried configs failed');
    return [];
  }

  static LatLng interpolateLatLng(LatLng a, LatLng b, double t) {
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  static Future<List<LatLng>> shapeViaSafeWaypoint(
    _HomePageState state,
    List<LatLng> points,
    List<LatLng> hazards,
  ) async {
    if (points.length < 3) return [];
    const Distance dist = Distance();

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

    final route = await _computeRoadRoute([start, best, end], hazardPoints: hazards);
    if (route.length < 2) return [];
    if (routeIntersectsHazards(route, hazards, 150.0)) return [];
    return route;
  }

  /// Given a road-shaped route that violates the 150m hazard zone, identify
  /// offending hazards and re-route through deflection waypoints pushed
  /// outside the zone.  Up to [maxPasses] iterative deflections are tried.
  static Future<List<LatLng>> _deflectRouteAroundHazards(
    List<LatLng> snappedWaypoints,
    List<LatLng> hazardPoints,
  ) async {
    const Distance dist = Distance();
    const double safeRadius = 150.0;
    const double pushDistance = 250.0;
    const int maxPasses = 3;

    var waypoints = List<LatLng>.from(snappedWaypoints);

    for (int pass = 0; pass < maxPasses; pass++) {
      final route = await _computeRoadRoute(waypoints, hazardPoints: hazardPoints);
      if (route.length < 2) return [];

      final violations = <_HazardViolation>[];
      for (final hz in hazardPoints) {
        double closestDist = double.infinity;
        int closestIdx = -1;
        for (int i = 0; i < route.length; i++) {
          final d = dist.as(LengthUnit.Meter, route[i], hz);
          if (d < closestDist) {
            closestDist = d;
            closestIdx = i;
          }
        }
        if (closestDist <= safeRadius) {
          violations.add(_HazardViolation(hz, closestIdx, closestDist));
        }
      }

      if (violations.isEmpty) {
        debugPrint('[routing-diag] deflection pass $pass: safe route found '
            '(${route.length} pts)');
        return route;
      }

      debugPrint('[routing-diag] deflection pass $pass: ${violations.length} '
          'violations: ${violations.map((v) => '${v.distance.toStringAsFixed(0)}m@${v.hazard.latitude.toStringAsFixed(5)},${v.hazard.longitude.toStringAsFixed(5)}').join(' | ')}');

      final newWaypoints = List<LatLng>.from(waypoints);
      int inserted = 0;

      for (final v in violations) {
        final routePoint = route[v.routeIndex];
        final bearingFromHazard = dist.bearing(v.hazard, routePoint);
        final deflected = dist.offset(v.hazard, pushDistance, bearingFromHazard);
        final snapped = await snapToNearestRoad(deflected);

        if (dist.as(LengthUnit.Meter, snapped, v.hazard) < safeRadius) {
          final perpLeft = dist.offset(v.hazard, pushDistance, bearingFromHazard + 45);
          final perpRight = dist.offset(v.hazard, pushDistance, bearingFromHazard - 45);
          final lr = await Future.wait([
            snapToNearestRoad(perpLeft),
            snapToNearestRoad(perpRight),
          ]);
          final snappedL = lr[0];
          final snappedR = lr[1];
          final dL = dist.as(LengthUnit.Meter, snappedL, v.hazard);
          final dR = dist.as(LengthUnit.Meter, snappedR, v.hazard);
          final bestSnapped = dL > dR ? snappedL : snappedR;
          if (dist.as(LengthUnit.Meter, bestSnapped, v.hazard) >= safeRadius) {
            _insertDeflectionWaypoint(newWaypoints, bestSnapped, v.hazard, dist);
            inserted++;
            continue;
          }
        } else {
          _insertDeflectionWaypoint(newWaypoints, snapped, v.hazard, dist);
          inserted++;
          continue;
        }

        for (final angle in [90.0, -90.0, 135.0, -135.0, 180.0]) {
          final candidate = dist.offset(v.hazard, pushDistance + 50, bearingFromHazard + angle);
          final candidateSnapped = await snapToNearestRoad(candidate);
          if (dist.as(LengthUnit.Meter, candidateSnapped, v.hazard) >= safeRadius) {
            _insertDeflectionWaypoint(newWaypoints, candidateSnapped, v.hazard, dist);
            inserted++;
            break;
          }
        }
      }

      if (inserted == 0) break;
      waypoints = newWaypoints;
    }

    final finalRoute = await _computeRoadRoute(waypoints, hazardPoints: hazardPoints);
    if (finalRoute.length >= 2 &&
        !routeIntersectsHazards(finalRoute, hazardPoints, safeRadius)) {
      return finalRoute;
    }
    return [];
  }

  static void _insertDeflectionWaypoint(
    List<LatLng> waypoints,
    LatLng deflectionPoint,
    LatLng hazard,
    Distance dist,
  ) {
    int bestInsertIdx = 1;
    double bestScore = double.infinity;
    for (int i = 1; i < waypoints.length; i++) {
      final prev = waypoints[i - 1];
      final next = waypoints[i];
      final dPrev = dist.as(LengthUnit.Meter, prev, hazard);
      final dNext = dist.as(LengthUnit.Meter, next, hazard);
      final score = (dPrev + dNext) / 2;
      if (score < bestScore) {
        bestScore = score;
        bestInsertIdx = i;
      }
    }
    waypoints.insert(bestInsertIdx, deflectionPoint);
  }

  static Future<LatLng> snapToNearestRoad(LatLng point) async {
    if (_useGoogleRouting) {
      final snapped = await _requestNearestRoad(point);
      final moved =
          (snapped.latitude - point.latitude).abs() > 1e-7 ||
          (snapped.longitude - point.longitude).abs() > 1e-7;
      if (moved || !_allowLegacyRoutingFallback) return snapped;
    }
    return _requestLegacyNearestRoad(point);
  }

  static bool routeIntersectsHazards(
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

  static List<LatLng> removeDeadEndLoops(
    _HomePageState state,
    List<LatLng> points,
  ) {
    if (points.length < 3) return points;

    if (_useGoogleRouting) {
      return _lightClean(points);
    }

    const Distance dist = Distance();
    final cleaned = <LatLng>[points.first];

    for (int i = 1; i < points.length - 1; i++) {
      final prev = cleaned.last;
      final current = points[i];
      final next = points[i + 1];
      final prevToCurrent = dist.as(LengthUnit.Meter, prev, current);
      final currentToNext = dist.as(LengthUnit.Meter, current, next);
      final prevToNext = dist.as(LengthUnit.Meter, prev, next);

      final isLoopish =
          prevToCurrent < 45 && currentToNext < 45 && prevToNext < 30;
      if (!isLoopish) cleaned.add(current);
    }

    cleaned.add(points.last);
    return prunePolylineLoops(cleaned);
  }

  /// Light cleanup for Google-shaped routes: only remove consecutive
  /// near-duplicate points (< 2m apart). Google routes are already
  /// road-following so aggressive loop removal would destroy them.
  static List<LatLng> _lightClean(List<LatLng> points) {
    if (points.length < 3) return points;
    const Distance dist = Distance();
    final out = <LatLng>[points.first];
    for (int i = 1; i < points.length; i++) {
      if (dist.as(LengthUnit.Meter, out.last, points[i]) > 2.0) {
        out.add(points[i]);
      }
    }
    if (out.last != points.last) out.add(points.last);

    if (out.length < 6) return out;

    // Remove local branch loops (short out-and-back artifacts)
    // while preserving legitimate long detours.
    var changed = true;
    int guard = 0;
    while (changed && out.length > 6 && guard < 3) {
      changed = false;
      guard++;
      bool broke = false;
      for (int i = 0; i < out.length - 4; i++) {
        final jMax = (i + 24).clamp(i + 3, out.length - 2);
        for (int j = i + 3; j <= jMax; j++) {
          final crow = dist.as(LengthUnit.Meter, out[i], out[j]);
          if (crow >= 35) continue;

          double branchLength = 0;
          for (int k = i; k < j; k++) {
            branchLength += dist.as(LengthUnit.Meter, out[k], out[k + 1]);
          }

          // Only collapse when the polyline does not run much farther than the
          // chord; otherwise we replace a real road detour with a cut through
          // buildings (e.g. tight block geometry with endpoints <35m apart).
          final excess = branchLength - crow;
          if (branchLength < 380 && excess <= 52) {
            out.removeRange(i + 1, j);
            changed = true;
            broke = true;
            break;
          }
        }
        if (broke) break;
      }
    }

    // Targeted cleanup for startup loops near the current position:
    // if the early path goes out and returns close to itself, drop that
    // branch because it is usually a snap artifact.
    if (out.length > 12) {
      final earlyLimit = out.length < 90 ? out.length - 1 : 90;
      bool cut = true;
      int pass = 0;
      while (cut && pass < 3) {
        cut = false;
        pass++;
        for (int i = 0; i < earlyLimit - 6; i++) {
          final jMax = (i + 42).clamp(i + 4, earlyLimit - 1);
          for (int j = i + 4; j <= jMax; j++) {
            final crow = dist.as(LengthUnit.Meter, out[i], out[j]);
            if (crow >= 55) continue;
            double branchLength = 0;
            for (int k = i; k < j; k++) {
              branchLength += dist.as(LengthUnit.Meter, out[k], out[k + 1]);
            }
            final excess = branchLength - crow;
            if (branchLength < 520 && excess <= 70) {
              out.removeRange(i + 1, j);
              cut = true;
              break;
            }
          }
          if (cut) break;
        }
      }
    }

    // Remove tiny spike zigzags.
    if (out.length < 3) return out;
    final finalClean = <LatLng>[out.first];
    for (int i = 1; i < out.length - 1; i++) {
      final a = finalClean.last;
      final b = out[i];
      final c = out[i + 1];
      final ab = dist.as(LengthUnit.Meter, a, b);
      final bc = dist.as(LengthUnit.Meter, b, c);
      final ac = dist.as(LengthUnit.Meter, a, c);
      // Dropping b draws chord a→c; only for true micro-spikes, not 40m shortcuts
      // across lots when the road path went around a block.
      final isTinySpike =
          ab < 85 &&
          bc < 85 &&
          ac < 20 &&
          (ab + bc - ac) < 38;
      if (!isTinySpike) {
        finalClean.add(b);
      }
    }
    finalClean.add(out.last);
    return _pruneTightUTurns(_pruneSmallClosedLoops(finalClean));
  }

  /// Google sometimes returns a bulb: go out, U-turn through a lot, return near
  /// the same road. Endpoints are close but path length is large — skipped by
  /// excess-only heuristics. Use bearing reversal to detect and collapse.
  static List<LatLng> _pruneTightUTurns(List<LatLng> points) {
    if (points.length < 10) return points;
    const Distance dist = Distance();
    var out = List<LatLng>.from(points);

    for (var guard = 0; guard < 8; guard++) {
      bool removed = false;
      for (int i = 0; i < out.length - 8; i++) {
        final jMax = (i + 44).clamp(i + 7, out.length - 1);
        for (int j = i + 7; j <= jMax; j++) {
          final closure = dist.as(LengthUnit.Meter, out[i], out[j]);
          if (closure > 72) continue;

          double pathLen = 0;
          for (int k = i; k < j; k++) {
            pathLen += dist.as(LengthUnit.Meter, out[k], out[k + 1]);
          }
          if (pathLen < 115) continue;
          if (pathLen - closure < 60) continue;

          final iMid = (i + (j - i) ~/ 4).clamp(i + 1, j - 2);
          final jMid = (j - (j - i) ~/ 4).clamp(i + 2, j - 1);
          final bOut = dist.bearing(out[i], out[iMid]);
          final bIn = dist.bearing(out[jMid], out[j]);
          var rev = (bIn - bOut).abs();
          if (rev > 180) rev = 360 - rev;
          // Roughly reversed travel (U / bulb), not a gentle S-curve.
          if (rev < 88 || rev > 178) continue;

          out.removeRange(i + 1, j);
          removed = true;
          break;
        }
        if (removed) break;
      }
      if (!removed) break;
    }
    return out;
  }

  /// Removes compact closed loops that are usually routing artifacts.
  /// Keeps large detours and normal road bends intact.
  static List<LatLng> _pruneSmallClosedLoops(List<LatLng> points) {
    if (points.length < 8) return points;
    const Distance dist = Distance();
    final output = List<LatLng>.from(points);

    bool changed = true;
    int guard = 0;
    while (changed && output.length > 8 && guard < 5) {
      changed = false;
      guard++;
      bool broke = false;

      for (int i = 0; i < output.length - 6; i++) {
        final jMax = (i + 36).clamp(i + 4, output.length - 2);
        for (int j = i + 4; j <= jMax; j++) {
          final closure = dist.as(LengthUnit.Meter, output[i], output[j]);
          if (closure > 70) continue;

          double loopLength = 0;
          for (int k = i; k < j; k++) {
            loopLength += dist.as(LengthUnit.Meter, output[k], output[k + 1]);
          }
          if (loopLength < 120 || loopLength > 900) continue;

          // Compute compactness via bbox diagonal.
          double minLat = output[i].latitude;
          double maxLat = output[i].latitude;
          double minLng = output[i].longitude;
          double maxLng = output[i].longitude;
          for (int k = i + 1; k <= j; k++) {
            final p = output[k];
            if (p.latitude < minLat) minLat = p.latitude;
            if (p.latitude > maxLat) maxLat = p.latitude;
            if (p.longitude < minLng) minLng = p.longitude;
            if (p.longitude > maxLng) maxLng = p.longitude;
          }
          final diag = dist.as(
            LengthUnit.Meter,
            LatLng(minLat, minLng),
            LatLng(maxLat, maxLng),
          );
          if (diag > 195) continue;

          // Large excess normally means a real block detour; tiny closure with
          // large excess is often a U through a non-road pocket (Hippodromo-type).
          final excess = loopLength - closure;
          if (excess > 88 && closure > 38) continue;

          output.removeRange(i + 1, j);
          changed = true;
          broke = true;
          break;
        }
        if (broke) break;
      }
    }
    return output;
  }

  static List<LatLng> prunePolylineLoops(List<LatLng> points) {
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
          final crow = dist.as(LengthUnit.Meter, output[i], output[j]);
          if (crow >= 60) continue;

          double branchLength = 0;
          for (int k = i; k < j; k++) {
            branchLength += dist.as(LengthUnit.Meter, output[k], output[k + 1]);
          }

          final excess = branchLength - crow;
          if (branchLength < 700 && excess <= 75) {
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
      final isBacktrackSpike =
          ab < 120 && bc < 120 && ac < 24 && (ab + bc - ac) < 45;

      if (!isBacktrackSpike) {
        finalClean.add(b);
      }
    }
    finalClean.add(output.last);
    return finalClean;
  }
}

class _HazardViolation {
  final LatLng hazard;
  final int routeIndex;
  final double distance;
  const _HazardViolation(this.hazard, this.routeIndex, this.distance);
}
