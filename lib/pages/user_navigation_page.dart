import 'dart:async';

import 'package:first/services/flood_route_service.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart' as gnav;
import 'package:latlong2/latlong.dart';

class UserNavigationPage extends StatefulWidget {
  const UserNavigationPage({
    super.key,
    required this.initialOrigin,
    required this.destination,
    required this.initialHazardReports,
    this.destinationLabel,
  });

  final LatLng initialOrigin;
  final LatLng destination;
  final List<Map<String, dynamic>> initialHazardReports;
  final String? destinationLabel;

  @override
  State<UserNavigationPage> createState() => _UserNavigationPageState();
}

class _UserNavigationPageState extends State<UserNavigationPage> {
  static const Duration _rerouteDebounce = Duration(seconds: 10);
  static const Duration _hazardPollInterval = Duration(seconds: 45);
  static const int _maxIntermediateWaypoints = 18;
  static const double _waypointSpacingMeters = 55.0;

  gnav.GoogleNavigationViewController? _navViewController;
  StreamSubscription<gnav.OnArrivalEvent>? _arrivalSub;
  StreamSubscription<gnav.NavInfoEvent>? _navInfoSub;
  Timer? _hazardPoll;

  bool _sessionReady = false;
  bool _calculating = true;
  bool _isDisposed = false;
  String _statusText = 'Preparing navigation session...';
  String _routeStatus = 'pending';
  DateTime? _lastRerouteAt;
  List<LatLng> _backendPolyline = const <LatLng>[];
  List<Map<String, dynamic>> _latestHazards = const <Map<String, dynamic>>[];
  static const Distance _distance = Distance();

  @override
  void initState() {
    super.initState();
    _initializeAndStart();
    _hazardPoll = Timer.periodic(
      _hazardPollInterval,
      (_) => unawaited(_recalculateRoute(reason: 'Hazard scan update')),
    );
  }

  Future<void> _initializeAndStart() async {
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
        _sessionReady = true;
        _statusText = 'Navigation ready. Calculating safest route...';
        _latestHazards = widget.initialHazardReports;
      });
      _arrivalSub = gnav.GoogleMapsNavigator.setOnArrivalListener((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You arrived at your destination.')),
        );
      });
      _navInfoSub = gnav.GoogleMapsNavigator.setNavInfoListener((event) {
        if (!mounted) return;
        setState(() => _statusText = 'Guidance: ${event.navInfo.navState.name}');
      });
      await _recalculateRoute(reason: 'Initial route');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _calculating = false;
        _statusText = 'Navigation SDK init failed: $e';
      });
    }
  }

  Future<LatLng?> _readCurrentOrigin() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
        ),
      );
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  bool _rerouteDebounced() {
    final now = DateTime.now();
    final last = _lastRerouteAt;
    if (last != null && now.difference(last) < _rerouteDebounce) return true;
    _lastRerouteAt = now;
    return false;
  }

  Future<void> _recalculateRoute({required String reason}) async {
    if (!_sessionReady || _isDisposed) return;
    if (_rerouteDebounced()) return;
    setState(() {
      _calculating = true;
      _statusText = '$reason...';
    });

    final origin = await _readCurrentOrigin() ?? widget.initialOrigin;
    List<Map<String, dynamic>> hazards = widget.initialHazardReports;
    try {
      hazards = await FloodRouteService.fetchVerifiedHazardReports();
    } catch (_) {}
    _latestHazards = hazards;
    unawaited(_syncHazardOverlays());

    var result = await FloodRouteService.fetchRoadFollowingSafestRoute(
      origin: origin,
      destination: widget.destination,
      hazardReports: hazards,
    );

    // Trust the service's verdict. fetchRoadFollowingSafestRoute already runs
    // multi-deflection retries; if it returns 'best_effort' the route may
    // pass near reported floods (no clean alternative existed) - we surface
    // that as a banner instead of refusing to navigate.
    if (!mounted) return;
    if (!result.isUsable) {
      setState(() {
        _routeStatus = result.status;
        _calculating = false;
        _statusText = result.message;
        _backendPolyline = const <LatLng>[];
      });
      return;
    }

    final navWaypoints = _buildConstrainedWaypoints(result);

    try {
      final routeStatus = await gnav.GoogleMapsNavigator.setDestinations(
        gnav.Destinations(
          waypoints: navWaypoints,
          // Hide per-waypoint destination dots so the cluster of intermediate
          // safe-corridor waypoints doesn't visually look like extra route
          // segments. Routing/waypoint logic is unchanged - the SDK still
          // receives the same waypoints, only their default markers are off.
          displayOptions: gnav.NavigationDisplayOptions(
            showDestinationMarkers: false,
          ),
        ),
      );
      await gnav.GoogleMapsNavigator.startGuidance();
      if (_navViewController != null) {
        unawaited(
          _navViewController!.followMyLocation(
            gnav.CameraPerspective.tilted,
            zoomLevel: 17,
          ),
        );
        unawaited(_syncHazardOverlays());
      }
      setState(() {
        _routeStatus = routeStatus.name;
        _calculating = false;
        _statusText = result.isFloodSafe
            ? 'Live guidance via safest route (${result.status}).'
            : result.message;
        _backendPolyline = result.polyline;
      });
    } catch (e) {
      setState(() {
        _calculating = false;
        _routeStatus = 'failed';
        _statusText = 'Could not start navigation guidance: $e';
      });
    }
  }

  List<gnav.NavigationWaypoint> _buildConstrainedWaypoints(
    FloodRouteResult result,
  ) {
    final polyline = result.polyline;
    if (polyline.length < 2) {
      return <gnav.NavigationWaypoint>[
        gnav.NavigationWaypoint.withLatLngTarget(
          title: widget.destinationLabel ?? 'Destination',
          target: gnav.LatLng(
            latitude: widget.destination.latitude,
            longitude: widget.destination.longitude,
          ),
        ),
      ];
    }

    final densified = <LatLng>[polyline.first];
    for (int i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];
      final segmentMeters = _distance.as(LengthUnit.Meter, a, b);
      final segmentSteps = (segmentMeters / _waypointSpacingMeters)
          .floor()
          .clamp(1, 8);
      for (int step = 1; step <= segmentSteps; step++) {
        final t = step / segmentSteps;
        densified.add(
          LatLng(
            a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t,
          ),
        );
      }
    }

    final deduped = <LatLng>[densified.first];
    for (int i = 1; i < densified.length; i++) {
      final prev = deduped.last;
      final curr = densified[i];
      final d = _distance.as(LengthUnit.Meter, prev, curr);
      if (d >= (_waypointSpacingMeters * 0.5) || i == densified.length - 1) {
        deduped.add(curr);
      }
    }

    final interior = deduped.length > 2
        ? deduped.sublist(1, deduped.length - 1)
        : const <LatLng>[];
    final selected = <LatLng>[];
    if (interior.isNotEmpty) {
      if (interior.length <= _maxIntermediateWaypoints) {
        selected.addAll(interior);
      } else {
        final stride = interior.length / _maxIntermediateWaypoints;
        for (int i = 0; i < _maxIntermediateWaypoints; i++) {
          final idx = (i * stride).floor().clamp(0, interior.length - 1);
          selected.add(interior[idx]);
        }
      }
    }

    // Final dedupe pass against the destination - the SDK rejects waypoints
    // that round to the same location with DUPLICATE_WAYPOINTS_ERROR.
    const double minPairwiseMeters = 30.0;
    final orderedPoints = <LatLng>[
      for (final p in selected) p,
      widget.destination,
    ];
    final cleanedPoints = <LatLng>[];
    for (int i = 0; i < orderedPoints.length; i++) {
      final p = orderedPoints[i];
      if (cleanedPoints.isEmpty) {
        cleanedPoints.add(p);
        continue;
      }
      final last = cleanedPoints.last;
      final d = _distance.as(LengthUnit.Meter, last, p);
      if (d < minPairwiseMeters) {
        if (i == orderedPoints.length - 1) {
          // Always preserve the destination - drop the previous corridor
          // waypoint that's too close to it.
          cleanedPoints.removeLast();
          cleanedPoints.add(p);
        }
        continue;
      }
      cleanedPoints.add(p);
    }

    final navWaypoints = <gnav.NavigationWaypoint>[];
    for (int i = 0; i < cleanedPoints.length; i++) {
      final p = cleanedPoints[i];
      final isLast = i == cleanedPoints.length - 1;
      navWaypoints.add(
        gnav.NavigationWaypoint.withLatLngTarget(
          title: isLast
              ? (widget.destinationLabel ?? 'Destination')
              : 'Safe corridor',
          target: gnav.LatLng(latitude: p.latitude, longitude: p.longitude),
        ),
      );
    }
    return navWaypoints;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _hazardPoll?.cancel();
    _arrivalSub?.cancel();
    _navInfoSub?.cancel();
    unawaited(gnav.GoogleMapsNavigator.stopGuidance());
    unawaited(gnav.GoogleMapsNavigator.cleanup());
    super.dispose();
  }

  Future<void> _syncHazardOverlays() async {
    final controller = _navViewController;
    if (!_sessionReady || controller == null) return;
    try {
      await controller.clearCircles();
      await controller.clearMarkers();

      final circleOptions = <gnav.CircleOptions>[];
      final markerOptions = <gnav.MarkerOptions>[];
      for (final report in _latestHazards) {
        final decision = (report['admin_decision'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        if (decision != 'impassable' && decision != 'risky') continue;
        final lat = (report['latitude'] as num?)?.toDouble();
        final lng = (report['longitude'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        final isImpassable = decision == 'impassable';
        final stroke = isImpassable
            ? const Color(0xFFE53935).withAlpha(220)
            : Colors.orangeAccent.withAlpha(220);
        circleOptions.add(
          gnav.CircleOptions(
            position: gnav.LatLng(latitude: lat, longitude: lng),
            radius: isImpassable ? 150.0 : 80.0,
            strokeColor: stroke,
            strokeWidth: 2,
            fillColor: stroke.withAlpha(55),
            zIndex: 1,
          ),
        );
        if (isImpassable) {
          markerOptions.add(
            gnav.MarkerOptions(
              position: gnav.LatLng(latitude: lat, longitude: lng),
              infoWindow: const gnav.InfoWindow(title: 'Flood report'),
            ),
          );
        }
      }

      if (circleOptions.isNotEmpty) {
        await controller.addCircles(circleOptions);
      }
      if (markerOptions.isNotEmpty) {
        await controller.addMarkers(markerOptions);
      }
    } catch (e) {
      debugPrint('user nav hazard overlay sync failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D141D),
      appBar: AppBar(
        title: const Text('Safe Navigation'),
        backgroundColor: const Color(0xFF101A24),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          _buildStatusBanner(),
          Expanded(
            child: _sessionReady
                ? gnav.GoogleMapsNavigationView(
                    onViewCreated: (controller) {
                      _navViewController = controller;
                      unawaited(controller.setMyLocationEnabled(true));
                      unawaited(_syncHazardOverlays());
                    },
                    initialMapColorScheme: gnav.MapColorScheme.light,
                    initialNavigationUIEnabledPreference:
                        gnav.NavigationUIEnabledPreference.automatic,
                    initialForceNightMode: gnav.NavigationForceNightMode.forceDay,
                    initialCameraPosition: gnav.CameraPosition(
                      target: gnav.LatLng(
                        latitude: widget.initialOrigin.latitude,
                        longitude: widget.initialOrigin.longitude,
                      ),
                      zoom: 16,
                    ),
                  )
                : const Center(
                    child: CircularProgressIndicator(color: Color(0xFF00E4FF)),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner() {
    final color = switch (_routeStatus) {
      'safe' => const Color(0xFF00C853),
      'rerouted' => const Color(0xFFFFA000),
      'failed' || 'no_route' => const Color(0xFFE53935),
      _ => const Color(0xFF00E4FF),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      color: const Color(0xFF111A24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                'Status: ${_routeStatus.toUpperCase()}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              if (_calculating)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _statusText,
            style: TextStyle(
              color: Colors.blueGrey.shade100,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (_backendPolyline.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'FastAPI polyline points: ${_backendPolyline.length}',
              style: TextStyle(color: Colors.blueGrey.shade300, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
