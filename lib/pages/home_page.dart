import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'emergency_page.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

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

  late final AnimationController _pulseController;
  late final AnimationController _sosController;
  bool _isAutoCentering = false;
  bool _isRerouting = false;
  bool _pathIsBlocked = false;

  LatLng? _currentPCPos;
  double _currentHeading = 0.0;

  List<LatLng> _routePoints = [];
  LatLng? _destinationPos;

  // MAPBOX CREDENTIALS
  final String mapboxToken = dotenv.env['MAPBOX_TOKEN'] ?? "";
  final String mapboxStyleId = "mapbox/streets-v12";

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

  // --- 1. DETECT IF CURRENT PATH HAS HAZARDS ---
  void _checkRouteForFloods(List<Map<String, dynamic>> reports) {
    if (_routePoints.isEmpty || _destinationPos == null || _isRerouting) return;

    const Distance distance = Distance();
    bool hazardFound = false;

    for (var point in _routePoints) {
      for (var report in reports) {
        if (report['admin_decision'] == 'Impassable') {
          double d = distance.as(
            LengthUnit.Meter,
            point,
            LatLng(report['latitude'], report['longitude']),
          );
          if (d < 150) {
            hazardFound = true;
            break;
          }
        }
      }
    }

    if (hazardFound != _pathIsBlocked) {
      setState(() => _pathIsBlocked = hazardFound);
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

  // --- 3. PYTHON A* ALTERNATE ROUTE ---
  Future<void> _getSafeAStarRoute(
    List<Map<String, dynamic>> verifiedReports,
  ) async {
    if (_currentPCPos == null || _destinationPos == null) return;

    setState(() => _isRerouting = true);

    final blockedNodes = verifiedReports
        .where((r) => r['admin_decision'] == 'Impassable')
        .map((r) => {"lat": r['latitude'], "lng": r['longitude']})
        .toList();

    // UPDATE TO YOUR CURRENT IP: 172.20.10.3
    const String laptopIp = "172.20.10.3";
    const String pythonServerUrl = 'http://$laptopIp:5000/astar_safe_route';

    try {
      final response = await http.post(
        Uri.parse(pythonServerUrl),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "start": [_currentPCPos!.latitude, _currentPCPos!.longitude],
          "end": [_destinationPos!.latitude, _destinationPos!.longitude],
          "blocked_nodes": blockedNodes,
        }),
      );

      if (response.statusCode == 200 && mounted) {
        final data = json.decode(response.body);
        if (data['status'] == 'success') {
          final List coords = data['points'];
          setState(() {
            _routePoints = coords.map((c) => LatLng(c[0], c[1])).toList();
            _isRerouting = false;
            _pathIsBlocked = false;
          });
        } else {
          setState(() => _isRerouting = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(data['message'] ?? "No path found"),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isRerouting = false);
      debugPrint("A* Connection Error: $e");
    }
  }

  void _clearRoute() {
    setState(() {
      _routePoints = [];
      _destinationPos = null;
      _pathIsBlocked = false;
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
              final verifiedReports = allReports
                  .where(
                    (r) =>
                        r['admin_decision'] == 'Impassable' ||
                        r['admin_decision'] == 'Risky',
                  )
                  .toList();

              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _checkRouteForFloods(verifiedReports),
              );

              return FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter:
                      _currentPCPos ?? const LatLng(10.2685, 123.8402),
                  initialZoom: 15.0,
                  onPositionChanged: (pos, hasGesture) {
                    if (hasGesture && _isAutoCentering) {
                      setState(() => _isAutoCentering = false);
                    }
                  },
                ),
                children: [
                  // MAPBOX TILE LAYER
                  TileLayer(
                    urlTemplate:
                        'https://api.mapbox.com/styles/v1/$mapboxStyleId/tiles/256/{z}/{x}/{y}@2x?access_token=$mapboxToken',
                    additionalOptions: {'accessToken': mapboxToken},
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
                    ],
                  ),

                  MarkerLayer(
                    markers: [
                      ...verifiedReports.map(
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

                  // REQUIRED MAPBOX ATTRIBUTION
                  RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution(
                        'Mapbox',
                        onTap: () => debugPrint('Mapbox source tapped'),
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
          _buildSOSButton(),
          _buildFollowToggle(),

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
                final reports = List<Map<String, dynamic>>.from(response);
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
    return IgnorePointer(
      child: Positioned.fill(
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
        ? "Hazard on route"
        : "Route looks clear";
    final statusColor = _pathIsBlocked ? _dangerColor : _accentColor;

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

  // --- UPDATED MAPBOX SEARCH LOGIC ---
  Future<List<Map<String, dynamic>>> _getSearchSuggestions(String query) async {
    if (query.length < 3) return [];

    // Using Mapbox Geocoding API for better Cebu street coverage
    final String url =
        'https://api.mapbox.com/geocoding/v5/mapbox.places/$query.json?'
        'access_token=$mapboxToken&'
        'proximity=${_currentPCPos?.longitude},${_currentPCPos?.latitude}&' // Prioritizes nearby results
        'bbox=123.75,10.22,124.0,10.45&' // Focus strictly on Cebu area
        'country=ph&limit=10';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List features = data['features'];

        return features
            .map(
              (f) => {
                'display_name': f['place_name'],
                'lat': f['geometry']['coordinates'][1],
                'lon': f['geometry']['coordinates'][0],
              },
            )
            .toList();
      }
    } catch (e) {
      debugPrint("Mapbox Search Error: $e");
    }
    return [];
  }

  Future<void> _fastTrackLocation() async {
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
