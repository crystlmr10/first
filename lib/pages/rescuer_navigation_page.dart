import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:first/services/flood_route_service.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_navigation_flutter/google_navigation_flutter.dart' as gnav;
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RescuerNavigationPage extends StatefulWidget {
  const RescuerNavigationPage({
    super.key,
    required this.dispatchId,
    required this.initialOrigin,
    required this.initialDestination,
    required this.initialHazardReports,
    this.ticketNumber,
    this.initialPreferredPolyline = const <LatLng>[],
  });

  final String dispatchId;
  final String? ticketNumber;
  final LatLng initialOrigin;
  final LatLng initialDestination;
  final List<Map<String, dynamic>> initialHazardReports;
  final List<LatLng> initialPreferredPolyline;

  @override
  State<RescuerNavigationPage> createState() => _RescuerNavigationPageState();
}

class _RescuerNavigationPageState extends State<RescuerNavigationPage> {
  static const Distance _distance = Distance();
  static const double _destinationMoveMeters = 35.0;
  static const Duration _rerouteDebounce = Duration(seconds: 10);
  static const Duration _hazardPollInterval = Duration(seconds: 60);
  static const int _maxIntermediateWaypoints = 18;
  static const double _waypointSpacingMeters = 55.0;
  static const double _preferredRouteEndpointToleranceMeters = 220.0;
  static const double _offRouteToleranceMeters = 45.0;
  static const double _routeDestinationToleranceMeters = 90.0;
  static const double _stationaryToleranceMeters = 12.0;

  gnav.GoogleNavigationViewController? _navViewController;
  gnav.ImageDescriptor? _bluePinDescriptor;
  StreamSubscription<List<Map<String, dynamic>>>? _dispatchSub;
  StreamSubscription<gnav.OnArrivalEvent>? _arrivalSub;
  StreamSubscription<gnav.NavInfoEvent>? _navInfoSub;
  Timer? _hazardPoll;

  bool _sessionReady = false;
  bool _calculating = true;
  bool _isDisposed = false;
  String _statusText = 'Preparing navigation session...';
  String _routeStatus = 'pending';
  DateTime? _lastRerouteAt;
  LatLng? _lastRerouteOrigin;
  LatLng _destination = const LatLng(0, 0);
  LatLng _activeNavigationTarget = const LatLng(0, 0);
  bool _routingToSafeApproachPoint = false;
  int _safeApproachVictimOffsetMeters = 0;
  // Lock-until-far state for the safe-proxy waypoint. Once the backend picks
  // a safe approach point, we keep using it across reroutes unless the victim
  // drifts >50m or a new impassable hazard now covers the locked target.
  LatLng? _lockedSafeProxyTarget;
  LatLng? _lockedSafeProxyVictim;
  static const double _safeProxyLockVictimDriftMeters = 50.0;
  static const double _safeProxyLockHazardClearanceMeters = 150.0;
  // Static-state gate: skip a recalc if the rescuer has not moved at least
  // this far since the last calculation (treats the rescuer as parked).
  static const double _staticStateMoveThresholdMeters = 25.0;
  // Near-target gate: in safe-proxy mode, once the rescuer is within this
  // radius of the safe waypoint we stop recalculating to avoid flicker.
  static const double _nearTargetSkipRadiusMeters = 60.0;
  List<LatLng> _backendPolyline = const <LatLng>[];
  List<Map<String, dynamic>> _latestHazards = const <Map<String, dynamic>>[];
  String _lastHazardDigest = '';
  int? _distanceToFinalDestinationMeters;
  int? _timeToFinalDestinationSeconds;
  int? _fallbackDistanceToFinalMeters;
  int? _fallbackEtaToFinalSeconds;
  bool _arrivedAtPinDestination = false;
  bool _enRouteSynced = false;
  bool _closedSynced = false;
  bool _dispatchClosedRemotely = false;
  bool _routeUpdateSnackShown = false;
  static const double _finalArrivalToleranceMeters = 20.0;
  static const double _fallbackEtaMetersPerSecond = 8.33; // ~30 km/h

  @override
  void initState() {
    super.initState();
    _destination = widget.initialDestination;
    _activeNavigationTarget = widget.initialDestination;
    _latestHazards = widget.initialHazardReports;
    _initializeAndStart();
    _attachDispatchRealtime();
    _hazardPoll = Timer.periodic(
      _hazardPollInterval,
      (_) => unawaited(_recalculateRoute(reason: 'Periodic hazard scan')),
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
      });
      _arrivalSub = gnav.GoogleMapsNavigator.setOnArrivalListener((event) {
        unawaited(_handleArrivalEvent(event));
      });
      _navInfoSub = gnav.GoogleMapsNavigator.setNavInfoListener((event) {
        if (!mounted) return;
        final navState = event.navInfo.navState.name;
        setState(() {
          _statusText = 'Guidance: $navState';
          _distanceToFinalDestinationMeters =
              event.navInfo.distanceToFinalDestinationMeters;
          _timeToFinalDestinationSeconds =
              event.navInfo.timeToFinalDestinationSeconds;
        });
      });
      final preferred = _buildPreferredInitialResult();
      if (preferred != null) {
        await _startGuidanceForResult(
          origin: widget.initialOrigin,
          result: preferred,
          safeStatusText: 'Guiding via preview safest route.',
          showRouteUpdatedSnack: false,
        );
        // Preview points to the victim pin. Immediately force a proxy-aware
        // recalculation so the SDK swaps to the safe approach point if the
        // victim is inside an impassable flood area. Bypass the static-state
        // and debounce gates because this is the first real run of the trip.
        unawaited(
          _recalculateRoute(reason: 'Apply safe waypoint', force: true),
        );
      } else {
        await _recalculateRoute(
          reason: 'Initial route',
          force: true,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _calculating = false;
        _statusText = 'Navigation SDK init failed: $e';
      });
    }
  }

  Future<void> _handleArrivalEvent(gnav.OnArrivalEvent event) async {
    if (!mounted || _arrivedAtPinDestination) return;
    if (!_isFinalDestinationWaypoint(event.waypoint)) return;
    final nearPin = await _isNearPinDestination();
    if (!nearPin) return;
    setState(() {
      _arrivedAtPinDestination = true;
      _routeStatus = 'arrived';
      _statusText = 'Arrived at destination.';
    });
    await _markDispatchClosedIfNeeded();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Arrived at destination.')),
    );
  }

  bool _isFinalDestinationWaypoint(gnav.NavigationWaypoint waypoint) {
    final title = waypoint.title.trim().toLowerCase();
    if (title == 'safe corridor') return false;

    final target = waypoint.target;
    if (target == null) return false;

    final d = _distance.as(
      LengthUnit.Meter,
      LatLng(target.latitude, target.longitude),
      _activeNavigationTarget,
    );
    return d <= _finalArrivalToleranceMeters;
  }

  Future<bool> _isNearPinDestination() async {
    final current = await _readCurrentOrigin();
    if (current == null) return false;
    final d = _distance.as(LengthUnit.Meter, current, _activeNavigationTarget);
    final sdkRemaining = _distanceToFinalDestinationMeters;
    final sdkGateOk = sdkRemaining == null || sdkRemaining <= 25;
    return d <= _finalArrivalToleranceMeters && sdkGateOk;
  }

  Future<void> _endTrip() async {
    await gnav.GoogleMapsNavigator.stopGuidance();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  bool _isDispatchClosedStatus(dynamic rawStatus) {
    final status = (rawStatus ?? '').toString().trim().toLowerCase();
    return status == 'closed';
  }

  Future<void> _handleRemoteDispatchClosed() async {
    if (_dispatchClosedRemotely || !mounted) return;
    _dispatchClosedRemotely = true;
    _hazardPoll?.cancel();
    _hazardPoll = null;
    try {
      await gnav.GoogleMapsNavigator.stopGuidance();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _calculating = false;
      _routeStatus = 'closed';
      _statusText = 'Dispatch closed. Returning to map...';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Dispatch closed. Returning to map.'),
      ),
    );
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  void _attachDispatchRealtime() {
    _dispatchSub?.cancel();
    _dispatchSub = Supabase.instance.client
        .from('sos_dispatches')
        .stream(primaryKey: const ['id'])
        .eq('id', widget.dispatchId)
        .listen((rows) {
          if (rows.isEmpty || !mounted) return;
          final row = rows.first;
          if (_isDispatchClosedStatus(row['status'])) {
            unawaited(_handleRemoteDispatchClosed());
            return;
          }
          final lat = (row['latitude'] as num?)?.toDouble();
          final lng = (row['longitude'] as num?)?.toDouble();
          if (lat == null || lng == null) return;
          final next = LatLng(lat, lng);
          final moved = _distance.as(LengthUnit.Meter, _destination, next);
          if (moved < _destinationMoveMeters) return;
          setState(() {
            _destination = next;
            _statusText =
                'Citizen location updated (${moved.toStringAsFixed(0)}m). Recalculating...';
          });
          unawaited(_recalculateRoute(reason: 'Citizen location changed'));
        });
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

  Future<void> _recalculateRoute({
    required String reason,
    bool force = false,
  }) async {
    if (!_sessionReady || _isDisposed) return;
    if (_dispatchClosedRemotely) return;
    if (!force && _rerouteDebounced()) return;

    final origin = await _readCurrentOrigin() ?? widget.initialOrigin;

    // Static-state gate: do not recalculate if the rescuer has not moved
    // meaningfully since the last calculation. This avoids the periodic
    // hazard-scan timer churning the route while the rescuer is parked.
    if (!force) {
      final last = _lastRerouteOrigin;
      if (last != null) {
        final moved = _distance.as(LengthUnit.Meter, last, origin);
        if (moved < _staticStateMoveThresholdMeters) {
          return;
        }
      }
    }

    // Near-target gate: in safe-proxy mode, once the rescuer is close to the
    // safe waypoint we let Google Nav finish guidance without further
    // recomputations. Recalculating this close can produce flickering routes.
    if (!force && _routingToSafeApproachPoint) {
      final remaining = _distance.as(
        LengthUnit.Meter,
        origin,
        _activeNavigationTarget,
      );
      if (remaining <= _nearTargetSkipRadiusMeters) {
        return;
      }
    }

    setState(() {
      _calculating = true;
      _statusText = '$reason...';
    });
    List<Map<String, dynamic>> hazards = widget.initialHazardReports;
    try {
      hazards = await FloodRouteService.fetchVerifiedHazardReports();
    } catch (_) {}
    _latestHazards = hazards;
    unawaited(_syncHazardOverlays());

    final rerouteNeeded = _shouldReroute(
      origin: origin,
      destination: _destination,
      hazards: hazards,
    );
    if (!rerouteNeeded) {
      if (!mounted) return;
      setState(() {
        _calculating = false;
        _routeStatus = 'safe';
        _statusText = 'Guidance unchanged: current route still safe.';
      });
      return;
    }

    var result = await FloodRouteService.fetchRoadFollowingSafestRoute(
      origin: origin,
      destination: _destination,
      hazardReports: hazards,
      routeMode: 'sos_rescue',
      isSos: true,
      victimLocation: _destination,
    );

    // Apply lock-until-far so the rescuer's safe waypoint does not jump
    // around between reroutes. If the lock is still valid, refetch the route
    // toward the locked target so Google road-routes to a stable point.
    result = await _applySafeProxyLock(
      origin: origin,
      result: result,
      hazards: hazards,
    );

    // Trust the service's verdict. fetchRoadFollowingSafestRoute already
    // runs multi-deflection retries; if it returns 'best_effort' the route
    // may pass near reported floods (no clean alternative existed) - we
    // surface that as a banner instead of refusing to navigate.
    if (!mounted) return;
    if (!result.isUsable || !result.isFloodSafe) {
      setState(() {
        _routeStatus = 'no_route';
        _calculating = false;
        _statusText =
            'No safe route available right now. Waiting for route/hazard update.';
        _backendPolyline = const <LatLng>[];
        _routingToSafeApproachPoint = false;
        _safeApproachVictimOffsetMeters = 0;
      });
      return;
    }

    await _startGuidanceForResult(origin: origin, result: result);
  }

  bool _isSafeProxyLockStillValid({
    required LatLng currentVictim,
    required List<Map<String, dynamic>> hazards,
  }) {
    final locked = _lockedSafeProxyTarget;
    final lockedVictim = _lockedSafeProxyVictim;
    if (locked == null || lockedVictim == null) return false;

    final victimDrift = _distance.as(
      LengthUnit.Meter,
      lockedVictim,
      currentVictim,
    );
    if (victimDrift > _safeProxyLockVictimDriftMeters) return false;

    final impassable = FloodRouteService.extractHazardPoints(
      hazards,
      decisions: const {'impassable'},
    );
    for (final h in impassable) {
      final d = _distance.as(LengthUnit.Meter, locked, h);
      if (d < _safeProxyLockHazardClearanceMeters) return false;
    }
    return true;
  }

  Future<FloodRouteResult> _applySafeProxyLock({
    required LatLng origin,
    required FloodRouteResult result,
    required List<Map<String, dynamic>> hazards,
  }) async {
    // Clear the lock when not in proxy mode (victim no longer in flood).
    if (!result.isSafeProxyTarget) {
      _lockedSafeProxyTarget = null;
      _lockedSafeProxyVictim = null;
      return result;
    }

    // First proxy pick of this trip: lock the freshly-chosen target.
    if (_lockedSafeProxyTarget == null || _lockedSafeProxyVictim == null) {
      _lockedSafeProxyTarget = result.targetPoint ?? result.polyline.last;
      _lockedSafeProxyVictim = _destination;
      return result;
    }

    final lockValid = _isSafeProxyLockStillValid(
      currentVictim: _destination,
      hazards: hazards,
    );
    if (!lockValid) {
      // Drift or hazard change broke the lock; relock to the new pick.
      _lockedSafeProxyTarget = result.targetPoint ?? result.polyline.last;
      _lockedSafeProxyVictim = _destination;
      return result;
    }

    // Keep using the locked target. Refetch a road-following route toward it
    // (treated as a normal destination since it sits outside any flood zone)
    // so Google Nav has a stable point to road-route to.
    final locked = _lockedSafeProxyTarget!;
    final relock = await FloodRouteService.fetchRoadFollowingSafestRoute(
      origin: origin,
      destination: locked,
      hazardReports: hazards,
      routeMode: 'sos_rescue',
      isSos: false,
    );
    if (!relock.isUsable || !relock.isFloodSafe) {
      // Could not road-route to the locked target right now; relock to the
      // backend's freshest valid pick so guidance keeps working.
      _lockedSafeProxyTarget = result.targetPoint ?? result.polyline.last;
      _lockedSafeProxyVictim = _destination;
      return result;
    }

    final offsetM = _distance
        .as(LengthUnit.Meter, locked, _destination)
        .round();
    return FloodRouteResult(
      status: relock.status,
      message: relock.message,
      polyline: relock.polyline,
      routeNodeIds: relock.routeNodeIds,
      targetMode: 'safe_proxy',
      proxyReason: 'locked_safe_target',
      targetPoint: locked,
      victimPoint: _destination,
      victimOffsetMeters: offsetM,
    );
  }

  bool _shouldKeepCurrentRoute(
    LatLng origin,
    LatLng destination,
    List<Map<String, dynamic>> hazards,
  ) {
    if (_backendPolyline.length < 2) return false;

    final distanceToCurrentRoute = _minDistanceToPolylineMeters(
      origin,
      _backendPolyline,
    );
    if (distanceToCurrentRoute > _offRouteToleranceMeters) return false;

    final currentRouteDestinationGap = _distance.as(
      LengthUnit.Meter,
      _backendPolyline.last,
      destination,
    );
    if (currentRouteDestinationGap > _routeDestinationToleranceMeters) {
      return false;
    }

    final impassableHazards = FloodRouteService.extractHazardPoints(
      hazards,
      decisions: const {'impassable'},
    );
    if (impassableHazards.isEmpty) return true;

    final intersects = FloodRouteService.routeIntersectsHazards(
      _backendPolyline,
      impassableHazards,
      220.0,
      endpointToleranceMeters: 260.0,
    );
    return !intersects;
  }

  bool _shouldReroute({
    required LatLng origin,
    required LatLng destination,
    required List<Map<String, dynamic>> hazards,
  }) {
    if (_backendPolyline.length < 2) {
      _lastHazardDigest = _hazardDigest(hazards);
      return true;
    }

    final movedSinceLastReroute = _lastRerouteOrigin == null
        ? double.infinity
        : _distance.as(LengthUnit.Meter, _lastRerouteOrigin!, origin);
    final isStationary = movedSinceLastReroute <= _stationaryToleranceMeters;

    final offRoute =
        _minDistanceToPolylineMeters(origin, _backendPolyline) >
        _offRouteToleranceMeters;
    if (offRoute) {
      _lastHazardDigest = _hazardDigest(hazards);
      return true;
    }

    final destinationChanged =
        _distance.as(LengthUnit.Meter, _backendPolyline.last, destination) >
        _routeDestinationToleranceMeters;
    if (destinationChanged) {
      _lastHazardDigest = _hazardDigest(hazards);
      return true;
    }

    final routeUnsafeNow = !_shouldKeepCurrentRoute(origin, destination, hazards);
    if (routeUnsafeNow) {
      _lastHazardDigest = _hazardDigest(hazards);
      return true;
    }

    final newDigest = _hazardDigest(hazards);
    final hazardChanged = newDigest != _lastHazardDigest;
    _lastHazardDigest = newDigest;

    if (isStationary) return false;
    if (hazardChanged) return false;
    return false;
  }

  String _hazardDigest(List<Map<String, dynamic>> hazards) {
    final items = <String>[];
    for (final report in hazards) {
      final decision = (report['admin_decision'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (decision != 'impassable' && decision != 'risky') continue;
      final lat = (report['latitude'] as num?)?.toDouble();
      final lng = (report['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      final ts =
          (report['updated_at'] ?? report['created_at'] ?? '').toString().trim();
      items.add(
        '$decision:${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}:$ts',
      );
    }
    items.sort();
    return items.join('|');
  }

  double _minDistanceToPolylineMeters(LatLng point, List<LatLng> polyline) {
    if (polyline.isEmpty) return double.infinity;
    double minDistance = double.infinity;
    for (final p in polyline) {
      final d = _distance.as(LengthUnit.Meter, point, p);
      if (d < minDistance) {
        minDistance = d;
      }
    }
    return minDistance;
  }

  FloodRouteResult? _buildPreferredInitialResult() {
    final raw = widget.initialPreferredPolyline;
    if (raw.length < 2) return null;
    final first = raw.first;
    final last = raw.last;
    final startGap = _distance.as(
      LengthUnit.Meter,
      first,
      widget.initialOrigin,
    );
    final endGap = _distance.as(
      LengthUnit.Meter,
      last,
      widget.initialDestination,
    );
    // Only trust preview routes that still match this navigation session's
    // start/end. If rescuer or destination changed significantly, recalc.
    if (startGap > _preferredRouteEndpointToleranceMeters ||
        endGap > _preferredRouteEndpointToleranceMeters) {
      return null;
    }
    final cleaned = <LatLng>[raw.first];
    for (int i = 1; i < raw.length; i++) {
      final p = raw[i];
      final d = _distance.as(LengthUnit.Meter, cleaned.last, p);
      if (d >= 4.0 || i == raw.length - 1) {
        cleaned.add(p);
      }
    }
    if (cleaned.length < 2) return null;
    return FloodRouteResult(
      status: 'safe',
      message: 'Preview safest route loaded.',
      polyline: cleaned,
      routeNodeIds: const <String>[],
    );
  }

  Future<void> _startGuidanceForResult({
    required LatLng origin,
    required FloodRouteResult result,
    String? safeStatusText,
    bool showRouteUpdatedSnack = true,
  }) async {
    // Resolve the actual driving target FIRST so waypoint construction below
    // uses the safe-proxy point (when applicable) instead of the stale
    // _activeNavigationTarget which still points at the victim during the
    // first proxy refresh after preview.
    final effectiveDestination = result.targetPoint ?? result.polyline.last;
    _activeNavigationTarget = effectiveDestination;
    final navWaypoints = _buildConstrainedWaypoints(
      result,
      target: effectiveDestination,
    );
    final fallbackDistance = _estimateRemainingDistanceMeters(
      origin: origin,
      route: result.polyline,
      destination: effectiveDestination,
    );
    final fallbackEta = (fallbackDistance / _fallbackEtaMetersPerSecond).ceil();
    try {
      // In safe-proxy mode the only acceptable route is the one that ends at
      // the chosen safe approach point and avoids the impassable flood zone.
      // Disable the SDK's alternative-route suggestions so the rescuer cannot
      // accidentally swipe to a flood-crossing alt (the SDK does not let us
      // filter alternatives by hazard radius client-side). Normal trips keep
      // the default behavior.
      final routingOptions = result.isSafeProxyTarget
          ? gnav.RoutingOptions(
              alternateRoutesStrategy:
                  gnav.NavigationAlternateRoutesStrategy.none,
            )
          : null;
      final routeStatus = await gnav.GoogleMapsNavigator.setDestinations(
        gnav.Destinations(
          waypoints: navWaypoints,
          displayOptions: gnav.NavigationDisplayOptions(
            // Show the SDK destination marker so the rescuer sees a pin at
            // the actual driving target (the safe approach point in proxy
            // mode, or the destination in normal mode). Without this the only
            // visible pin is our custom blue victim pin, which makes it look
            // like the route is heading to the victim.
            showDestinationMarkers: true,
          ),
          routingOptions: routingOptions,
        ),
      );
      await gnav.GoogleMapsNavigator.startGuidance();
      if (_navViewController != null) {
        // Camera follows the rescuer's GPS heading (tilted 3D perspective)
        // so the on-screen arrow always matches the actual driving direction.
        // Previously we used showRouteOverview(), which locks to north-up and
        // makes the arrow look like it contradicts the heading.
        unawaited(
          _navViewController!.followMyLocation(
            gnav.CameraPerspective.tilted,
            zoomLevel: 17,
          ),
        );
        unawaited(_syncHazardOverlays());
        unawaited(_renderBlueOriginDestinationPins());
      }
      if (!mounted) return;
      setState(() {
        _routeStatus = routeStatus.name;
        _calculating = false;
        _statusText = result.isSafeProxyTarget
            ? 'Exact victim location unreachable by vehicle.'
            : (result.isFloodSafe
                ? (safeStatusText ??
                    'Guiding via safest route (${result.status}).')
                : result.message);
        _backendPolyline = result.polyline;
        _activeNavigationTarget = effectiveDestination;
        _routingToSafeApproachPoint = result.isSafeProxyTarget;
        _safeApproachVictimOffsetMeters =
            result.isSafeProxyTarget ? result.victimOffsetMeters : 0;
        _lastRerouteOrigin = origin;
        _lastHazardDigest = _hazardDigest(_latestHazards);
        _fallbackDistanceToFinalMeters = fallbackDistance;
        _fallbackEtaToFinalSeconds = fallbackEta;
        _arrivedAtPinDestination = false;
      });
      if (showRouteUpdatedSnack && mounted) {
        if (!_routeUpdateSnackShown) {
          _routeUpdateSnackShown = true;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.isFloodSafe
                    ? 'Route updated for flood safety.'
                    : 'Route updated. Caution: it may pass near a reported flood.',
              ),
            ),
          );
        }
      }
      unawaited(_markDispatchEnRouteIfNeeded());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _calculating = false;
        _routeStatus = 'failed';
        _statusText = 'Could not start navigation guidance: $e';
      });
    }
  }

  Future<void> _markDispatchEnRouteIfNeeded() async {
    if (_enRouteSynced || widget.dispatchId.trim().isEmpty) return;
    try {
      final rpcResult = await Supabase.instance.client.rpc(
        'set_dispatch_en_route',
        params: {'p_dispatch_id': widget.dispatchId},
      );
      if (rpcResult == true || rpcResult == 'true') {
        _enRouteSynced = true;
        return;
      }
    } catch (_) {
      // Fallback below for environments where the RPC is not deployed yet.
    }

    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      await Supabase.instance.client
          .from('sos_dispatches')
          .update({'status': 'en_route'})
          .eq('id', widget.dispatchId)
          .eq('assigned_rescuer_id', uid)
          .inFilter('status', ['received', 'dispatching', 'en_route']);
      _enRouteSynced = true;
    } catch (e) {
      debugPrint('Failed to mark dispatch en_route: $e');
    }
  }

  Future<void> _markDispatchClosedIfNeeded() async {
    if (_closedSynced || widget.dispatchId.trim().isEmpty) return;
    try {
      final rpcResult = await Supabase.instance.client.rpc(
        'set_dispatch_closed',
        params: {'p_dispatch_id': widget.dispatchId},
      );
      if (rpcResult == true || rpcResult == 'true') {
        _closedSynced = true;
        if (mounted) {
          setState(() {
            _routeStatus = 'closed';
            _statusText = 'Dispatch closed: rescuer arrived at destination.';
          });
        }
        return;
      }
    } catch (_) {
      // Fallback below for environments where the RPC is not deployed yet.
    }

    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      await Supabase.instance.client
          .from('sos_dispatches')
          .update({'status': 'closed'})
          .eq('id', widget.dispatchId)
          .eq('assigned_rescuer_id', uid)
          .inFilter('status', ['dispatching', 'en_route', 'closed']);
      _closedSynced = true;
      if (mounted) {
        setState(() {
          _routeStatus = 'closed';
          _statusText = 'Dispatch closed: rescuer arrived at destination.';
        });
      }
    } catch (e) {
      debugPrint('Failed to mark dispatch closed: $e');
    }
  }

  List<gnav.NavigationWaypoint> _buildConstrainedWaypoints(
    FloodRouteResult result, {
    required LatLng target,
  }) {
    // Safe-proxy mode: the backend already chose a single drivable safe
    // waypoint near the flood perimeter. Hand exactly ONE waypoint to Google
    // Nav so it can produce a clean road-following polyline. Adding
    // intermediate corridor waypoints here is what causes the multi-leg
    // "extra nodes/edges" artifacts visible on the map.
    if (result.isSafeProxyTarget) {
      return <gnav.NavigationWaypoint>[
        gnav.NavigationWaypoint.withLatLngTarget(
          title: 'Nearest safe approach',
          target: gnav.LatLng(
            latitude: target.latitude,
            longitude: target.longitude,
          ),
        ),
      ];
    }

    final hasHazards = _latestHazards.any((report) {
      final decision = (report['admin_decision'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      return decision == 'impassable' || decision == 'risky';
    });
    if (!hasHazards) {
      return <gnav.NavigationWaypoint>[
        gnav.NavigationWaypoint.withLatLngTarget(
          title: widget.ticketNumber ?? 'Destination',
          target: gnav.LatLng(
            latitude: target.latitude,
            longitude: target.longitude,
          ),
        ),
      ];
    }

    final polyline = result.polyline;
    if (polyline.length < 2) {
      return <gnav.NavigationWaypoint>[
        gnav.NavigationWaypoint.withLatLngTarget(
          title: widget.ticketNumber ?? 'Citizen SOS',
          target: gnav.LatLng(
            latitude: target.latitude,
            longitude: target.longitude,
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
    final orderedPoints = <LatLng>[for (final p in selected) p, target];
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

    // Remove intermediate points that are too close to the final target; these
    // can create tiny visual "extra node/edge" artifacts near destination.
    final destinationPoint = cleanedPoints.isNotEmpty
        ? cleanedPoints.last
        : target;
    final prunedPoints = <LatLng>[];
    for (int i = 0; i < cleanedPoints.length; i++) {
      final p = cleanedPoints[i];
      final isLast = i == cleanedPoints.length - 1;
      if (!isLast) {
        final dToDestination = _distance.as(
          LengthUnit.Meter,
          p,
          destinationPoint,
        );
        if (dToDestination < 120.0) {
          continue;
        }
      }
      prunedPoints.add(p);
    }
    if (prunedPoints.length >= 2) {
      final beforeLast = prunedPoints[prunedPoints.length - 2];
      final last = prunedPoints.last;
      final tailGap = _distance.as(LengthUnit.Meter, beforeLast, last);
      if (tailGap < 70.0) {
        prunedPoints.removeAt(prunedPoints.length - 2);
      }
    }
    if (prunedPoints.isEmpty) {
      prunedPoints.add(target);
    }

    final waypoints = <gnav.NavigationWaypoint>[];
    for (int i = 0; i < prunedPoints.length; i++) {
      final p = prunedPoints[i];
      final isLast = i == prunedPoints.length - 1;
      waypoints.add(
        gnav.NavigationWaypoint.withLatLngTarget(
          title: isLast
              ? (widget.ticketNumber ?? 'Citizen SOS')
              : 'Safe corridor',
          target: gnav.LatLng(latitude: p.latitude, longitude: p.longitude),
        ),
      );
    }
    return waypoints;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _dispatchSub?.cancel();
    _hazardPoll?.cancel();
    _arrivalSub?.cancel();
    _navInfoSub?.cancel();
    final blueDescriptor = _bluePinDescriptor;
    if (blueDescriptor != null) {
      unawaited(gnav.unregisterImage(blueDescriptor));
    }
    unawaited(gnav.GoogleMapsNavigator.stopGuidance());
    unawaited(gnav.GoogleMapsNavigator.cleanup());
    super.dispose();
  }

  Future<void> _renderBlueOriginDestinationPins() async {
    final controller = _navViewController;
    if (controller == null) return;
    try {
      final blueIcon = await _ensureBluePinDescriptor();
      await controller.clearMarkers();
      final markers = <gnav.MarkerOptions>[
        if (_routingToSafeApproachPoint)
          gnav.MarkerOptions(
            position: gnav.LatLng(
              latitude: _destination.latitude,
              longitude: _destination.longitude,
            ),
            // Keep one custom marker only: victim exact location.
            // Safe waypoint marker is the SDK destination marker to avoid duplicates.
            icon: blueIcon,
            infoWindow: const gnav.InfoWindow(title: 'Victim exact location'),
          ),
      ];
      await controller.addMarkers(markers);
    } catch (e) {
      debugPrint('Failed to render blue origin/destination pins: $e');
    }
  }

  Future<void> _syncHazardOverlays() async {
    final controller = _navViewController;
    if (!_sessionReady || controller == null) return;
    try {
      await controller.clearCircles();
      final circleOptions = <gnav.CircleOptions>[];
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
      }
      if (circleOptions.isNotEmpty) {
        await controller.addCircles(circleOptions);
      }
    } catch (e) {
      debugPrint('rescuer nav hazard overlay sync failed: $e');
    }
  }

  Future<gnav.ImageDescriptor> _ensureBluePinDescriptor() async {
    final existing = _bluePinDescriptor;
    if (existing != null) return existing;
    final byteData = await _buildPinIconByteData(const Color(0xFF1E88E5));
    final descriptor = await gnav.registerBitmapImage(
      bitmap: byteData,
      imagePixelRatio: 2,
      width: 36,
      height: 44,
    );
    _bluePinDescriptor = descriptor;
    return descriptor;
  }

  Future<ByteData> _buildPinIconByteData(Color fillColor) async {
    const width = 72.0;
    const height = 88.0;
    const cx = width / 2;
    const circleRadius = 24.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, width, height));

    final fill = Paint()
      ..color = fillColor
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..isAntiAlias = true;

    canvas.drawCircle(const Offset(cx, 30), circleRadius, fill);
    canvas.drawCircle(const Offset(cx, 30), circleRadius, stroke);

    final tail = ui.Path()
      ..moveTo(cx, 80)
      ..lineTo(cx - 13, 47)
      ..lineTo(cx + 13, 47)
      ..close();
    canvas.drawPath(tail, fill);
    canvas.drawPath(tail, stroke);

    canvas.drawCircle(
      const Offset(cx, 30),
      8,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..isAntiAlias = true,
    );

    final image = await recorder.endRecording().toImage(
      width.toInt(),
      height.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      throw Exception('Could not encode blue pin icon.');
    }
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D141D),
      appBar: AppBar(
        title: Text(widget.ticketNumber ?? 'Rescuer Navigation'),
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
                      unawaited(controller.setNavigationHeaderEnabled(false));
                      unawaited(controller.setNavigationFooterEnabled(false));
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
          if (_arrivedAtPinDestination)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _endTrip,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00C853),
                      foregroundColor: const Color(0xFF0D141D),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text(
                      'End Trip',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ),
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
          if (_routingToSafeApproachPoint) ...[
            const SizedBox(height: 4),
            Text(
              'Routing to nearest safe approach point '
              '(${_safeApproachVictimOffsetMeters}m from victim).',
              style: TextStyle(
                color: Colors.amber.shade200,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (_effectiveDistanceToFinalMeters != null ||
              _effectiveEtaToFinalSeconds != null) ...[
            const SizedBox(height: 4),
            Text(
              'ETA ${_formatEta(_effectiveEtaToFinalSeconds)}  |  '
              'Distance ${_formatDistanceMeters(_effectiveDistanceToFinalMeters)}',
              style: TextStyle(
                color: Colors.blueGrey.shade50,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
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

  int? get _effectiveDistanceToFinalMeters =>
      _distanceToFinalDestinationMeters ?? _fallbackDistanceToFinalMeters;
  int? get _effectiveEtaToFinalSeconds =>
      _timeToFinalDestinationSeconds ?? _fallbackEtaToFinalSeconds;

  int _estimateRemainingDistanceMeters({
    required LatLng origin,
    required List<LatLng> route,
    required LatLng destination,
  }) {
    if (route.length < 2) {
      return _distance.as(LengthUnit.Meter, origin, destination).round();
    }

    var closestIdx = 0;
    var minDistance = double.infinity;
    for (var i = 0; i < route.length; i++) {
      final d = _distance.as(LengthUnit.Meter, origin, route[i]);
      if (d < minDistance) {
        minDistance = d;
        closestIdx = i;
      }
    }

    double total = 0;
    var prev = origin;
    for (var i = closestIdx; i < route.length; i++) {
      final curr = route[i];
      total += _distance.as(LengthUnit.Meter, prev, curr);
      prev = curr;
    }
    total += _distance.as(LengthUnit.Meter, prev, destination);
    return total.round();
  }

  String _formatDistanceMeters(int? meters) {
    if (meters == null || meters <= 0) return '--';
    if (meters < 1000) return '$meters m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  String _formatEta(int? seconds) {
    if (seconds == null || seconds <= 0) return '--';
    final totalMinutes = (seconds / 60).ceil();
    if (totalMinutes < 60) return '$totalMinutes min';
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    if (mins == 0) return '$hours hr';
    return '$hours hr $mins min';
  }
}
