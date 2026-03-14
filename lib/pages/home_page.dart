import 'dart:convert';
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
  bool _isAutoCentering = false;
  bool _isRerouting = false; 
  bool _pathIsBlocked = false; 

  LatLng? _currentPCPos;
  double _currentHeading = 0.0;
  
  List<LatLng> _routePoints = []; 
  LatLng? _destinationPos; 

  @override
  void initState() {
    super.initState();
    _fastTrackLocation();
  }

  // --- 1. DETECT IF CURRENT PATH HAS HAZARDS ---
  void _checkRouteForFloods(List<Map<String, dynamic>> reports) {
    if (_routePoints.isEmpty || _destinationPos == null || _isRerouting) return;
    
    const Distance distance = Distance();
    bool hazardFound = false;

    for (var point in _routePoints) {
      for (var report in reports) {
        if (report['admin_decision'] == 'Impassable') {
          double d = distance.as(LengthUnit.Meter, point, LatLng(report['latitude'], report['longitude']));
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
    final url = 'https://router.project-osrm.org/route/v1/driving/${_currentPCPos!.longitude},${_currentPCPos!.latitude};${destination.longitude},${destination.latitude}?overview=full&geometries=geojson';

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final List coords = data['routes'][0]['geometry']['coordinates'];
        setState(() {
          _routePoints = coords.map((c) => LatLng(c[1].toDouble(), c[0].toDouble())).toList();
          _pathIsBlocked = false; 
        });
        
        if (_routePoints.isNotEmpty) {
          _mapController.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(_routePoints), padding: const EdgeInsets.all(70.0)));
        }
      }
    } catch (e) {
      debugPrint("Standard Routing Error: $e");
    }
  }

  // --- 3. PYTHON A* ALTERNATE ROUTE ---
  Future<void> _getSafeAStarRoute(List<Map<String, dynamic>> verifiedReports) async {
    if (_currentPCPos == null || _destinationPos == null) return;

    setState(() => _isRerouting = true);

    final blockedNodes = verifiedReports
        .where((r) => r['admin_decision'] == 'Impassable')
        .map((r) => {"lat": r['latitude'], "lng": r['longitude']})
        .toList();

    const String laptopIp = "172.20.10.2"; 
    const String pythonServerUrl = 'http://$laptopIp:5000/astar_safe_route';

    try {
      final response = await http.post(
        Uri.parse(pythonServerUrl),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "start": [_currentPCPos!.latitude, _currentPCPos!.longitude],
          "end": [_destinationPos!.latitude, _destinationPos!.longitude],
          "blocked_nodes": blockedNodes
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
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(data['message']), backgroundColor: Colors.red));
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
      backgroundColor: const Color(0xFF1B2430),
      body: Stack(
        children: [
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: Supabase.instance.client.from('user_reports').stream(primaryKey: ['id']),
            builder: (context, reportSnapshot) {
              final allReports = reportSnapshot.data ?? [];
              final verifiedReports = allReports.where((r) => 
                r['admin_decision'] == 'Impassable' || r['admin_decision'] == 'Risky'
              ).toList();

              WidgetsBinding.instance.addPostFrameCallback((_) => _checkRouteForFloods(verifiedReports));

              return FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _currentPCPos ?? const LatLng(10.2685, 123.8402),
                  initialZoom: 15.0,
                  onPositionChanged: (pos, hasGesture) {
                    if (hasGesture && _isAutoCentering) setState(() => _isAutoCentering = false);
                  },
                ),
                children: [
                  TileLayer(urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager_labels_under/{z}/{x}/{y}{r}.png', subdomains: const ['a', 'b', 'c']),
                  PolylineLayer(polylines: [
                    Polyline(
                      points: _routePoints, 
                      color: _pathIsBlocked ? Colors.red.withAlpha(150) : const Color(0xFF00FBFF), 
                      strokeWidth: 5.0
                    )
                  ]),
                  MarkerLayer(
                    markers: [
                      ...verifiedReports.map((r) => Marker(
                        point: LatLng(r['latitude'], r['longitude']),
                        width: 45, height: 45,
                        child: GestureDetector(
                          onTap: () => _showReportDetails(r), 
                          child: Icon(Icons.warning_rounded, color: _getDecisionColor(r['admin_decision']), size: 35)
                        ),
                      )),
                      if (_destinationPos != null)
                        Marker(point: _destinationPos!, width: 40, height: 40, child: const Icon(Icons.location_on, color: Colors.red, size: 40)),
                      if (_currentPCPos != null)
                        Marker(
                          point: _currentPCPos!, width: 60, height: 60,
                          child: Transform.rotate(
                            angle: (_currentHeading * (3.14159 / 180)),
                            child: Stack(alignment: Alignment.center, children: [
                              Container(width: 45, height: 45, decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFF00FBFF).withAlpha(50))),
                              const Icon(Icons.navigation, color: Color(0xFF00FBFF), size: 40)
                            ]),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            }
          ),
          _buildTopSearchBar(),
          _buildSOSButton(),
          _buildFollowToggle(),

          // --- WARNING BAR: TRIGGERS A* ON PRESS ---
        // --- RED WARNING BAR: TRIGGERS A* ON PRESS ---
if (_pathIsBlocked)
  Positioned(
    bottom: 0, left: 0, right: 0,
    child: GestureDetector(
      onTap: () async {
        // Fetch fresh reports from Supabase to ensure we have the latest blocks
        final response = await Supabase.instance.client.from('user_reports').select();
        final List<Map<String, dynamic>> reports = List<Map<String, dynamic>>.from(response);
        
        // Pass the actual list of reports to the A* function
        _getSafeAStarRoute(reports);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 20),
        color: const Color(0xFFFF5252),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.alt_route, color: Colors.white, size: 20),
            SizedBox(width: 15),
            Text(
              "Hazard ahead! Click to get alternate route.",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ],
        ),
      ),
    ),
  ),
            
          if (_isRerouting)
            const Center(child: CircularProgressIndicator(color: Color(0xFF00FBFF))),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  // --- HELPER METHODS ---
  Widget _buildTopSearchBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Container(
          decoration: BoxDecoration(color: Colors.white.withAlpha(242), borderRadius: BorderRadius.circular(30), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 15)]),
          child: TypeAheadField<Map<String, dynamic>>(
            builder: (context, controller, focusNode) => TextField(controller: controller, focusNode: focusNode, decoration: InputDecoration(hintText: "Where to?", prefixIcon: const Icon(Icons.search, color: Color(0xFF00FBFF)), suffixIcon: _destinationPos != null ? IconButton(icon: const Icon(Icons.close, color: Colors.red), onPressed: _clearRoute) : const Icon(Icons.mic, color: Colors.grey), border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(vertical: 15))),
            suggestionsCallback: (pattern) async => await _getSearchSuggestions(pattern),
            itemBuilder: (context, suggestion) => ListTile(title: Text(suggestion['display_name'] ?? "Unknown", style: const TextStyle(fontSize: 12))),
            onSelected: (suggestion) {
              final dest = LatLng(double.parse(suggestion['lat']), double.parse(suggestion['lon']));
              setState(() { _destinationPos = dest; _isAutoCentering = false; });
              _getInitialRoute(dest); 
            },
          ),
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
        decoration: const BoxDecoration(color: Color(0xFF2D3848), borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (report['image_url'] != null)
              ClipRRect(borderRadius: BorderRadius.circular(15), child: Image.network(report['image_url'], height: 180, width: double.infinity, fit: BoxFit.cover)),
            const SizedBox(height: 15),
            Text(report['location_name'] ?? "Flood Report", style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            _buildDetailRow(Icons.comment, "Note", report['user_comments'] ?? "No description."),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(children: [Icon(icon, color: const Color(0xFF00FBFF), size: 20), const SizedBox(width: 12), Text("$label: ", style: const TextStyle(color: Colors.white70, fontSize: 14)), Expanded(child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)))]),
    );
  }

  Color _getDecisionColor(String? decision) {
    if (decision == 'Impassable') return Colors.red;
    if (decision == 'Risky') return Colors.orange;
    return Colors.transparent;
  }

  Future<List<Map<String, dynamic>>> _getSearchSuggestions(String query) async {
    if (query.length < 3) return [];
    final url = 'https://nominatim.openstreetmap.org/search?q=$query&format=json&limit=10&countrycodes=ph&viewbox=123.75,10.45,124.0,10.22&bounded=1'; 
    try {
      final response = await http.get(Uri.parse(url), headers: {'User-Agent': 'Floote_App'});
      if (response.statusCode == 200) {
        final List data = json.decode(response.body);
        return data.where((item) => item['display_name'].toString().toLowerCase().contains('cebu')).toList().cast<Map<String, dynamic>>();
      }
    } catch (e) { debugPrint("Search Error: $e"); }
    return [];
  }

  Future<void> _fastTrackLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    Position? lastPos = await Geolocator.getLastKnownPosition();
    if (lastPos != null && mounted) {
      setState(() => _currentPCPos = LatLng(lastPos.latitude, lastPos.longitude));
      _mapController.move(_currentPCPos!, 15.0);
    }
    _initLocationTracking();
  }

  void _animatedMapMove(LatLng destLocation, double destZoom) {
    final latTween = Tween<double>(begin: _mapController.camera.center.latitude, end: destLocation.latitude);
    final lngTween = Tween<double>(begin: _mapController.camera.center.longitude, end: destLocation.longitude);
    final zoomTween = Tween<double>(begin: _mapController.camera.zoom, end: destZoom);
    final controller = AnimationController(duration: const Duration(milliseconds: 1000), vsync: this);
    final animation = CurvedAnimation(parent: controller, curve: Curves.fastOutSlowIn);
    controller.addListener(() => _mapController.move(LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)), zoomTween.evaluate(animation)));
    animation.addStatusListener((status) { if (status == AnimationStatus.completed) controller.dispose(); });
    controller.forward();
  }

  Future<void> _initLocationTracking() async {
    Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 2)).listen((pos) {
      if (mounted) {
        final newPos = LatLng(pos.latitude, pos.longitude);
        const Distance distance = Distance();
        setState(() {
          _currentPCPos = newPos;
          if (_routePoints.isNotEmpty) {
            int closestIndex = 0; double minDistance = double.infinity;
            for (int i = 0; i < _routePoints.length; i++) {
              double d = distance.as(LengthUnit.Meter, newPos, _routePoints[i]);
              if (d < minDistance) { minDistance = d; closestIndex = i; }
            }
            if (minDistance < 25) {
              _currentPCPos = _routePoints[closestIndex];
              if (closestIndex < _routePoints.length - 1) {
                _currentHeading = distance.bearing(_routePoints[closestIndex], _routePoints[closestIndex + 1]);
              }
            } else { _currentHeading = pos.heading; }
          } else { _currentHeading = pos.heading; }
        });
        if (_isAutoCentering) _mapController.move(_currentPCPos!, _mapController.camera.zoom);
      }
    });
  }

  Widget _buildSOSButton() {
    return Positioned(bottom: _pathIsBlocked ? 70 : 25, right: 20, child: GestureDetector(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const EmergencyPage())), child: Container(height: 65, width: 65, decoration: BoxDecoration(color: const Color(0xFFFF3B30), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3), boxShadow: [BoxShadow(color: Colors.red.withAlpha(102), blurRadius: 15)]), child: const Icon(Icons.emergency_share, color: Colors.white, size: 30))));
  }

  Widget _buildFollowToggle() {
    return Positioned(bottom: _pathIsBlocked ? 165 : 120, left: 20, child: Column(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)), child: Text(_isAutoCentering ? "FOLLOW ON" : "FOLLOW OFF", style: const TextStyle(color: Colors.white, fontSize: 8))), const SizedBox(height: 8), FloatingActionButton(mini: true, backgroundColor: _isAutoCentering ? const Color(0xFF00FBFF) : const Color(0xFF2D3848), onPressed: () { setState(() { _isAutoCentering = !_isAutoCentering; if (_isAutoCentering && _currentPCPos != null) _animatedMapMove(_currentPCPos!, 17.0); }); }, child: Icon(_isAutoCentering ? Icons.gps_fixed : Icons.gps_not_fixed, color: _isAutoCentering ? Colors.black87 : Colors.white))]));
  }

  Widget _buildBottomNav() {
    return Container(decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)]), child: BottomNavigationBar(backgroundColor: Colors.white, elevation: 0, selectedItemColor: const Color(0xFF00FBFF), unselectedItemColor: Colors.blueGrey.shade200, items: const [BottomNavigationBarItem(icon: Icon(Icons.explore), label: "Map"), BottomNavigationBarItem(icon: Icon(Icons.notifications), label: "Alerts"), BottomNavigationBarItem(icon: Icon(Icons.person), label: "Profile")]));
  }
}