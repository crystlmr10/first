import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart' as gnav;
import 'package:latlong2/latlong.dart' as ll;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:first/utils/sos_emergency_categories.dart';

typedef OnRescuerDispatchAccepted = void Function({
  required String dispatchId,
  required double latitude,
  required double longitude,
  String? ticketNumber,
});

/// Rescue Center: live SOS offers for the logged-in rescuer, map pins, accept/decline.
/// Requires SQL migrations: profiles duty/location, sos_dispatch_offers, RLS, trigger, RPC.
class RescuerRescueCenterPage extends StatefulWidget {
  const RescuerRescueCenterPage({super.key, this.onDispatchAccepted});

  /// Called after this rescuer successfully accepts an SOS (before queue refresh).
  final OnRescuerDispatchAccepted? onDispatchAccepted;

  @override
  State<RescuerRescueCenterPage> createState() =>
      _RescuerRescueCenterPageState();
}

class _RescuerRescueCenterPageState extends State<RescuerRescueCenterPage> {
  /// Map camera target: first fix from device GPS (respects mock location apps), then user pan/zoom.
  ll.LatLng? _mapCenter;
  double _mapZoom = 14;
  final MapController _mapController = MapController();
  bool _mapLocationLoading = true;
  String? _mapLocationError;
  bool _myLocationLayerEnabled = false;
  bool _androidNavMapReady = false;
  String? _androidNavMapError;

  static const double _wideBreakpoint = 900;

  List<Map<String, dynamic>> _offerRows = [];
  List<Map<String, dynamic>> _historyRows = [];
  Map<String, String> _citizenNames = {};
  bool _loading = true;
  String? _error;
  Timer? _poll;
  StreamSubscription<RemoteMessage>? _fcmSub;
  final Set<String> _responding = {};
  static const String _darkTileUrl =
      'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
  bool get _useNavigationMapLayer =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    unawaited(_prepareAndroidNavigationMapLayer());
    unawaited(_refreshMapCenterFromGps());
    unawaited(_loadOffers());
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _loadOffers());
    if (Firebase.apps.isNotEmpty) {
      _fcmSub = FirebaseMessaging.onMessage.listen((m) {
        final d = m.data;
        if (d['type'] != 'sos_dispatch') return;
        unawaited(_loadOffers());
        if (!mounted) return;
        final ticket = d['ticket_number'] ?? 'SOS';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('New alert: $ticket')),
        );
      });
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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _androidNavMapError = 'Navigation map failed: $e');
    }
  }

  @override
  void dispose() {
    _fcmSub?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  /// Centers the map on [Geolocator]’s current position (includes Fake GPS / mock location).
  Future<void> _refreshMapCenterFromGps() async {
    if (!mounted) return;
    setState(() {
      _mapLocationLoading = true;
      _mapLocationError = null;
    });
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _mapLocationLoading = false;
            _mapLocationError =
                'Turn on location services to show your position on the map.';
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
            _mapLocationLoading = false;
            _mapLocationError =
                'Location permission is required to show your position.';
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
      final target = ll.LatLng(pos.latitude, pos.longitude);
      setState(() {
        _mapCenter = target;
        _mapLocationLoading = false;
        _mapLocationError = null;
        _myLocationLayerEnabled = true;
      });
      if (!_useNavigationMapLayer) {
        _mapController.move(target, _mapZoom);
      }
    } catch (e, st) {
      debugPrint('Rescue Center map GPS: $e\n$st');
      if (mounted) {
        setState(() {
          _mapLocationLoading = false;
          _mapLocationError = 'Could not read GPS. Try again.';
        });
      }
    }
  }

  Future<void> _loadOffers() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Not signed in.';
        });
      }
      return;
    }

    try {
      final rows = await Supabase.instance.client
          .from('sos_dispatch_offers')
          .select('''
            id, status, distance_m, created_at, responded_at,
            sos_dispatches (
              id, ticket_number, latitude, longitude, status, submitted_at,
              emergency_main_category, emergency_subcategory, emergency_other_note,
              caller_phone,
              user_id, assigned_rescuer_id
            )
          ''')
          .eq('rescuer_id', uid)
          .inFilter('status', ['pending', 'accepted'])
          .order('created_at', ascending: false);

      final list = <Map<String, dynamic>>[];
      final history = <Map<String, dynamic>>[];
      final userIds = <String>{};
      for (final raw in rows as List<dynamic>) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final d = m['sos_dispatches'];
        if (d is Map) {
          final uidCit = d['user_id']?.toString();
          if (uidCit != null && uidCit.isNotEmpty) userIds.add(uidCit);
        }
        list.add(m);
      }

      final historyRows = await Supabase.instance.client
          .from('sos_dispatch_offers')
          .select('''
            id, status, distance_m, created_at, responded_at,
            sos_dispatches (
              id, ticket_number, latitude, longitude, status, submitted_at, closed_at,
              emergency_main_category, emergency_subcategory, emergency_other_note,
              caller_phone,
              user_id, assigned_rescuer_id
            )
          ''')
          .eq('rescuer_id', uid)
          .inFilter('status', ['accepted', 'declined'])
          .order('responded_at', ascending: false)
          .limit(100);

      for (final raw in historyRows as List<dynamic>) {
        if (raw is! Map) continue;
        final m = Map<String, dynamic>.from(raw);
        final d = m['sos_dispatches'];
        if (d is Map) {
          final uidCit = d['user_id']?.toString();
          if (uidCit != null && uidCit.isNotEmpty) userIds.add(uidCit);
        }
        history.add(m);
      }

      final names = Map<String, String>.from(_citizenNames);
      if (userIds.isNotEmpty) {
        final profs = await Supabase.instance.client
            .from('profiles')
            .select('id, username')
            .filter('id', 'in', '(${userIds.join(',')})');
        for (final p in profs as List<dynamic>) {
          if (p is! Map) continue;
          final id = p['id']?.toString();
          final un = p['username']?.toString().trim();
          if (id != null && un != null && un.isNotEmpty) {
            names[id] = un;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _offerRows = list;
        _historyRows = history;
        _citizenNames = names;
        _loading = false;
        _error = null;
      });
    } catch (e, st) {
      debugPrint('Rescue Center load: $e\n$st');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load SOS queue. Run DB migrations?';
        });
      }
    }
  }

  Future<void> _respond(String offerId, bool accept, Map<String, dynamic> row) async {
    if (_responding.contains(offerId)) return;
    setState(() => _responding.add(offerId));
    try {
      final res = await Supabase.instance.client.rpc(
        'respond_sos_offer',
        params: {'p_offer_id': offerId, 'p_accept': accept},
      );
      if (!mounted) return;
      final map = res is Map
          ? Map<String, dynamic>.from(res)
          : <String, dynamic>{};
      final ok = map['ok'] == true;
      final accepted = map['accepted'] == true;
      if (!ok && map['error'] == 'already_assigned') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Another rescuer already accepted this SOS.')),
        );
      }
      if (ok && accept && accepted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You accepted this SOS.')),
        );
        final rawDispatch = row['sos_dispatches'];
        if (rawDispatch is Map) {
          final dispatch = Map<String, dynamic>.from(rawDispatch);
          final dispatchId = dispatch['id']?.toString();
          final lat = (dispatch['latitude'] as num?)?.toDouble();
          final lng = (dispatch['longitude'] as num?)?.toDouble();
          final ticket = dispatch['ticket_number']?.toString();
          if (dispatchId != null && lat != null && lng != null) {
            widget.onDispatchAccepted?.call(
              dispatchId: dispatchId,
              latitude: lat,
              longitude: lng,
              ticketNumber: ticket,
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Accepted SOS, but destination is missing. Refresh queue.',
                ),
              ),
            );
          }
        }
      }
      await _loadOffers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Action failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _responding.remove(offerId));
      }
    }
  }

  List<Marker> _buildMarkers() {
    final out = <Marker>[];
    for (final m in _offerRows) {
      final st = m['status']?.toString();
      if (st != 'pending' && st != 'accepted') continue;
      final d = m['sos_dispatches'];
      if (d is! Map) continue;
      final id = d['id']?.toString() ?? '';
      final lat = (d['latitude'] as num?)?.toDouble();
      final lng = (d['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null || id.isEmpty) continue;
      final ticket = d['ticket_number']?.toString() ?? 'SOS';
      out.add(
        Marker(
          point: ll.LatLng(lat, lng),
          width: 40,
          height: 40,
          child: Tooltip(
            message: '$ticket • Citizen SOS',
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.redAccent,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black45,
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(Icons.sos, color: Colors.white, size: 18),
            ),
          ),
        ),
      );
    }
    return out;
  }

  Widget _mapCard({double? height}) {
    if (_mapLocationLoading && _mapCenter == null) {
      return _RescueCardShell(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: const Center(child: CircularProgressIndicator()),
          ),
        ),
      );
    }
    if (_mapLocationError != null && _mapCenter == null) {
      return _RescueCardShell(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _mapLocationError!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.blueGrey.shade800,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: _refreshMapCenterFromGps,
                      icon: const Icon(Icons.my_location),
                      label: const Text('Retry location'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final center = _mapCenter!;
    if (_useNavigationMapLayer) {
      return _buildAndroidNavigationMap(center, height: height);
    }
    final map = FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: center,
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
        MarkerLayer(markers: _buildMarkers()),
        if (_myLocationLayerEnabled)
          MarkerLayer(
            markers: [
              Marker(
                point: center,
                width: 42,
                height: 42,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF00B8FF),
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(
                    Icons.my_location,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ],
          ),
      ],
    );

    return _RescueCardShell(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            height != null
                ? SizedBox(height: height, child: map)
                : SizedBox.expand(child: map),
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.white.withValues(alpha: 0.92),
                elevation: 2,
                borderRadius: BorderRadius.circular(8),
                child: IconButton(
                  tooltip: 'Center on my location',
                  onPressed: _refreshMapCenterFromGps,
                  icon: Icon(Icons.my_location, color: Colors.blue.shade800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAndroidNavigationMap(ll.LatLng center, {double? height}) {
    final mapBody = !_androidNavMapReady
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
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
                  await controller.setMyLocationEnabled(_myLocationLayerEnabled);
                  await controller.setMapType(mapType: gnav.MapType.normal);
                  await controller.setMapColorScheme(gnav.MapColorScheme.light);
                  await controller.setMapStyle('[]');
                  await Future<void>.delayed(const Duration(milliseconds: 700));
                  await controller.setMapType(mapType: gnav.MapType.normal);
                  await controller.setMapColorScheme(gnav.MapColorScheme.light);
                  await controller.setMapStyle('[]');
                } catch (e) {
                  debugPrint('rescue center map style apply failed: $e');
                }
              }());
            },
            initialMapType: gnav.MapType.normal,
            initialMapColorScheme: gnav.MapColorScheme.light,
            initialCameraPosition: gnav.CameraPosition(
              target: gnav.LatLng(
                latitude: center.latitude,
                longitude: center.longitude,
              ),
              zoom: _mapZoom,
            ),
          );

    return _RescueCardShell(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            height != null
                ? SizedBox(height: height, child: mapBody)
                : SizedBox.expand(child: mapBody),
            Positioned(
              left: 10,
              top: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xC6111A24),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Text(
                    '${_offerRows.length} SOS markers listed below',
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
              top: 8,
              right: 8,
              child: Material(
                color: Colors.white.withValues(alpha: 0.92),
                elevation: 2,
                borderRadius: BorderRadius.circular(8),
                child: IconButton(
                  tooltip: 'Center on my location',
                  onPressed: _refreshMapCenterFromGps,
                  icon: Icon(Icons.my_location, color: Colors.blue.shade800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _incidentsSection() {
    if (_loading) {
      return const _RescueCardShell(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_error != null) {
      return _RescueCardShell(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: TextStyle(color: Colors.red.shade800)),
        ),
      );
    }

    final pending = _offerRows
        .where((m) => m['status']?.toString() == 'pending')
        .toList();

    return _RescueCardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Text(
              'SOS Reports',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
          ),
          const Divider(height: 1),
          if (pending.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No pending SOS in your queue. Stay on Active Duty with GPS to receive offers within 1 km.',
                style: TextStyle(color: Colors.blueGrey, fontWeight: FontWeight.w600),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: pending.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final row = pending[i];
                return _SosOfferCard(
                  row: row,
                  citizenNames: _citizenNames,
                  responding: _responding,
                  onAccept: () => _respond(row['id'].toString(), true, row),
                  onDecline: () => _respond(row['id'].toString(), false, row),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _statusSection() {
    return _RescueCardShell(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Rescuer Status',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
            const SizedBox(height: 10),
            Text(
              'Use Active Duty on the dashboard to broadcast your position. '
              'SOS alerts go to on-duty rescuers within 1 km (recent GPS).',
              style: TextStyle(
                color: Colors.blueGrey.shade700,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _historySection() {
    if (_loading) {
      return const _RescueCardShell(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_error != null) {
      return _RescueCardShell(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(_error!, style: TextStyle(color: Colors.red.shade800)),
        ),
      );
    }

    return _RescueCardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Text(
              'SOS History',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
          ),
          const Divider(height: 1),
          if (_historyRows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No SOS history yet for this rescuer.',
                style: TextStyle(color: Colors.blueGrey, fontWeight: FontWeight.w600),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: _historyRows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                return _SosHistoryCard(
                  row: _historyRows[i],
                  citizenNames: _citizenNames,
                );
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final isWide = w >= _wideBreakpoint;

    return ColoredBox(
      color: const Color(0xFFF4F7FA),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(isWide ? 24 : 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _TopTitle(
                title: 'Rescue Center',
                subtitle: 'SOS dispatches near you (live queue + map)',
              ),
              SizedBox(height: isWide ? 16 : 12),
              Expanded(child: isWide ? _buildWideBody() : _buildNarrowBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNarrowBody() {
    return Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _mapCard(height: 220),
            const SizedBox(height: 14),
            _incidentsSection(),
            const SizedBox(height: 14),
            _statusSection(),
            const SizedBox(height: 14),
            _historySection(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildWideBody() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 1,
          child: Column(
            children: [
              Expanded(child: _incidentsSectionInExpanded()),
              const SizedBox(height: 16),
              Expanded(child: _statusSectionInExpanded()),
              const SizedBox(height: 16),
              Expanded(child: _historySectionInExpanded()),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(flex: 2, child: _mapCard()),
      ],
    );
  }

  Widget _incidentsSectionInExpanded() {
    if (_loading) {
      return const _RescueCardShell(
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return _RescueCardShell(child: Center(child: Text(_error!)));
    }
    final pending = _offerRows
        .where((m) => m['status']?.toString() == 'pending')
        .toList();

    return _RescueCardShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Text(
              'SOS Reports',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: pending.isEmpty
                ? const Center(
                    child: Text(
                      'No pending SOS.',
                      style: TextStyle(color: Colors.blueGrey),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: pending.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, i) {
                      final row = pending[i];
                      return _SosOfferCard(
                        row: row,
                        citizenNames: _citizenNames,
                        responding: _responding,
                        onAccept: () => _respond(row['id'].toString(), true, row),
                        onDecline: () => _respond(row['id'].toString(), false, row),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _statusSectionInExpanded() {
    return _statusSection();
  }

  Widget _historySectionInExpanded() {
    return _historySection();
  }
}

/// Badge text: first letter of each word capitalized (handles `en_route` → "En Route").
String _formatSosDispatchStatusForBadge(String? raw) {
  final s = raw?.trim() ?? '';
  if (s.isEmpty) return '—';
  return s
      .split(RegExp(r'[\s_]+'))
      .where((w) => w.isNotEmpty)
      .map((w) {
        final lower = w.toLowerCase();
        return '${lower[0].toUpperCase()}${lower.substring(1)}';
      })
      .join(' ');
}

class _SosOfferCard extends StatelessWidget {
  const _SosOfferCard({
    required this.row,
    required this.citizenNames,
    required this.responding,
    required this.onAccept,
    required this.onDecline,
  });

  final Map<String, dynamic> row;
  final Map<String, String> citizenNames;
  final Set<String> responding;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final rawDisp = row['sos_dispatches'];
    if (rawDisp is! Map) {
      return const SizedBox.shrink();
    }
    final disp = Map<String, dynamic>.from(rawDisp);

    final ticket = disp['ticket_number']?.toString() ?? '—';
    final lat = (disp['latitude'] as num?)?.toDouble();
    final lng = (disp['longitude'] as num?)?.toDouble();
    final uid = disp['user_id']?.toString();
    final name = (uid != null ? citizenNames[uid] : null) ?? 'Citizen';
    final phoneRaw = disp['caller_phone']?.toString().trim();
    final phoneDisplay =
        (phoneRaw != null && phoneRaw.isNotEmpty) ? phoneRaw : '—';
    final em = disp['emergency_main_category']?.toString();
    final es = disp['emergency_subcategory']?.toString();
    final eo = disp['emergency_other_note']?.toString();
    final typeLine = formatSosEmergencyTypeLine(em, es, eo);
    final dist = (row['distance_m'] as num?)?.toDouble();
    final distLabel = dist != null ? '${dist.round()} m away' : '';
    final offerId = row['id']?.toString() ?? '';
    final busy = responding.contains(offerId);

    final statusLabel =
        _formatSosDispatchStatusForBadge(disp['status']?.toString());

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.emergency_share, color: Colors.redAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ticket,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    statusLabel,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              name,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Text(
              phoneDisplay,
              style: TextStyle(
                color: Colors.blueGrey.shade700,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              typeLine,
              style: TextStyle(
                color: Colors.blueGrey.shade800,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            if (lat != null && lng != null)
              Text(
                '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
                style: TextStyle(
                  color: Colors.blueGrey.shade600,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            if (distLabel.isNotEmpty)
              Text(
                distLabel,
                style: TextStyle(
                  color: Colors.teal.shade800,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : onDecline,
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: busy ? null : onAccept,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                    ),
                    child: busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Accept'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SosHistoryCard extends StatelessWidget {
  const _SosHistoryCard({
    required this.row,
    required this.citizenNames,
  });

  final Map<String, dynamic> row;
  final Map<String, String> citizenNames;

  @override
  Widget build(BuildContext context) {
    final rawDisp = row['sos_dispatches'];
    if (rawDisp is! Map) return const SizedBox.shrink();
    final disp = Map<String, dynamic>.from(rawDisp);

    final ticket = disp['ticket_number']?.toString() ?? '—';
    final uid = disp['user_id']?.toString();
    final name = (uid != null ? citizenNames[uid] : null) ?? 'Citizen';
    final offerStatus = row['status']?.toString().trim().toLowerCase() ?? '';
    final dispatchStatus =
        disp['status']?.toString().trim().toLowerCase() ?? '';
    final badgeText = dispatchStatus == 'closed'
        ? 'Rescued'
        : (offerStatus == 'declined' ? 'Declined' : 'Accepted');
    final badgeColor = dispatchStatus == 'closed'
        ? const Color(0xFF2E7D32)
        : (offerStatus == 'declined'
            ? const Color(0xFFC62828)
            : const Color(0xFF1565C0));

    final respondedAt = DateTime.tryParse(
      (row['responded_at'] ?? row['created_at'] ?? '').toString(),
    );
    final when = respondedAt == null
        ? 'Time unavailable'
        : '${respondedAt.toLocal().year}-${respondedAt.toLocal().month.toString().padLeft(2, '0')}-${respondedAt.toLocal().day.toString().padLeft(2, '0')} '
            '${respondedAt.toLocal().hour.toString().padLeft(2, '0')}:${respondedAt.toLocal().minute.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          const Icon(Icons.history, color: Colors.blueGrey),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ticket,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 2),
                Text(
                  name,
                  style: TextStyle(
                    color: Colors.blueGrey.shade800,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  when,
                  style: TextStyle(
                    color: Colors.blueGrey.shade600,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              badgeText,
              style: TextStyle(
                color: badgeColor,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopTitle extends StatelessWidget {
  final String title;
  final String subtitle;
  const _TopTitle({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PersonShadowIcon(color: Colors.purple),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 22,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.blueGrey.shade600,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PersonShadowIcon extends StatelessWidget {
  final Color color;
  const _PersonShadowIcon({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 2,
            top: 3,
            child: Icon(
              Icons.person,
              size: 22,
              color: color.withValues(alpha: 0.25),
            ),
          ),
          Icon(Icons.person_outline, size: 22, color: color),
        ],
      ),
    );
  }
}

class _RescueCardShell extends StatelessWidget {
  final Widget child;
  const _RescueCardShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}
