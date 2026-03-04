import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MapController _mapController = MapController();
  
  // South District Sensors
  final LatLng _tabunok = const LatLng(10.2685, 123.8402);
  final LatLng _talisay = const LatLng(10.2547, 123.8483);
  final LatLng _minglanilla = const LatLng(10.2450, 123.7960);

  LatLng? _currentPCPos;
  double _currentHeading = 0.0;

  @override
  void initState() {
    super.initState();
    _initLocationTracking();
  }

  Future<void> _initLocationTracking() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
    
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high)
    ).listen((pos) {
      if (mounted) {
        setState(() {
          _currentPCPos = LatLng(pos.latitude, pos.longitude);
          _currentHeading = pos.heading;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F4F7), 
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _tabunok, 
              initialZoom: 13.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'com.floote.app',
                retinaMode: MediaQuery.of(context).devicePixelRatio > 1.0,
              ),
              
              CircleLayer(
                circles: [
                  _buildWazeDangerCircle(_tabunok),
                  _buildWazeDangerCircle(_minglanilla),
                ],
              ),

              MarkerLayer(
                markers: [
                  _buildWazeStatusMarker(_tabunok, "Tabunok", "50cm", "IMPASSABLE", Colors.red),
                  _buildWazeStatusMarker(_talisay, "Talisay", "5cm", "SAFE", Colors.green),
                  _buildWazeStatusMarker(_minglanilla, "Minglanilla", "42cm", "IMPASSABLE", Colors.red),
                  
                  if (_currentPCPos != null)
                    Marker(
                      point: _currentPCPos!,
                      width: 80,
                      height: 80,
                      child: Transform.rotate(
                        angle: (_currentHeading * (3.14159 / 180)),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.blue.withValues(alpha: 0.2),
                              ),
                            ),
                            const Icon(
                              Icons.directions_car_filled, 
                              color: Colors.blue, 
                              size: 35
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),

          _buildTopSearchBar(),
          _buildSOSButton(),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  // --- UI COMPONENTS ---

  Widget _buildTopSearchBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(25),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15), 
                blurRadius: 20
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.my_location, color: Colors.blue, size: 20),
                title: const Text("Current Location", style: TextStyle(fontSize: 12, color: Colors.grey)),
                subtitle: Text(
                  _currentPCPos != null 
                    ? "${_currentPCPos!.latitude.toStringAsFixed(4)}, ${_currentPCPos!.longitude.toStringAsFixed(4)}"
                    : "Fetching GPS...", 
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Colors.black)
                ),
                onTap: () {
                  if (_currentPCPos != null) {
                    _mapController.move(_currentPCPos!, 15);
                  }
                },
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Divider(height: 1, thickness: 0.5),
              ),
              const ListTile(
                dense: true,
                leading: Icon(Icons.search, color: Colors.grey, size: 20),
                title: Text("Where to?", style: TextStyle(color: Colors.grey, fontSize: 14)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Marker _buildWazeStatusMarker(LatLng pos, String name, String level, String status, Color color) {
    return Marker(
      point: pos,
      width: 150, 
      height: 70,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.3), width: 2),
              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 5, offset: Offset(0, 3))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(status == "SAFE" ? Icons.check_circle : Icons.error, color: color, size: 16),
                const SizedBox(width: 5),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
                    Text("$level • $status", style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
          Icon(Icons.arrow_drop_down, color: color.withValues(alpha: 0.5), size: 20),
        ],
      ),
    );
  }

  CircleMarker _buildWazeDangerCircle(LatLng pos) {
    return CircleMarker(
      point: pos,
      color: Colors.red.withValues(alpha: 0.1),
      borderStrokeWidth: 3,
      borderColor: Colors.red.withValues(alpha: 0.3),
      useRadiusInMeter: true,
      radius: 350,
    );
  }

  Widget _buildSOSButton() {
    return Positioned(
      bottom: 25,
      right: 20,
      child: GestureDetector(
        onTap: () {},
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFD32F2F), 
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.red.withValues(alpha: 0.5), 
                blurRadius: 20, 
                spreadRadius: 3
              )
            ],
          ),
          child: const Icon(
            Icons.emergency_share, 
            color: Colors.white, 
            size: 32
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)],
      ),
      child: BottomNavigationBar(
        elevation: 0,
        backgroundColor: Colors.white,
        selectedItemColor: Colors.blue,
        unselectedItemColor: Colors.blueGrey.shade300,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.explore), label: "Map"),
          // ICON UPDATED: Changed from Icons.report_problem to Icons.notifications
          BottomNavigationBarItem(icon: Icon(Icons.notifications), label: "Notifications"),
          BottomNavigationBarItem(icon: Icon(Icons.account_circle), label: "My Floote"),
        ],
      ),
    );
  }
}