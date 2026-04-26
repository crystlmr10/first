import 'dart:async';

import 'package:first/utils/sensor_reading_format.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart' as gnav;
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum SensorConnectionStatus { online, offline }

class SensorNodeStatus {
  final String locationName;
  final String municipality;
  final String barangay;
  final SensorConnectionStatus loraStatus;
  final int? rssiDbm;
  final double waterLevelCm;

  /// Null when the row has no battery column or value (avoid showing a fake 0%).
  final int? batteryPercent;
  final String sensorId;
  final DateTime lastSeen;
  final LatLng position;

  const SensorNodeStatus({
    required this.locationName,
    required this.municipality,
    required this.barangay,
    required this.loraStatus,
    required this.rssiDbm,
    required this.waterLevelCm,
    required this.batteryPercent,
    required this.sensorId,
    required this.lastSeen,
    required this.position,
  });
}

class RescuerSensorNetworkPage extends StatefulWidget {
  const RescuerSensorNetworkPage({super.key});

  @override
  State<RescuerSensorNetworkPage> createState() =>
      _RescuerSensorNetworkPageState();
}

class _RescuerSensorNetworkPageState extends State<RescuerSensorNetworkPage> {
  String? _selectedSensorId;
  LatLng _mapCenter = const LatLng(10.2644, 123.8503);
  double _mapZoom = 13;
  final MapController _mapController = MapController();
  bool _androidNavMapReady = false;
  String? _androidNavMapError;
  static const String _darkTileUrl =
      'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
  bool get _useNavigationMapLayer =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    unawaited(_prepareAndroidNavigationMapLayer());
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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _androidNavMapError = 'Navigation map failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FA),
      appBar: AppBar(
        title: const Text(
          'Sensor Network',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: const Color(0xFF101A24),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: Supabase.instance.client
            .from('sensors')
            .stream(primaryKey: ['id']),
        builder: (context, snapshot) {
          final sensorRows = snapshot.data ?? const <Map<String, dynamic>>[];
          final nodes = _parseNodes(sensorRows);
          if (_selectedSensorId == null && nodes.isNotEmpty) {
            _selectedSensorId = nodes.first.sensorId;
          }
          return _buildSensorNetworkTab(nodes);
        },
      ),
    );
  }

  Widget _buildSensorNetworkTab(List<SensorNodeStatus> nodes) {
    if (nodes.isEmpty) {
      return const Center(
        child: Text(
          'No sensor records found in Supabase.',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      );
    }

    final selected = nodes.firstWhere(
      (n) => n.sensorId == _selectedSensorId,
      orElse: () => nodes.first,
    );

    final total = nodes.length;
    final online = nodes
        .where((n) => n.loraStatus == SensorConnectionStatus.online)
        .length;
    final offline = total - online;
    final lowSignal = nodes.where((n) => (n.rssiDbm ?? 0) <= -90).length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _summaryCard('Total Sensors', '$total', Icons.sensors, Colors.blue),
            _summaryCard('Online', '$online', Icons.wifi, Colors.green),
            _summaryCard(
              'Offline',
              '$offline',
              Icons.wifi_off,
              Colors.redAccent,
            ),
            _summaryCard(
              'Low Signal',
              '$lowSignal',
              Icons.network_wifi_1_bar,
              Colors.orange,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          height: 260,
          decoration: _cardDecoration(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: _useNavigationMapLayer
                ? _buildAndroidNavigationMap(nodes)
                : FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _mapCenter,
                      initialZoom: _mapZoom,
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
                      MarkerLayer(
                        markers: nodes
                            .map(
                              (n) => Marker(
                                point: n.position,
                                width: 38,
                                height: 38,
                                child: GestureDetector(
                                  onTap: () => setState(
                                    () => _selectedSensorId = n.sensorId,
                                  ),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: n.loraStatus ==
                                              SensorConnectionStatus.online
                                          ? Colors.green
                                          : Colors.redAccent,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 1.8,
                                      ),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black45,
                                          blurRadius: 7,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.sensors,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 14),
        Container(
          decoration: _cardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(14, 14, 14, 8),
                child: Text(
                  'Sensor Network',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                ),
              ),
              const Divider(height: 1),
              ...nodes.map((node) {
                final isSelected = node.sensorId == selected.sensorId;
                return ListTile(
                  onTap: () =>
                      setState(() => _selectedSensorId = node.sensorId),
                  leading: Icon(
                    node.loraStatus == SensorConnectionStatus.online
                        ? Icons.check_circle
                        : Icons.error,
                    color: node.loraStatus == SensorConnectionStatus.online
                        ? Colors.green
                        : Colors.redAccent,
                  ),
                  title: Text(node.locationName),
                  subtitle: Text(
                    'Water: ${formatSensorReading(node.waterLevelCm)} cm • RSSI: ${node.rssiDbm?.toString() ?? 'N/A'} • Battery: ${node.batteryPercent != null ? '${node.batteryPercent}%' : 'N/A'}',
                  ),
                  trailing: isSelected ? const Icon(Icons.chevron_right) : null,
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAndroidNavigationMap(List<SensorNodeStatus> nodes) {
    if (!_androidNavMapReady) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _androidNavMapError ?? 'Preparing Navigation SDK map...',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      );
    }
    return Stack(
      children: [
        gnav.GoogleMapsMapView(
          onViewCreated: (controller) {
            unawaited(() async {
              try {
                await controller.setMyLocationEnabled(false);
                await controller.setMapType(mapType: gnav.MapType.normal);
                await controller.setMapColorScheme(gnav.MapColorScheme.light);
                await controller.setMapStyle('[]');
                await Future<void>.delayed(const Duration(milliseconds: 700));
                await controller.setMapType(mapType: gnav.MapType.normal);
                await controller.setMapColorScheme(gnav.MapColorScheme.light);
                await controller.setMapStyle('[]');
              } catch (e) {
                debugPrint('sensor map style apply failed: $e');
              }
            }());
          },
          initialMapType: gnav.MapType.normal,
          initialMapColorScheme: gnav.MapColorScheme.light,
          initialCameraPosition: gnav.CameraPosition(
            target: gnav.LatLng(
              latitude: _mapCenter.latitude,
              longitude: _mapCenter.longitude,
            ),
            zoom: _mapZoom,
          ),
        ),
        Positioned(
          left: 10,
          top: 10,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xC6111A24),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                '${nodes.length} sensors listed below',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _summaryCard(String title, String value, IconData icon, Color color) {
    return SizedBox(
      width: 170,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: _cardDecoration(borderColor: color.withAlpha(100)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              value,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration _cardDecoration({Color? borderColor}) {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: borderColor ?? Colors.black.withAlpha(12)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x14000000),
          blurRadius: 12,
          offset: Offset(0, 6),
        ),
      ],
    );
  }

  List<SensorNodeStatus> _parseNodes(List<Map<String, dynamic>> rows) {
    return rows.map((r) {
      final status = (r['status'] ?? '').toString().toLowerCase();
      final isOffline = status == 'offline';
      final lastUpdated =
          DateTime.tryParse((r['last_updated'] ?? '').toString()) ??
          DateTime.now();
      return SensorNodeStatus(
        locationName: (r['location_name'] ?? 'Unknown Location').toString(),
        municipality: (r['municipality'] ?? '').toString(),
        barangay: (r['barangay'] ?? '').toString(),
        loraStatus: isOffline
            ? SensorConnectionStatus.offline
            : SensorConnectionStatus.online,
        rssiDbm: _asInt(r['rssi_dbm']),
        waterLevelCm: _asDouble(r['water_level_cm']),
        batteryPercent: _asInt(r['battery_percent'] ?? r['battery_level']),
        sensorId: (r['sensor_id'] ?? (r['id'] ?? '')).toString(),
        lastSeen: lastUpdated.toLocal(),
        position: LatLng(_asDouble(r['latitude']), _asDouble(r['longitude'])),
      );
    }).toList();
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
