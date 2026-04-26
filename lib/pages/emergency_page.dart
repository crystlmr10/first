import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart' as gnav;
import 'package:latlong2/latlong.dart' as ll;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart'; // Ensure this is in pubspec.yaml

import 'package:first/pages/widgets/sos_queue_card.dart';
import 'package:first/utils/sos_dispatch_status.dart';
import 'package:first/utils/sos_emergency_categories.dart';

/// One row for [SOS History] (closed dispatches only).
class _SosClosedHistoryEntry {
  const _SosClosedHistoryEntry({
    required this.ticketNumber,
    required this.closedAt,
  });

  final String ticketNumber;
  final DateTime? closedAt;
}

class EmergencyPage extends StatefulWidget {
  const EmergencyPage({super.key});

  @override
  State<EmergencyPage> createState() => _EmergencyPageState();
}

class _EmergencyPageState extends State<EmergencyPage> {
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

  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  XFile? _selectedImage;
  bool _isSubmitting = false;
  bool _isDetectingLocation = true;

  double? _lat;
  double? _lng;

  /// After closing SOS ACTIVE, show queue card (value is [ticket_number] or "Pending sync").
  String? _sosQueueTicketId;

  /// Survives popping Emergency SOS so the queue card still shows when reopening this screen.
  static String? _sessionSosQueueTicketId;
  static String? _sessionSosDispatchId;
  static String? _sessionSosStatus;

  /// Matches [_SosBroadcastPageState._pendingTicketLabel] when DB insert failed.
  static const String _pendingSosTicketLabel = 'Pending sync';

  StreamSubscription<List<Map<String, dynamic>>>? _sosDispatchRowSub;

  List<_SosClosedHistoryEntry> _sosClosedHistory = const [];

  /// Queue card only while a dispatch is open (or pending sync). Hidden when latest is [closed].
  bool get _showSosQueueCard {
    final q = _sosQueueTicketId;
    if (q == null || q.isEmpty) return false;
    if (q == _pendingSosTicketLabel) return true;
    final st = _sessionSosStatus;
    if (st == null || st.isEmpty) return true;
    return sosDispatchIsOpen(st);
  }

  bool get _cebuSosLocked {
    final q = _sosQueueTicketId;
    if (q == null || q.isEmpty) return false;
    if (q == _pendingSosTicketLabel) return true;
    final st = _sessionSosStatus;
    if (st == null || st.isEmpty) return true;
    return sosDispatchIsOpen(st);
  }

  void _bindSosDispatchStream(String? dispatchId) {
    _sosDispatchRowSub?.cancel();
    _sosDispatchRowSub = null;
    final id = dispatchId?.trim();
    if (id == null || id.isEmpty) return;
    _sosDispatchRowSub = Supabase.instance.client
        .from('sos_dispatches')
        .stream(primaryKey: const ['id']).eq('id', id)
        .listen((rows) {
      if (!mounted || rows.isEmpty) return;
      final s = rows.first['status']?.toString().trim().toLowerCase();
      if (s == null || s.isEmpty) return;
      if (s == _sessionSosStatus) return;
      setState(() => _sessionSosStatus = s);
      unawaited(_loadSosClosedHistory());
    });
  }

  Future<void> _loadSosClosedHistory() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      if (mounted) setState(() => _sosClosedHistory = const []);
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('sos_dispatches')
          .select('ticket_number, closed_at, submitted_at')
          .eq('user_id', uid)
          .eq('status', SosDispatchStatuses.closed);
      if (!mounted) return;
      final list = <_SosClosedHistoryEntry>[];
      for (final raw in rows as List<dynamic>) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final ticket = m['ticket_number']?.toString().trim() ?? '';
        if (ticket.isEmpty) continue;
        DateTime? closedAt;
        final ca = m['closed_at'];
        if (ca != null) {
          closedAt = DateTime.tryParse(ca.toString());
        }
        closedAt ??= DateTime.tryParse(
          m['submitted_at']?.toString() ?? '',
        );
        list.add(_SosClosedHistoryEntry(ticketNumber: ticket, closedAt: closedAt));
      }
      list.sort((a, b) {
        final ta = a.closedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final tb = b.closedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return tb.compareTo(ta);
      });
      setState(() => _sosClosedHistory = list);
    } catch (e, st) {
      debugPrint('SOS closed history load: $e\n$st');
    }
  }

  /// Latest row for current user (so cold start matches DB). Keeps “Pending sync” if no DB row.
  Future<void> _refreshLatestSosDispatchFromDb() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      if (mounted) setState(() => _sosClosedHistory = const []);
      return;
    }
    try {
      final row = await Supabase.instance.client
          .from('sos_dispatches')
          .select('id, ticket_number, status')
          .eq('user_id', uid)
          .order('submitted_at', ascending: false)
          .limit(1)
          .maybeSingle();
      if (!mounted) return;
      if (row == null) {
        if ((_sessionSosQueueTicketId ?? '') == _pendingSosTicketLabel) {
          _bindSosDispatchStream(_sessionSosDispatchId);
          await _loadSosClosedHistory();
          return;
        }
        _sessionSosQueueTicketId = null;
        _sessionSosDispatchId = null;
        _sessionSosStatus = null;
        setState(() => _sosQueueTicketId = null);
        _bindSosDispatchStream(null);
        await _loadSosClosedHistory();
        return;
      }
      final ticket = row['ticket_number']?.toString().trim() ?? '';
      final id = row['id']?.toString();
      final st = row['status']?.toString().trim().toLowerCase() ?? '';
      _sessionSosQueueTicketId = ticket.isNotEmpty ? ticket : null;
      _sessionSosDispatchId = id;
      _sessionSosStatus = st;
      setState(() {
        _sosQueueTicketId = ticket.isNotEmpty ? ticket : null;
      });
      _bindSosDispatchStream(id);
    } catch (e, st) {
      debugPrint('Latest sos_dispatches load: $e\n$st');
    }
    await _loadSosClosedHistory();
  }

  @override
  void initState() {
    super.initState();
    _sosQueueTicketId = _sessionSosQueueTicketId;
    _bindSosDispatchStream(_sessionSosDispatchId);
    _initLocationDetection();
    unawaited(_refreshLatestSosDispatchFromDb());
  }

  @override
  void dispose() {
    _sosDispatchRowSub?.cancel();
    super.dispose();
  }

  // --- SEARCH METHOD: Borrowed from HomePage ---
  Future<List<Map<String, dynamic>>> _getSearchSuggestions(String query) async {
    if (query.length < 3) return [];

    try {
      if (_googlePlacesApiKey.isNotEmpty) {
        final uri = Uri.https(
          'places.googleapis.com',
          '/v1/places:autocomplete',
        );
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
            final displayName = (prediction['text'] as Map?)?['text']
                ?.toString();
            if (placeId == null || placeId.isEmpty || displayName == null) {
              continue;
            }
            items.add({'display_name': displayName, 'place_id': placeId});
          }
          if (items.isNotEmpty) return items;
        }
      }

      if (!_allowLegacyGeocodeFallback) {
        return [];
      }

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
    } catch (e) {
      debugPrint("Search Error: $e");
    }
    return [];
  }

  // --- AUTO-DETECT ADDRESS FROM GPS ---
  Future<void> _initLocationDetection() async {
    setState(() => _isDetectingLocation = true);
    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      _lat = position.latitude;
      _lng = position.longitude;

      if (_googleGeocodingApiKey.isNotEmpty || _googlePlacesApiKey.isNotEmpty) {
        final geocodeKey = _googleGeocodingApiKey.isNotEmpty
            ? _googleGeocodingApiKey
            : _googlePlacesApiKey;
        final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
          'latlng': '$_lat,$_lng',
          'key': geocodeKey,
        });
        final response = await http.get(uri);
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final results = data['results'];
          if (results is List && results.isNotEmpty) {
            setState(() {
              _locationController.text =
                  results.first['formatted_address'] ?? "Current Location";
              _isDetectingLocation = false;
            });
            return;
          }
        }
      }

      if (_allowLegacyGeocodeFallback) {
        final url = Uri.parse(
          'https://nominatim.openstreetmap.org/reverse?format=json&lat=$_lat&lon=$_lng&zoom=18',
        );

        final response = await http.get(
          url,
          headers: {'User-Agent': 'Floote_App'},
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          setState(() {
            _locationController.text =
                data['display_name'] ?? "Current Location";
            _isDetectingLocation = false;
          });
          return;
        }
      }

      setState(() {
        _locationController.text = "Current Location";
        _isDetectingLocation = false;
      });
    } catch (e) {
      debugPrint("Address detection error: $e");
      setState(() {
        _locationController.text = "";
        _isDetectingLocation = false;
      });
    }
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) setState(() => _selectedImage = image);
  }

  Future<void> _submitReport() async {
    if (_descriptionController.text.trim().isEmpty ||
        _locationController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Description and Location are required.")),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      String? publicUrl;

      if (_selectedImage != null) {
        final file = File(_selectedImage!.path);
        final fileName = 'report_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await Supabase.instance.client.storage
            .from('reports')
            .upload(fileName, file);
        publicUrl = Supabase.instance.client.storage
            .from('reports')
            .getPublicUrl(fileName);
      }

      await Supabase.instance.client.from('user_reports').insert({
        'location_name': _locationController.text.trim(),
        'user_comments': _descriptionController.text.trim(),
        'image_url': publicUrl,
        'latitude': _lat,
        'longitude': _lng,
        'created_at': DateTime.now().toIso8601String(),
        'admin_decision': 'Pending',
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Report submitted!"),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint("Submit Error: $e");
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          "Emergency SOS",
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildEmergencyContactsSection(),
            // Order: (1) Contacts → (3) queue if active → (2) history → (4) Report.
            if (_showSosQueueCard) ...[
              const SizedBox(height: 16),
              SosQueueCard(
                key: ValueKey<String>(
                  'sos_q_${_sessionSosDispatchId ?? _sosQueueTicketId}',
                ),
                ticketNumber: _sosQueueTicketId!,
                dispatchId: _sessionSosDispatchId,
                initialStatus:
                    _sessionSosStatus ?? SosDispatchStatuses.submitted,
                onTap: _openSosDetailFromQueue,
              ),
            ],
            if (_sosClosedHistory.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildSosHistorySection(),
            ],
            const SizedBox(height: 30),
            const Text(
              "Report Incident",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // --- EDITABLE SEARCHABLE LOCATION FIELD ---
            const Text(
              "Location *",
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
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
                  hintText: "Type street name or use GPS...",
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  filled: true,
                  fillColor: Colors.green.shade50,
                ),
              ),
              suggestionsCallback: (pattern) async =>
                  await _getSearchSuggestions(pattern),
              itemBuilder: (context, suggestion) => ListTile(
                leading: const Icon(Icons.map, size: 20),
                title: Text(
                  suggestion['display_name'],
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              onSelected: (suggestion) {
                _resolveAndSetSelectedLocation(suggestion);
              },
              controller: _locationController,
            ),

            const SizedBox(height: 20),
            const Text(
              "Description *",
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _descriptionController,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: "Describe the water level or blockage...",
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),

            const SizedBox(height: 20),
            const Text(
              "Incident Photo",
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
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
                            "Tap to take/upload photo",
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
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: _isSubmitting ? null : _submitReport,
                child: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        "SUBMIT REPORT",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSosHistorySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'SOS History',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        for (final e in _sosClosedHistory) _buildSosHistoryTile(e),
      ],
    );
  }

  Widget _buildSosHistoryTile(_SosClosedHistoryEntry e) {
    final when = e.closedAt != null
        ? DateFormat('MMM d, y • h:mm a').format(e.closedAt!.toLocal())
        : '—';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    e.ticketNumber,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Closed',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Closed at: $when',
              style: TextStyle(
                color: Colors.grey.shade700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmergencyContactsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Emergency Contacts",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.5,
          children: [
            _buildContactCard(
              "Emergency 911",
              "911",
              Colors.orange,
              Icons.notifications_active,
              onTap: null,
            ),
            _buildContactCard(
              "Cebu City Emergency",
              "161",
              Colors.red,
              Icons.local_hospital,
              onTap: _showCebuSosDispatchSheet,
              enabled: !_cebuSosLocked,
            ),
          ],
        ),
      ],
    );
  }

  void _showCebuSosDispatchSheet() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign in to use emergency SOS.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    if (_cebuSosLocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'You already have an active SOS. Wait until it is closed before starting another.',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      builder: (sheetContext) => _SosActivatingSheet(
        onCountdownComplete: () {
          Navigator.of(sheetContext).pop();
          unawaited(_openSosBroadcastAfterCountdown());
        },
      ),
    );
  }

  /// Brief delay + root navigator so push runs after the sheet route is gone (avoids null handoff).
  Future<void> _openSosBroadcastAfterCountdown() async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (!mounted) return;
    final handoff = await Navigator.of(context, rootNavigator: true)
        .push<SosDispatchHandoff?>(
      MaterialPageRoute<SosDispatchHandoff?>(
        fullscreenDialog: true,
        builder: (ctx) => _SosBroadcastPage(
          dispatchStartedAt: DateTime.now(),
        ),
      ),
    );
    if (!mounted) return;
    if (handoff != null && handoff.ticket.isNotEmpty) {
      _sessionSosQueueTicketId = handoff.ticket;
      _sessionSosDispatchId = handoff.dispatchId;
      _sessionSosStatus = handoff.status;
      setState(() => _sosQueueTicketId = handoff.ticket);
      _bindSosDispatchStream(handoff.dispatchId);
      unawaited(_loadSosClosedHistory());
    }
  }

  /// Full-screen SOS map + details; resume from session queue card tap.
  Future<void> _openSosDetailFromQueue() async {
    if (_sosQueueTicketId == null || _sosQueueTicketId!.isEmpty) return;
    final handoff = await Navigator.of(context, rootNavigator: true)
        .push<SosDispatchHandoff?>(
      MaterialPageRoute<SosDispatchHandoff?>(
        fullscreenDialog: true,
        builder: (ctx) => _SosBroadcastPage(
          dispatchStartedAt: DateTime.now(),
          resumeDispatchId: _sessionSosDispatchId,
          resumeTicketNumber: _sosQueueTicketId,
          resumeInitialStatus:
              _sessionSosStatus ?? SosDispatchStatuses.submitted,
        ),
      ),
    );
    if (!mounted) return;
    if (handoff != null && handoff.ticket.isNotEmpty) {
      _sessionSosQueueTicketId = handoff.ticket;
      _sessionSosDispatchId = handoff.dispatchId;
      _sessionSosStatus = handoff.status;
      setState(() => _sosQueueTicketId = handoff.ticket);
      _bindSosDispatchStream(handoff.dispatchId);
      unawaited(_loadSosClosedHistory());
    }
  }

  Widget _buildContactCard(
    String title,
    String subtitle,
    Color color,
    IconData icon, {
    VoidCallback? onTap,
    bool enabled = true,
  }) {
    final effectiveColor = enabled ? color : color.withValues(alpha: 0.45);
    final effectiveOnTap = enabled ? onTap : null;
    final child = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: Colors.white, size: 24),
        const SizedBox(height: 4),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
        Text(
          subtitle,
          style: const TextStyle(color: Colors.white, fontSize: 10),
        ),
      ],
    );

    return Material(
      color: effectiveColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: effectiveOnTap,
        borderRadius: BorderRadius.circular(10),
        child: effectiveOnTap != null
            ? Semantics(
                button: true,
                label: '$title $subtitle',
                child: child,
              )
            : child,
      ),
    );
  }

  Future<void> _resolveAndSetSelectedLocation(
    Map<String, dynamic> suggestion,
  ) async {
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
        });
        return;
      }
    }

    final placeId = suggestion['place_id']?.toString();
    if (placeId == null || placeId.isEmpty || _googlePlacesApiKey.isEmpty) {
      return;
    }

    try {
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
      });
    } catch (e) {
      debugPrint('Place resolve error: $e');
    }
  }
}

/// 3-second SOS activation UI (Cebu City Emergency). Then [onCountdownComplete] opens [_SosBroadcastPage].
class _SosActivatingSheet extends StatefulWidget {
  const _SosActivatingSheet({required this.onCountdownComplete});

  final VoidCallback onCountdownComplete;

  static const int _seconds = 3;

  /// Aligned with Emergency SOS screen: red 911 + blue Cebu accents.
  static const Color _accentRed = Color(0xFFC62828);
  static const Color _surfaceTint = Color(0xFFFFF5F5);

  @override
  State<_SosActivatingSheet> createState() => _SosActivatingSheetState();
}

class _SosActivatingSheetState extends State<_SosActivatingSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: _SosActivatingSheet._seconds),
    );
    _progress = CurvedAnimation(parent: _controller, curve: Curves.linear);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        widget.onCountdownComplete();
      }
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _cancel() {
    _controller.stop();
    if (mounted) Navigator.of(context).pop();
  }

  int _displaySeconds(double v) {
    final remaining =
        _SosActivatingSheet._seconds - (v * _SosActivatingSheet._seconds).floor();
    return remaining.clamp(1, _SosActivatingSheet._seconds);
  }

  @override
  Widget build(BuildContext context) {
    const accent = _SosActivatingSheet._accentRed;
    const tint = _SosActivatingSheet._surfaceTint;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.paddingOf(context).bottom + 16,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final v = _progress.value;
              final sec = _displaySeconds(v);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '⚠️ SOS ACTIVATING',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Hold to confirm',
                    style: TextStyle(
                      color: accent.withValues(alpha: 0.92),
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: 112,
                    height: 112,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox.expand(
                          child: CircularProgressIndicator(
                            value: v,
                            strokeWidth: 5,
                            color: accent,
                            backgroundColor: accent.withValues(alpha: 0.15),
                          ),
                        ),
                        Text(
                          '$sec',
                          style: const TextStyle(
                            color: accent,
                            fontSize: 44,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: v,
                      minHeight: 8,
                      color: accent,
                      backgroundColor: accent.withValues(alpha: 0.12),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text.rich(
                    TextSpan(
                      style: TextStyle(
                        color: accent.withValues(alpha: 0.9),
                        fontSize: 14,
                      ),
                      children: [
                        const TextSpan(text: 'Sending emergency alert in '),
                        TextSpan(
                          text: '$sec',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        TextSpan(
                          text: sec == 1 ? ' second' : ' seconds',
                        ),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 22),
                  Divider(height: 1, color: accent.withValues(alpha: 0.18)),
                  const SizedBox(height: 14),
                  _row(
                    'Location',
                    '📍 Capturing GPS…',
                    accent,
                  ),
                  const SizedBox(height: 12),
                  _row(
                    'Contact',
                    'Cebu City Emergency (161)',
                    accent,
                  ),
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: _cancel,
                    child: Text(
                      'TAP TO CANCEL',
                      style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                        decoration: TextDecoration.underline,
                        decorationColor: accent,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static Widget _row(String label, String value, Color accent) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: TextStyle(
              color: accent.withValues(alpha: 0.75),
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: accent,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}

enum _SosWizardStep { hidden, chooseMain, chooseSub }

/// After Cebu 161 countdown: minimap, decimal coords, live flood warnings from [user_reports].
class _SosBroadcastPage extends StatefulWidget {
  const _SosBroadcastPage({
    required this.dispatchStartedAt,
    this.resumeDispatchId,
    this.resumeTicketNumber,
    this.resumeInitialStatus,
  });

  final DateTime dispatchStartedAt;

  /// When set (queue card reopen), load coords from [sos_dispatches] or GPS without inserting.
  final String? resumeDispatchId;
  final String? resumeTicketNumber;
  final String? resumeInitialStatus;

  @override
  State<_SosBroadcastPage> createState() => _SosBroadcastPageState();
}

class _SosBroadcastPageState extends State<_SosBroadcastPage> {
  static const Color _headerCream = Color(0xFFFFF8E1);
  static const Color _titleBrown = Color(0xFF5D4037);
  static const Color _dangerColor = Color(0xFFFF4C4C);
  static const String _darkTileUrl =
      'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';

  /// Shown when GPS worked but DB insert failed (missing table, RLS, network).
  static const String _pendingTicketLabel = 'Pending sync';

  Position? _position;
  String? _gpsError;
  final MapController _mapController = MapController();
  bool _androidNavMapReady = false;
  String? _androidNavMapError;
  StreamSubscription<List<Map<String, dynamic>>>? _reportsSub;
  List<Map<String, dynamic>> _liveReports = [];
  String? _ticketNumber;
  String? _dispatchId;
  String _dbStatus = SosDispatchStatuses.submitted;

  /// From DB [submitted_at] when resuming; else [dispatchStartedAt] is used for “Sent at”.
  DateTime? _sentAtForDisplay;

  /// New SOS only: main → sub → Confirm before DB insert.
  _SosWizardStep _wizardStep = _SosWizardStep.hidden;
  String? _selectedMainKey;
  String? _selectedSubKey;
  final TextEditingController _otherNoteController = TextEditingController();

  /// Shown in SOS Details (from DB resume or after Confirm).
  String? _emergencyMainKey;
  String? _emergencySubKey;
  String? _emergencyOtherNote;
  String? _callerPhoneDisplay;

  bool _insertingSos = false;

  /// True while [Geolocator.getCurrentPosition] is in flight (new SOS path).
  bool _gpsFetchPending = false;

  /// GPS + optional insert; [close] awaits this so we never [pop] before ticket is known.
  late final Future<void> _bootFuture;

  @override
  void initState() {
    super.initState();
    _otherNoteController.addListener(() {
      if (mounted) setState(() {});
    });
    _listenReports();
    unawaited(_prepareAndroidNavigationMapLayer());
    _bootFuture = _loadGpsAndPersist();
  }

  bool get _useNavigationMapLayer => Platform.isAndroid;

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

  void _listenReports() {
    _reportsSub = Supabase.instance.client
        .from('user_reports')
        .stream(primaryKey: ['id'])
        .listen((rows) {
          if (!mounted) return;
          final typed = rows
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          setState(() {
            _liveReports = _normalizeVerifiedReports(typed);
          });
        });
  }

  Future<bool> _tryLoadDispatchRow(String id) async {
    try {
      final row = await Supabase.instance.client
          .from('sos_dispatches')
          .select(
            'latitude, longitude, accuracy_m, submitted_at, ticket_number, status, '
            'emergency_main_category, emergency_subcategory, emergency_other_note, caller_phone',
          )
          .eq('id', id)
          .maybeSingle();
      if (row == null || !mounted) return false;
      final lat = (row['latitude'] as num?)?.toDouble();
      final lng = (row['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) return false;
      final acc = (row['accuracy_m'] as num?)?.toDouble();
      final accVal = (acc != null && acc.isFinite && acc > 0) ? acc : 0.0;
      final submittedRaw = row['submitted_at'];
      final DateTime ts = submittedRaw is String
          ? (DateTime.tryParse(submittedRaw) ?? DateTime.now())
          : (submittedRaw is DateTime ? submittedRaw : DateTime.now());
      final ticket = row['ticket_number']?.toString().trim();
      final st = row['status']?.toString().trim().toLowerCase() ??
          SosDispatchStatuses.submitted;

      setState(() {
        _position = Position(
          latitude: lat,
          longitude: lng,
          timestamp: ts,
          accuracy: accVal,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: 0,
          headingAccuracy: 0,
          speed: 0,
          speedAccuracy: 0,
        );
        _ticketNumber = (ticket != null && ticket.isNotEmpty)
            ? ticket
            : (widget.resumeTicketNumber ?? _pendingTicketLabel);
        _dispatchId = id;
        _dbStatus = st;
        _sentAtForDisplay = ts;
        _gpsError = null;
        final em = row['emergency_main_category']?.toString().trim();
        _emergencyMainKey = (em != null && em.isNotEmpty) ? em : null;
        final es = row['emergency_subcategory']?.toString().trim();
        _emergencySubKey = (es != null && es.isNotEmpty) ? es : null;
        final eo = row['emergency_other_note']?.toString().trim();
        _emergencyOtherNote = (eo != null && eo.isNotEmpty) ? eo : null;
        final cp = row['caller_phone']?.toString().trim();
        _callerPhoneDisplay =
            (cp != null && cp.isNotEmpty) ? cp : '—';
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final p = _position;
        if (p != null && mounted) {
          unawaited(Future<void>.delayed(
            Duration.zero,
            () => _mapController.move(ll.LatLng(p.latitude, p.longitude), 15),
          ));
        }
      });
      return true;
    } catch (e, st) {
      debugPrint('SOS resume load failed: $e\n$st');
      return false;
    }
  }

  Future<void> _resumeWithGpsNoInsert({
    required String? dispatchId,
    required String ticketLabel,
  }) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _gpsError = 'Location services are disabled.';
            _ticketNumber = ticketLabel;
            _dispatchId = dispatchId;
            _dbStatus = widget.resumeInitialStatus?.trim().toLowerCase() ??
                SosDispatchStatuses.submitted;
          });
        }
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _gpsError = 'Location permission denied.';
            _ticketNumber = ticketLabel;
            _dispatchId = dispatchId;
            _dbStatus = widget.resumeInitialStatus?.trim().toLowerCase() ??
                SosDispatchStatuses.submitted;
          });
        }
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (!mounted) return;
      setState(() {
        _position = pos;
        _gpsError = null;
        _ticketNumber = ticketLabel;
        _dispatchId = dispatchId;
        _dbStatus = widget.resumeInitialStatus?.trim().toLowerCase() ??
            SosDispatchStatuses.submitted;
      });
      _mapController.move(ll.LatLng(pos.latitude, pos.longitude), 15);
    } catch (e) {
      debugPrint('SOS resume GPS error: $e');
      if (mounted) {
        setState(() {
          _gpsError = 'Could not get GPS fix. Try again outdoors.';
          _ticketNumber = ticketLabel;
          _dispatchId = dispatchId;
          _dbStatus = widget.resumeInitialStatus?.trim().toLowerCase() ??
              SosDispatchStatuses.submitted;
        });
      }
    }
  }

  Future<void> _loadGpsAndPersist() async {
    final resumeId = widget.resumeDispatchId?.trim();
    final resumeTicket = widget.resumeTicketNumber?.trim();

    if (resumeId != null && resumeId.isNotEmpty) {
      final loaded = await _tryLoadDispatchRow(resumeId);
      if (loaded) {
        return;
      }
      await _resumeWithGpsNoInsert(
        dispatchId: resumeId,
        ticketLabel: (resumeTicket != null && resumeTicket.isNotEmpty)
            ? resumeTicket
            : _pendingTicketLabel,
      );
      return;
    }

    if (resumeTicket != null &&
        resumeTicket.isNotEmpty &&
        resumeTicket == _pendingTicketLabel) {
      await _resumeWithGpsNoInsert(
        dispatchId: null,
        ticketLabel: resumeTicket,
      );
      return;
    }

    if (resumeTicket != null &&
        resumeTicket.isNotEmpty &&
        resumeTicket != _pendingTicketLabel &&
        (resumeId == null || resumeId.isEmpty)) {
      await _resumeWithGpsNoInsert(
        dispatchId: null,
        ticketLabel: resumeTicket,
      );
      return;
    }

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() => _gpsError = 'Location services are disabled.');
        }
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() => _gpsError = 'Location permission denied.');
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _wizardStep = _SosWizardStep.chooseMain;
        _gpsError = null;
      });
      await _fetchGpsPositionOnly();
    } catch (e) {
      debugPrint('SOS GPS error: $e');
      if (mounted) {
        setState(
          () => _gpsError = 'Could not get GPS fix. Try again outdoors.',
        );
      }
    }
  }

  Future<void> _fetchGpsPositionOnly() async {
    if (!mounted) return;
    setState(() {
      _gpsFetchPending = true;
      _gpsError = null;
    });
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (!mounted) return;
      setState(() {
        _position = pos;
        _gpsFetchPending = false;
        _gpsError = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final p = _position;
        if (p != null && mounted) {
          unawaited(Future<void>.delayed(
            Duration.zero,
            () => _mapController.move(ll.LatLng(p.latitude, p.longitude), 15),
          ));
        }
      });
    } catch (e) {
      debugPrint('SOS GPS fetch: $e');
      if (mounted) {
        setState(() {
          _gpsFetchPending = false;
          _gpsError = 'Could not get GPS fix. Try again outdoors.';
        });
      }
    }
  }

  Future<String?> _fetchProfilePhone() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('phone_number')
          .eq('id', uid)
          .maybeSingle();
      final p = row?['phone_number']?.toString().trim();
      if (p == null || p.isEmpty) return null;
      return p;
    } catch (_) {
      return null;
    }
  }

  bool _canConfirmEmergencySelection() {
    final sub = _selectedSubKey;
    if (sub == null || sub.isEmpty) return false;
    if (sub == 'other') {
      return _otherNoteController.text.trim().isNotEmpty;
    }
    return true;
  }

  bool get _canSubmitEmergencyConfirm =>
      _canConfirmEmergencySelection() &&
      _position != null &&
      !_gpsFetchPending &&
      !_insertingSos;

  Future<void> _confirmEmergencyAndInsert() async {
    final pos = _position;
    final main = _selectedMainKey;
    final sub = _selectedSubKey;
    if (pos == null || main == null || sub == null) return;
    if (!_canConfirmEmergencySelection()) return;

    final otherTrim = sub == 'other'
        ? _otherNoteController.text.trim()
        : null;

    setState(() => _insertingSos = true);
    final phone = await _fetchProfilePhone();
    if (!mounted) return;

    final res = await _tryInsertSosDispatches(
      pos,
      emergencyMainCategory: main,
      emergencySubcategory: sub,
      emergencyOtherNote: (sub == 'other') ? otherTrim : null,
      callerPhone: phone,
    );
    if (!mounted) return;

    setState(() {
      _insertingSos = false;
      _wizardStep = _SosWizardStep.hidden;
      _emergencyMainKey = main;
      _emergencySubKey = sub;
      _emergencyOtherNote =
          (sub == 'other' && otherTrim != null && otherTrim.isNotEmpty)
              ? otherTrim
              : null;
      _callerPhoneDisplay =
          (phone != null && phone.isNotEmpty) ? phone : '—';
      if (res != null) {
        _ticketNumber = res.ticket;
        _dispatchId = res.id;
        _dbStatus = res.status;
        _sentAtForDisplay = res.submittedAt ?? DateTime.now();
      } else {
        _ticketNumber = _pendingTicketLabel;
        _dispatchId = null;
        _dbStatus = SosDispatchStatuses.submitted;
      }
    });

    final p = _position;
    if (p != null) {
      _mapController.move(ll.LatLng(p.latitude, p.longitude), 15);
    }
  }

  /// Returns row id, ticket, and status from DB; null on insert failure.
  Future<SosDispatchInsertResult?> _tryInsertSosDispatches(
    Position pos, {
    required String emergencyMainCategory,
    required String emergencySubcategory,
    String? emergencyOtherNote,
    String? callerPhone,
  }) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      final insertPayload = <String, dynamic>{
        'user_id': uid,
        'channel': 'cebu_161',
        'latitude': pos.latitude,
        'longitude': pos.longitude,
        if (pos.accuracy > 0 && pos.accuracy.isFinite) 'accuracy_m': pos.accuracy,
        'status': SosDispatchStatuses.submitted,
        'emergency_main_category': emergencyMainCategory,
        'emergency_subcategory': emergencySubcategory,
        if (emergencyOtherNote != null && emergencyOtherNote.isNotEmpty)
          'emergency_other_note': emergencyOtherNote,
        if (callerPhone != null && callerPhone.isNotEmpty)
          'caller_phone': callerPhone,
      };
      final row = await Supabase.instance.client
          .from('sos_dispatches')
          .insert(insertPayload)
          .select(
            'id, ticket_number, status, submitted_at',
          )
          .maybeSingle();
      if (row == null) return null;
      final id = row['id']?.toString();
      final t = row['ticket_number']?.toString().trim();
      final st = row['status']?.toString().trim().toLowerCase() ??
          SosDispatchStatuses.submitted;
      if (id == null || id.isEmpty || t == null || t.isEmpty) return null;
      final submittedRaw = row['submitted_at'];
      DateTime? submittedAt;
      if (submittedRaw is String) {
        submittedAt = DateTime.tryParse(submittedRaw);
      } else if (submittedRaw is DateTime) {
        submittedAt = submittedRaw;
      }
      return SosDispatchInsertResult(
        id: id,
        ticket: t,
        status: st,
        submittedAt: submittedAt,
      );
    } catch (e, st) {
      debugPrint('sos_dispatches insert failed (table or RLS?): $e\n$st');
      if (mounted) {
        final msg = e.toString().toLowerCase();
        if (msg.contains('unique') ||
            msg.contains('duplicate') ||
            msg.contains('23505')) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'An active SOS already exists. Close it before starting a new one.',
                ),
                backgroundColor: Colors.redAccent,
              ),
            );
          });
        }
      }
      return null;
    }
  }

  @override
  void dispose() {
    _otherNoteController.dispose();
    _reportsSub?.cancel();
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

  Color _markerColorForDecision(String? decision) {
    final value = (decision ?? '').trim().toLowerCase();
    if (value == 'impassable') return Colors.redAccent;
    if (value == 'risky') return Colors.orangeAccent;
    return Colors.lightBlueAccent;
  }

  List<CircleMarker> _buildHazardCircles() {
    final circles = <CircleMarker>[];
    for (final report in _liveReports) {
      final lat = _toDouble(report['latitude']);
      final lng = _toDouble(report['longitude']);
      if (lat == null || lng == null) continue;
      final decision = (report['admin_decision'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      final isImpassable = decision == 'impassable';
      final radius = isImpassable ? 150.0 : 80.0;
      final stroke = isImpassable
          ? _dangerColor.withAlpha(220)
          : Colors.orangeAccent.withAlpha(220);
      circles.add(
        CircleMarker(
          point: ll.LatLng(lat, lng),
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

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];
    for (final r in _liveReports) {
      final lat = _toDouble(r['latitude']);
      final lng = _toDouble(r['longitude']);
      if (lat == null || lng == null) continue;
      markers.add(
        Marker(
          point: ll.LatLng(lat, lng),
          width: 36,
          height: 36,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _markerColorForDecision(r['admin_decision']?.toString()),
              border: Border.all(color: Colors.white, width: 1.8),
            ),
            child: const Icon(
              Icons.warning_amber_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
        ),
      );
    }
    final pos = _position;
    if (pos != null) {
      markers.add(
        Marker(
          point: ll.LatLng(pos.latitude, pos.longitude),
          width: 42,
          height: 42,
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
            child: const Icon(
              Icons.person_pin_circle,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      );
    }
    return markers;
  }

  Widget _buildEmergencyWizardOverlay() {
    const cream = _headerCream;
    const brown = _titleBrown;
    return Material(
      color: Colors.white.withValues(alpha: 0.97),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_gpsError != null)
              Material(
                color: Colors.red.shade50,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline, color: Colors.red.shade800, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _gpsError!,
                          style: TextStyle(
                            color: Colors.red.shade900,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _gpsFetchPending ? null : _fetchGpsPositionOnly,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: _wizardStep == _SosWizardStep.chooseMain
                  ? _buildWizardChooseMain(cream: cream, brown: brown)
                  : _buildWizardChooseSub(cream: cream, brown: brown),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWizardChooseMain({
    required Color cream,
    required Color brown,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            'What kind of emergency?',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: brown,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: sosEmergencyMainOrder.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final key = sosEmergencyMainOrder[i];
              final emoji = sosEmergencyMainEmoji[key] ?? '';
              final label = sosEmergencyMainLabels[key] ?? key;
              return Material(
                color: cream,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    setState(() {
                      _selectedMainKey = key;
                      _selectedSubKey = null;
                      _otherNoteController.clear();
                      _wizardStep = _SosWizardStep.chooseSub;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        Text(emoji, style: const TextStyle(fontSize: 26)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            label,
                            style: TextStyle(
                              color: brown,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        Icon(Icons.chevron_right, color: brown.withValues(alpha: 0.6)),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildWizardChooseSub({
    required Color cream,
    required Color brown,
  }) {
    final mainKey = _selectedMainKey;
    if (mainKey == null) {
      return const SizedBox.shrink();
    }
    final subs = sosEmergencySubKeysByMain[mainKey] ?? const [];
    final mainLabel = sosEmergencyMainLabels[mainKey] ?? mainKey;
    final emoji = sosEmergencyMainEmoji[mainKey] ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back, color: brown),
                onPressed: () {
                  setState(() {
                    _wizardStep = _SosWizardStep.chooseMain;
                    _selectedSubKey = null;
                    _otherNoteController.clear();
                  });
                },
              ),
              Expanded(
                child: Text(
                  '$emoji $mainLabel',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: brown,
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                  ),
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              ...subs.map((subKey) {
                final subLabel = sosEmergencySubLabel(mainKey, subKey);
                final selected = _selectedSubKey == subKey;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: selected
                        ? Colors.red.shade50
                        : cream,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        setState(() {
                          _selectedSubKey = subKey;
                          if (subKey != 'other') {
                            _otherNoteController.clear();
                          }
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                subLabel,
                                style: TextStyle(
                                  color: brown,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            if (selected)
                              Icon(Icons.check_circle, color: Colors.red.shade700),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
              if (_selectedSubKey == 'other') ...[
                const SizedBox(height: 6),
                TextField(
                  controller: _otherNoteController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'Describe the situation',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    fillColor: cream,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed:
                    _canSubmitEmergencyConfirm ? _confirmEmergencyAndInsert : null,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _insertingSos
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        'CONFIRM',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ),
                      ),
              ),
              if (_selectedSubKey != null &&
                  _position == null &&
                  _gpsFetchPending) ...[
                const SizedBox(height: 10),
                Text(
                  'Getting your location…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: brown.withValues(alpha: 0.85),
                    fontSize: 13,
                  ),
                ),
              ] else if (_selectedSubKey != null &&
                  _position == null &&
                  !_gpsFetchPending &&
                  _gpsError == null &&
                  _canConfirmEmergencySelection()) ...[
                const SizedBox(height: 10),
                Text(
                  'Waiting for GPS before you can confirm.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: brown.withValues(alpha: 0.85),
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }

  String _coordsLine() {
    final p = _position;
    if (p == null) return '—';
    return '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}';
  }

  String _accuracyLine() {
    final p = _position;
    if (p == null || !p.accuracy.isFinite || p.accuracy <= 0) return '—';
    return '±${p.accuracy.round()} m';
  }

  Future<void> _closeBroadcast() async {
    await _bootFuture;
    if (!mounted) return;
    final did = _dispatchId;
    if (did != null && did.isNotEmpty) {
      try {
        final row = await Supabase.instance.client
            .from('sos_dispatches')
            .select('status')
            .eq('id', did)
            .maybeSingle();
        final s = row?['status']?.toString().trim().toLowerCase();
        if (s != null && s.isNotEmpty && mounted) {
          setState(() => _dbStatus = s);
        }
      } catch (_) {}
    }
    if (!mounted) return;
    if (_position != null) {
      final tid = _dispatchId?.trim();
      final tk = _ticketNumber?.trim();
      final shouldHandoff = (tid != null && tid.isNotEmpty) ||
          (tk != null && tk.isNotEmpty);
      if (!shouldHandoff) {
        Navigator.of(context).pop();
        return;
      }
      final ticketLabel =
          (tk != null && tk.isNotEmpty) ? tk : _pendingTicketLabel;
      Navigator.of(context).pop(
        SosDispatchHandoff(
          ticket: ticketLabel,
          dispatchId: _dispatchId,
          status: _dbStatus,
        ),
      );
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final timeSent = DateFormat.jm().format(
      _sentAtForDisplay ?? widget.dispatchStartedAt,
    );
    final emergencyLine = formatSosEmergencyTypeLine(
      _emergencyMainKey,
      _emergencySubKey,
      _emergencyOtherNote,
    );
    final phoneLine = _callerPhoneDisplay ?? '—';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (didPop) return;
        unawaited(_closeBroadcast());
      },
      child: Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: _headerCream,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.close, color: _titleBrown),
          onPressed: () => unawaited(_closeBroadcast()),
        ),
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/sos_siren.png',
              height: 26,
              width: 26,
              fit: BoxFit.contain,
            ),
            const SizedBox(width: 10),
            Text(
              'SOS DETAILS',
              style: TextStyle(
                color: Colors.red.shade700,
                fontWeight: FontWeight.w800,
                fontSize: 17,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: SizedBox(
                    height: 220,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(11),
                          child: _buildMapArea(),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (_ticketNumber != null &&
                    _ticketNumber!.isNotEmpty &&
                    _ticketNumber != _pendingTicketLabel &&
                    _dispatchId != null &&
                    _dispatchId!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SosQueueCard(
                      key: ValueKey<String>(
                        'sos_q_${_dispatchId ?? _ticketNumber}',
                      ),
                      ticketNumber: _ticketNumber!,
                      dispatchId: _dispatchId,
                      initialStatus: _dbStatus,
                    ),
                  ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    children: [
                      _infoRow('Coords', _coordsLine()),
                      const Divider(height: 1),
                      _infoRow('Emergency Type', emergencyLine),
                      const Divider(height: 1),
                      _infoRow('Phone', phoneLine),
                      const Divider(height: 1),
                      _infoRow('Accuracy', _accuracyLine()),
                      const Divider(height: 1),
                      _infoRow('Sent at', timeSent),
                      if (_gpsError != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _gpsError!,
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontSize: 13,
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _gpsError = null;
                              _position = null;
                            });
                            _loadGpsAndPersist();
                          },
                          child: const Text('Retry GPS'),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (_wizardStep != _SosWizardStep.hidden)
              Positioned.fill(
                child: _buildEmergencyWizardOverlay(),
              ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _buildMapArea() {
    if (_gpsError != null &&
        _position == null &&
        _wizardStep == _SosWizardStep.hidden) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _gpsError!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade700),
          ),
        ),
      );
    }
    if (_position == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final pos = _position!;
    if (_useNavigationMapLayer) {
      return _buildAndroidMapArea(pos);
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: ll.LatLng(pos.latitude, pos.longitude),
            initialZoom: 15,
          ),
          children: [
            TileLayer(
              urlTemplate: _darkTileUrl,
              subdomains: const ['a', 'b', 'c', 'd'],
              userAgentPackageName: 'com.example.first',
            ),
            CircleLayer(circles: _buildHazardCircles()),
            MarkerLayer(markers: _buildMarkers()),
          ],
        ),
        Positioned(
          bottom: 10,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              'Broadcasting location',
              style: TextStyle(
                color: Colors.blue.shade800,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAndroidMapArea(Position pos) {
    final mapBody = !_androidNavMapReady
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _androidNavMapError ?? 'Preparing Navigation SDK map...',
                textAlign: TextAlign.center,
              ),
            ),
          )
        : gnav.GoogleMapsMapView(
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
                  debugPrint('sos map style apply failed: $e');
                }
              }());
            },
            initialMapType: gnav.MapType.normal,
            initialMapColorScheme: gnav.MapColorScheme.light,
            initialCameraPosition: gnav.CameraPosition(
              target: gnav.LatLng(
                latitude: pos.latitude,
                longitude: pos.longitude,
              ),
              zoom: 15,
            ),
          );
    return Stack(
      alignment: Alignment.center,
      children: [
        mapBody,
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
                '${_liveReports.length} nearby reports',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 10,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              'Broadcasting location',
              style: TextStyle(
                color: Colors.blue.shade800,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey.shade800,
                fontWeight: FontWeight.w500,
                fontSize: 15,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
