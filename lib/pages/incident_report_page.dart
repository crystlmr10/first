import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' as ll;
import 'package:supabase_flutter/supabase_flutter.dart';

class IncidentReportPage extends StatefulWidget {
  const IncidentReportPage({super.key});

  @override
  State<IncidentReportPage> createState() => _IncidentReportPageState();
}

class _IncidentReportPageState extends State<IncidentReportPage> {
  static const String _googlePlacesApiKey = String.fromEnvironment(
    'GOOGLE_PLACES_API_KEY',
    defaultValue: '',
  );
  static const String _googleGeocodingApiKey = String.fromEnvironment(
    'GOOGLE_GEOCODING_API_KEY',
    defaultValue: '',
  );
  static const bool _allowLegacyGeocodeFallback = bool.fromEnvironment(
    'ALLOW_LEGACY_GEOCODER_FALLBACK',
    defaultValue: false,
  );
  static const String _lightTileUrl =
      'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
  static const double _nearbyPreviewRadiusMeters = 220.0;
  static const double _duplicateBlockRadiusMeters = 120.0;
  // Legacy preview window kept for UI copy/history context only.
  // Duplicate blocking itself is now "active hazard only" (no time expiry).
  static const Duration _duplicateWindow = Duration(hours: 3);
  static const int _duplicateWindowMinutesUnlimited = 60 * 24 * 365 * 10;

  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  final ImagePicker _picker = ImagePicker();

  XFile? _selectedImage;
  bool _isSubmitting = false;
  bool _isDetectingLocation = true;
  bool _isLoadingNearbyReports = false;
  double? _lat;
  double? _lng;
  String? _lastResolvedLocationName;
  List<Map<String, dynamic>> _nearbyFloodReports = const [];

  @override
  void initState() {
    super.initState();
    _initLocationDetection();
  }

  Future<List<Map<String, dynamic>>> _getSearchSuggestions(String query) async {
    if (query.length < 3) return [];
    try {
      if (_googlePlacesApiKey.isNotEmpty) {
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
              'rectangle': {
                'low': {'latitude': 10.22, 'longitude': 123.75},
                'high': {'latitude': 10.45, 'longitude': 124.0},
              },
            },
          }),
        );
        if (response.statusCode == 200) {
          final payload = json.decode(response.body) as Map<String, dynamic>;
          final suggestions = (payload['suggestions'] as List?) ?? const [];
          final items = <Map<String, dynamic>>[];
          for (final raw in suggestions) {
            final prediction = (raw as Map?)?['placePrediction'];
            if (prediction is! Map) continue;
            final placeId = prediction['placeId']?.toString();
            final displayName =
                (prediction['text'] as Map?)?['text']?.toString();
            if (placeId == null || placeId.isEmpty || displayName == null) {
              continue;
            }
            items.add({'display_name': displayName, 'place_id': placeId});
          }
          if (items.isNotEmpty) return items;
        }
      }

      if (!_allowLegacyGeocodeFallback) return [];
      final url =
          'https://nominatim.openstreetmap.org/search'
          '?q=$query&format=json&limit=5&addressdetails=1'
          '&countrycodes=ph&viewbox=123.75,10.45,124.0,10.22&bounded=1';
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'Floote_App_Emergency'},
      );
      if (response.statusCode == 200) {
        final List data = json.decode(response.body);
        return data
            .where((item) {
              final address = item['display_name'].toString().toLowerCase();
              return address.contains('cebu');
            })
            .toList()
            .cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _initLocationDetection() async {
    setState(() => _isDetectingLocation = true);
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _lat = position.latitude;
      _lng = position.longitude;

      if (_googleGeocodingApiKey.isNotEmpty || _googlePlacesApiKey.isNotEmpty) {
        final geocodeKey =
            _googleGeocodingApiKey.isNotEmpty ? _googleGeocodingApiKey : _googlePlacesApiKey;
        final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
          'latlng': '$_lat,$_lng',
          'key': geocodeKey,
        });
        final response = await http.get(uri);
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final results = data['results'];
          if (results is List && results.isNotEmpty) {
            final detected = results.first['formatted_address']?.toString().trim();
            setState(() {
              _locationController.text =
                  (detected == null || detected.isEmpty) ? 'Current Location' : detected;
              _lastResolvedLocationName = _locationController.text;
              _isDetectingLocation = false;
            });
            unawaited(_refreshNearbyFloodReports());
            return;
          }
        }
      }

      final nearestLandmark = await _resolveNearestLandmarkName(_lat!, _lng!);
      if (nearestLandmark != null && nearestLandmark.isNotEmpty) {
        setState(() {
          _locationController.text = nearestLandmark;
          _lastResolvedLocationName = nearestLandmark;
          _isDetectingLocation = false;
        });
        unawaited(_refreshNearbyFloodReports());
        return;
      }

      setState(() {
        _locationController.text = 'Current Location';
        _lastResolvedLocationName = _locationController.text;
        _isDetectingLocation = false;
      });
      unawaited(_refreshNearbyFloodReports());
    } catch (_) {
      setState(() {
        _locationController.text = '';
        _lastResolvedLocationName = null;
        _isDetectingLocation = false;
        _nearbyFloodReports = const [];
      });
    }
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) setState(() => _selectedImage = image);
  }

  Future<void> _submitReport() async {
    final description = _descriptionController.text.trim();
    final typedLocation = _locationController.text.trim();
    if (description.isEmpty || typedLocation.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Description and Location are required.')),
      );
      return;
    }
    final locationReady = await _ensureReportLocationResolved();
    if (!mounted) return;
    if (!locationReady || _lat == null || _lng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please pick a valid location from suggestions or use GPS.')),
      );
      return;
    }
    // Force a fresh nearby snapshot right before submit so first-launch
    // submissions do not race ahead of duplicate validation.
    await _refreshNearbyFloodReports();
    if (!mounted) return;
    final duplicateNearby = await _hasNearbyDuplicateFloodReport();
    if (!mounted) return;
    if (duplicateNearby) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This area was already reported as flooded recently.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      String? publicUrl;
      if (_selectedImage != null) {
        final file = File(_selectedImage!.path);
        final fileName = 'report_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await Supabase.instance.client.storage.from('reports').upload(fileName, file);
        publicUrl = Supabase.instance.client.storage.from('reports').getPublicUrl(fileName);
      }
      final activeUserId = Supabase.instance.client.auth.currentUser?.id;
      final fallbackNearLabel =
          (_lat != null && _lng != null) ? _nearCoordinatesLabel(_lat!, _lng!) : null;
      final resolvedLocation = _normalizedLocationNameForInsert();
      final safeLocationName =
          resolvedLocation.toLowerCase() == 'current location' && fallbackNearLabel != null
              ? fallbackNearLabel
              : resolvedLocation;

      await Supabase.instance.client.from('user_reports').insert({
        'location_name': safeLocationName,
        'user_comments': description,
        'image_url': publicUrl,
        'latitude': _lat,
        'longitude': _lng,
        'user_id': activeUserId,
        'created_at': DateTime.now().toIso8601String(),
        'admin_decision': 'pending',
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report submitted!'), backgroundColor: Colors.green),
      );
      _resetReportFormAfterSubmit();
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _resolveAndSetSelectedLocation(Map<String, dynamic> suggestion) async {
    final rawLat = suggestion['lat']?.toString();
    final rawLng = suggestion['lon']?.toString();
    if (rawLat != null && rawLng != null) {
      final parsedLat = double.tryParse(rawLat);
      final parsedLng = double.tryParse(rawLng);
      if (parsedLat != null && parsedLng != null) {
        setState(() {
          _locationController.text = suggestion['display_name'];
          _lat = parsedLat;
          _lng = parsedLng;
          _lastResolvedLocationName = _locationController.text.trim();
        });
        unawaited(_refreshNearbyFloodReports());
        return;
      }
    }
    final placeId = suggestion['place_id']?.toString();
    if (placeId == null || placeId.isEmpty || _googlePlacesApiKey.isEmpty) return;

    final encodedPlaceId = Uri.encodeComponent(placeId);
    final uri = Uri.https('places.googleapis.com', '/v1/places/$encodedPlaceId');
    final response = await http.get(
      uri,
      headers: {
        'X-Goog-Api-Key': _googlePlacesApiKey,
        'X-Goog-FieldMask': 'location',
      },
    );
    if (response.statusCode != 200) return;
    final body = json.decode(response.body) as Map<String, dynamic>;
    final location = body['location'];
    if (location is! Map) return;
    final lat = (location['latitude'] as num?)?.toDouble();
    final lng = (location['longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) return;
    setState(() {
      _locationController.text = suggestion['display_name'];
      _lat = lat;
      _lng = lng;
      _lastResolvedLocationName = _locationController.text.trim();
    });
    unawaited(_refreshNearbyFloodReports());
  }

  Future<bool> _ensureReportLocationResolved() async {
    final typedLocation = _locationController.text.trim();
    if (typedLocation.isEmpty) return false;
    final hasCoords = _lat != null && _lng != null;
    final resolvedLocation = _lastResolvedLocationName?.trim();
    final isCurrentLocationLabel = typedLocation.toLowerCase() == 'current location';
    final matchesLastResolved = resolvedLocation != null &&
        resolvedLocation.isNotEmpty &&
        typedLocation.toLowerCase() == resolvedLocation.toLowerCase();
    if (hasCoords && (matchesLastResolved || isCurrentLocationLabel)) return true;

    final suggestions = await _getSearchSuggestions(typedLocation);
    if (suggestions.isEmpty) return false;
    await _resolveAndSetSelectedLocation(suggestions.first);
    return _lat != null && _lng != null;
  }

  String _normalizedLocationNameForInsert() {
    final typedLocation = _locationController.text.trim();
    final resolvedLocation = _lastResolvedLocationName?.trim();
    if (typedLocation.toLowerCase() == 'current location') {
      if (resolvedLocation != null &&
          resolvedLocation.isNotEmpty &&
          resolvedLocation.toLowerCase() != 'current location') {
        return resolvedLocation;
      }
      if (_lat != null && _lng != null) {
        return _nearCoordinatesLabel(_lat!, _lng!);
      }
    }
    return typedLocation;
  }

  String _nearCoordinatesLabel(double lat, double lng) =>
      'Near ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';

  double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  Future<void> _refreshNearbyFloodReports() async {
    final lat = _lat;
    final lng = _lng;
    if (lat == null || lng == null) return;
    if (mounted) setState(() => _isLoadingNearbyReports = true);
    try {
      final rows = await Supabase.instance.client
          .from('user_reports')
          .select('id, location_name, latitude, longitude, admin_decision, created_at')
          .order('created_at', ascending: false)
          .limit(500);
      final nearby = <Map<String, dynamic>>[];
      for (final raw in rows) {
        if (!_isActiveHazardDecision(raw['admin_decision']?.toString())) continue;
        final reportLat = _toDouble(raw['latitude']);
        final reportLng = _toDouble(raw['longitude']);
        if (reportLat == null || reportLng == null) continue;
        final distance = Geolocator.distanceBetween(lat, lng, reportLat, reportLng);
        if (distance > _nearbyPreviewRadiusMeters) continue;
        nearby.add({...raw, 'latitude': reportLat, 'longitude': reportLng, 'distance_m': distance});
      }
      nearby.sort((a, b) =>
          ((a['distance_m'] as double?) ?? double.infinity)
              .compareTo((b['distance_m'] as double?) ?? double.infinity));
      if (!mounted) return;
      setState(() {
        _nearbyFloodReports = nearby;
        _isLoadingNearbyReports = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoadingNearbyReports = false);
    }
  }

  Future<bool> _hasNearbyDuplicateFloodReport() async {
    final lat = _lat;
    final lng = _lng;
    if (lat == null || lng == null) return false;
    try {
      final rpcRaw = await Supabase.instance.client.rpc(
        'is_duplicate_flood_report',
        params: {
          'p_lat': lat,
          'p_lng': lng,
          'p_radius_m': _duplicateBlockRadiusMeters.toInt(),
          // Keep server-side duplicate check active for long-lived hazards.
          'p_window_minutes': _duplicateWindowMinutesUnlimited,
        },
      );
      final rpc = _rpcBoolValue(rpcRaw);
      if (rpc == true) return true;
    } catch (_) {}

    if (_isLoadingNearbyReports) {
      await _refreshNearbyFloodReports();
    }
    await _refreshNearbyFloodReports();
    for (final report in _nearbyFloodReports) {
      if (!_isActiveHazardDecision(report['admin_decision']?.toString())) continue;
      final reportLat = _toDouble(report['latitude']);
      final reportLng = _toDouble(report['longitude']);
      if (reportLat == null || reportLng == null) continue;
      final distance = Geolocator.distanceBetween(lat, lng, reportLat, reportLng);
      if (distance <= _duplicateBlockRadiusMeters) return true;
    }
    return false;
  }

  bool? _rpcBoolValue(dynamic raw) {
    dynamic v = raw;
    if (v is List && v.length == 1) v = v.first;
    if (v is bool) return v;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (s == 'true' || s == 't' || s == '1') return true;
      if (s == 'false' || s == 'f' || s == '0') return false;
    }
    if (v is num) return v != 0;
    return null;
  }

  bool _isActiveHazardDecision(String? decision) {
    final value = (decision ?? '').trim().toLowerCase();
    if (value.isEmpty) return true;
    // Only explicitly cleared / non-hazard outcomes are ignored.
    const nonHazard = {
      'safe',
      'cleared',
      'clear',
      'resolved',
      'rejected',
      'false_alarm',
      'no_flood',
      'not_flood',
      'normal',
    };
    return !nonHazard.contains(value);
  }

  Color _nearbyMarkerColor(String? decision) {
    final value = (decision ?? '').trim().toLowerCase();
    if (value == 'impassable') return Colors.redAccent;
    if (value == 'risky') return Colors.orangeAccent;
    return Colors.blueAccent;
  }

  Color? _nearbyHazardCircleColor(String? decision) {
    final value = (decision ?? '').trim().toLowerCase();
    if (value == 'impassable') return Colors.redAccent;
    if (value == 'risky') return Colors.orangeAccent;
    return null;
  }

  double _nearbyHazardRadiusMeters(String? decision) {
    final value = (decision ?? '').trim().toLowerCase();
    if (value == 'impassable') return 120;
    if (value == 'risky') return 80;
    return 0;
  }

  Color _selectedAreaRadiusColor() {
    bool hasRisky = false;
    for (final report in _nearbyFloodReports) {
      final distance = (report['distance_m'] as num?)?.toDouble();
      if (distance == null || distance > _duplicateBlockRadiusMeters) continue;
      final decision = (report['admin_decision'] ?? '').toString().trim().toLowerCase();
      if (decision == 'impassable') return Colors.redAccent;
      if (decision == 'risky') hasRisky = true;
    }
    return hasRisky ? Colors.orangeAccent : Colors.blueAccent;
  }

  Widget _buildNearbyFloodMiniMap() {
    final lat = _lat;
    final lng = _lng;
    if (lat == null || lng == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade300),
          color: Colors.grey.shade50,
        ),
        child: const Text(
          'Detect your location to preview nearby flood reports.',
          style: TextStyle(color: Colors.black54, fontSize: 13),
        ),
      );
    }
    final hasDuplicate = _nearbyFloodReports.any((report) {
      final distance = (report['distance_m'] as num?)?.toDouble();
      return distance != null && distance <= _duplicateBlockRadiusMeters;
    });
    final selectedRadiusColor = _selectedAreaRadiusColor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 180,
            child: FlutterMap(
              key: ValueKey<String>(
                'incident-mini-map-${lat.toStringAsFixed(6)}-${lng.toStringAsFixed(6)}',
              ),
              options: MapOptions(
                initialCenter: ll.LatLng(lat, lng),
                initialZoom: 16,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                ),
              ),
              children: [
                TileLayer(urlTemplate: _lightTileUrl, userAgentPackageName: 'com.floote.app'),
                CircleLayer(
                  circles: [
                    ..._nearbyFloodReports.map((report) {
                      final rLat = _toDouble(report['latitude'])!;
                      final rLng = _toDouble(report['longitude'])!;
                      final color = _nearbyHazardCircleColor(
                        report['admin_decision']?.toString(),
                      );
                      if (color == null) {
                        return CircleMarker(
                          point: ll.LatLng(rLat, rLng),
                          radius: 0,
                        );
                      }
                      return CircleMarker(
                        point: ll.LatLng(rLat, rLng),
                        radius: _nearbyHazardRadiusMeters(
                          report['admin_decision']?.toString(),
                        ),
                        useRadiusInMeter: true,
                        borderColor: color.withAlpha(230),
                        borderStrokeWidth: 2,
                        color: color.withAlpha(45),
                      );
                    }),
                    CircleMarker(
                      point: ll.LatLng(lat, lng),
                      radius: _duplicateBlockRadiusMeters,
                      useRadiusInMeter: true,
                      borderColor: selectedRadiusColor.withAlpha(220),
                      borderStrokeWidth: 2,
                      color: selectedRadiusColor.withAlpha(35),
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    ..._nearbyFloodReports.map((report) {
                      final rLat = _toDouble(report['latitude'])!;
                      final rLng = _toDouble(report['longitude'])!;
                      return Marker(
                        point: ll.LatLng(rLat, rLng),
                        width: 30,
                        height: 30,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _nearbyMarkerColor(report['admin_decision']?.toString()),
                            border: Border.all(color: Colors.white, width: 1.6),
                          ),
                          child: const Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      );
                    }),
                    Marker(
                      point: ll.LatLng(lat, lng),
                      width: 42,
                      height: 42,
                      child: const Icon(
                        Icons.location_on,
                        color: Color(0xFF1E88E5),
                        size: 36,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_isLoadingNearbyReports)
          const Text(
            'Checking nearby flood reports...',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          )
        else
          Text(
            hasDuplicate
                ? 'Possible duplicate: This area is already reported as flooded.'
                : '${_nearbyFloodReports.length} nearby reports found.',
            style: TextStyle(
              fontSize: 12,
              color: hasDuplicate ? Colors.redAccent : Colors.black54,
              fontWeight: hasDuplicate ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
      ],
    );
  }

  Future<String?> _resolveNearestLandmarkName(double lat, double lng) async {
    if (_googlePlacesApiKey.isEmpty) return null;
    try {
      final uri = Uri.https(
        'maps.googleapis.com',
        '/maps/api/place/nearbysearch/json',
        {
          'location': '$lat,$lng',
          'rankby': 'distance',
          'type': 'point_of_interest',
          'key': _googlePlacesApiKey,
        },
      );
      final response = await http.get(uri);
      if (response.statusCode != 200) return null;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final results = data['results'];
      if (results is! List || results.isEmpty) return null;
      final first = results.first;
      if (first is! Map) return null;
      final name = first['name']?.toString().trim();
      final vicinity = first['vicinity']?.toString().trim();
      if (name == null || name.isEmpty) return null;
      if (vicinity != null && vicinity.isNotEmpty) return '$name, $vicinity';
      return name;
    } catch (_) {
      return null;
    }
  }

  void _resetReportFormAfterSubmit() {
    _descriptionController.clear();
    _selectedImage = null;
    _lastResolvedLocationName = null;
    unawaited(_initLocationDetection());
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        leading: const SizedBox.shrink(),
        leadingWidth: 0,
        centerTitle: false,
        titleSpacing: 0,
        toolbarHeight: 72,
        title: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: const Text(
            'Reports',
            style: TextStyle(
              color: Colors.black,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Report Incident',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _buildNearbyFloodMiniMap(),
            const SizedBox(height: 20),
            const Text('Location *', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            TypeAheadField<Map<String, dynamic>>(
              builder: (context, controller, focusNode) => TextField(
                controller: controller,
                focusNode: focusNode,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.location_on, color: Colors.red),
                  suffixIcon: _isDetectingLocation
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.my_location),
                          onPressed: _initLocationDetection,
                        ),
                  hintText: 'Type street name or use GPS...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  filled: true,
                  fillColor: Colors.green.shade50,
                ),
              ),
              suggestionsCallback: (pattern) async {
                final typed = pattern.trim().toLowerCase();
                final resolved = (_lastResolvedLocationName ?? '').trim().toLowerCase();
                // Prevent reopening suggestions immediately after selecting
                // an item whose text is already resolved in the field.
                if (typed.isNotEmpty && typed == resolved) return const [];
                return _getSearchSuggestions(pattern);
              },
              itemBuilder: (context, suggestion) => ListTile(
                leading: const Icon(Icons.map, size: 20),
                title: Text(
                  suggestion['display_name'],
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              onSelected: (suggestion) async {
                await _resolveAndSetSelectedLocation(suggestion);
                if (!mounted) return;
                FocusScope.of(context).unfocus();
              },
              controller: _locationController,
            ),
            const SizedBox(height: 20),
            const Text('Description *', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            TextField(
              controller: _descriptionController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'Describe the water level or blockage...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Incident Photo', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _pickImage,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 30),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.blue.shade200),
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.blue.shade50.withValues(alpha: 0.3),
                ),
                child: _selectedImage == null
                    ? const Column(
                        children: [
                          Icon(Icons.camera_alt, color: Colors.blue),
                          Text(
                            'Tap to take/upload photo',
                            style: TextStyle(
                              color: Colors.blue,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          const Icon(Icons.check_circle, color: Colors.green),
                          Text(
                            _selectedImage!.name,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _isSubmitting ? null : _submitReport,
                child: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Text(
                        'SUBMIT REPORT',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
