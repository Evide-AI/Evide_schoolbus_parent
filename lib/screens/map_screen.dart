import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config.dart';
import '../models/models.dart';
import '../services/parent_service.dart';
import '../theme.dart';
import '../utils/route_geometry.dart';
import '../utils/route_trail.dart';
import 'change_password_screen.dart';
import 'notifications_screen.dart';

enum _MarkerKind { school, stop, bus }

// Which way the front of assets/bus_top.png points in the original image.
// If the bus drives "backwards" on the map, flip this to true.
const bool _busImageFacesRight = false;

// Below this speed we don't trust GPS heading (jitter at stops).
const double _minSpeedForHeading = 3; // km/h
// Minimum movement before we compute direction from two positions.
const double _minMoveForHeading = 5; // metres
// Older than this, the bus is treated as offline.
const Duration _staleAfter = Duration(minutes: 5);

// --- Yellow line: where the bus is heading next for this child ---
// The trip stage (from the backend) decides the target:
//   waiting / reached  -> bus to the child's stop
//   picked_up          -> bus to the school
//   anything else (absent, at_school, dropped) -> no yellow line
// While the bus is on the blue route the yellow line is cut out of the blue
// route itself (same coordinates, so it can never be misaligned). When the bus
// is elsewhere (coming from the depot, another road) it follows the road from
// the bus to the target instead.
// The blue line (school <-> stop) is always drawn.
const double _trailToleranceM = 60; // farther than this from blue = off the blue route

// --- Camera ---
// Zoom used when centring on the bus (first view, switching child, recenter).
const double _busZoom = 15;
// The camera only moves on first load, when switching child, when the bus
// first appears, and while "following" the bus. Refresh / GPS pings / app
// resume never reset the user's zoom. Following stops as soon as the user
// touches the map, and the "Bus" button turns it back on.

// Optional custom marker images. Drop your own PNGs at these paths (square,
// ~512x512, transparent background, subject centred — the point of a pin
// should sit at the bottom edge, since markers are anchored there).
// If a file is missing, the app falls back to the pin drawn in code, so
// nothing breaks before you add them.
const String _schoolMarkerAsset = 'assets/markers/school_marker.png';
const String _studentMarkerAsset = 'assets/markers/student_marker.png';
// On-screen size of the custom images. Raise for bigger markers.
const double _customMarkerIconSize = 0.55;

// Live updates arrive over Supabase Realtime (a WebSocket). If that socket
// drops — patchy mobile data, or Android freezing the app in the background —
// we fall back to asking for the latest position on a timer until it's back.
const Duration _fallbackPollInterval = Duration(seconds: 20);

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final _service = ParentService();

  MapboxMap? _map;
  PointAnnotationManager? _pointManager;
  PolylineAnnotationManager? _lineManager;

  List<Child> _children = [];
  int _selectedIndex = 0;
  bool _loading = true;
  bool _refreshing = false;
  DateTime? _lastRefreshed;
  String? _error;

  final List<RealtimeChannel> _channels = [];

  // Realtime (WebSocket) health: true once the position channels have joined.
  // While it's false, _pollTimer fetches positions on a timer instead.
  bool _liveConnected = false;
  Timer? _pollTimer;

  // Per-bus direction state (keyed by bus id).
  final Map<String, bool> _busFacingRight = {};
  final Map<String, ({double lat, double lng})> _lastBusPoint = {};

  // One slicer per route, keyed by the routeLine list itself, so it rebuilds
  // automatically whenever the route is recomputed.
  final Expando<RouteSlicer> _slicers = Expando<RouteSlicer>();

  // Road path bus -> target, used when the bus is not on the blue route.
  // Cached per child and only re-requested when the bus has moved or the
  // target changed, so we don't call Mapbox Directions on every GPS ping.
  final Map<String, _RoadYellow> _yellowRoad = {};
  bool _yellowBusy = false;

  // Camera state.
  // _framedChildId: child the camera was last framed for (null = needs framing).
  // _framedOnBus: whether that framing was centred on the bus (false when the
  //   bus had no position yet, so we re-centre once it appears).
  // _followBus: camera follows the bus until the user touches the map.
  String? _framedChildId;
  bool _framedOnBus = false;
  bool _followBus = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    MapboxOptions.setAccessToken(AppConfig.mapboxPublicToken);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    for (final ch in _channels) {
      ch.unsubscribe();
    }
    super.dispose();
  }

  /// Android and iOS suspend the WebSocket while the app is in the background,
  /// and it doesn't always come back on its own. Reconnecting on resume is what
  /// keeps tracking live after the parent locks their phone and returns.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _children.isNotEmpty) {
      _load(silent: true);
    }
  }

  /// Safety net for when the socket is down: ask for the latest position
  /// directly. Stops as soon as Realtime is connected again.
  void _startFallbackPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_fallbackPollInterval, (_) async {
      if (!mounted || _liveConnected) return;
      for (final child in _children) {
        final bus = child.bus;
        if (bus == null) continue;
        final stage = await _service.fetchTripStage(child.id);
        if (stage != null) child.tripStage = stage;
        final st = await _service.fetchBusStatus(bus.id);
        if (st != null && st != bus.status) {
          child.bus = BusInfo(id: bus.id, busNumber: bus.busNumber, status: st);
        }
        final pos = await _service.fetchBusPosition(bus.id);
        if (pos == null) continue;
        child.livePosition = pos;
        _updateFacing(bus.id.toString(), pos.lat, pos.lng, pos.heading, pos.speedKmh);
      }
      if (mounted) {
        setState(() => _lastRefreshed = DateTime.now());
        _redraw();
      }
    });
  }

  /// Loads everything: children, their routes, and live bus positions.
  /// [silent] keeps the map on screen (used by the refresh button) instead of
  /// replacing it with a full-screen spinner. Neither mode touches the camera
  /// once it has been framed.
  Future<void> _load({bool silent = false}) async {
    setState(() {
      if (silent) {
        _refreshing = true;
      } else {
        _loading = true;
      }
      _error = null;
    });

    // Drop existing realtime subscriptions, or a refresh would stack a second
    // set of listeners on top of the first.
    for (final ch in _channels) {
      ch.unsubscribe();
    }
    _channels.clear();
    _liveConnected = false;

    try {
      final children = await _service.loadChildren();
      if (children.isEmpty) {
        setState(() {
          _error =
              'No children are linked to your account yet. Contact your school office.';
          _loading = false;
          _refreshing = false;
        });
        return;
      }

      // Base route (school <-> stop) can be drawn right away from the fixed
      // coordinates. Live bus position is fetched too, but the map is useful
      // even before any GPS data exists.
      for (final child in children) {
        await _computeSchoolStopRoute(child);

        final bus = child.bus;
        if (bus == null) continue;
        final pos = await _service.fetchBusPosition(bus.id);
        child.livePosition = pos;
        if (pos != null) {
          _updateFacing(bus.id.toString(), pos.lat, pos.lng, pos.heading,
              pos.speedKmh);
        }

        final channel = _service.subscribeBusPosition(
          bus.id,
          (newPos) {
            child.livePosition = newPos;
            _updateFacing(bus.id.toString(), newPos.lat, newPos.lng,
                newPos.heading, newPos.speedKmh);
            if (mounted) setState(() => _lastRefreshed = DateTime.now());
            _redraw();
          },
          onConnectionChange: (connected) {
            if (!mounted) return;
            setState(() => _liveConnected = connected);
          },
        );
        _channels.add(channel);

        _channels.add(_service.subscribeBusStatus(bus.id, (status) {
          child.bus = BusInfo(
              id: bus.id, busNumber: bus.busNumber, status: status);
          if (mounted) setState(() {});
          _redraw();
        }));

        // Where this child is on today's trip (waiting / reached / picked_up
        // / absent / at_school / dropped). Decides what the yellow line shows.
        child.tripStage = await _service.fetchTripStage(child.id);
        _channels.add(_service.subscribeTripStage(child.id, (stage) {
          child.tripStage = stage;
          if (mounted) setState(() {});
          _redraw();
        }));
      }

      setState(() {
        _children = children;
        _loading = false;
        _refreshing = false;
        _lastRefreshed = DateTime.now();
      });
      _startFallbackPolling();
      _redraw();
    } catch (e) {
      setState(() {
        // On a refresh, keep showing the map we already have.
        if (!silent) _error = 'Could not load your children. Pull to retry.';
        _loading = false;
        _refreshing = false;
      });
      if (silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not refresh. Check your connection.')),
        );
      }
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    await _load(silent: true);
  }

  // This child's blue route as plain points, or null when there's no route.
  List<GeoPoint>? _routePoints(Child child) {
    final line = child.routeLine;
    if (line == null || line.length < 2) return null;
    // routeLine holds [lng, lat] pairs.
    return line.map((c) => GeoPoint(c[1], c[0])).toList();
  }

  // True / false when the bus is on or off the blue route; null when we can't
  // tell (no live position or no route yet).
  bool? _isBusOnRoute(Child child) {
    final pos = child.livePosition;
    final route = _routePoints(child);
    if (pos == null || route == null) return null;
    return isOnRoute(GeoPoint(pos.lat, pos.lng), route,
        toleranceMetres: _trailToleranceM);
  }

  // What the yellow line should lead to, or null when there should be none:
  //   'stop'   the bus is still coming to this child's stop
  //   'school' the child is on board and the bus is heading to school
  // No yellow when the trip isn't running, the bus has no signal, the child
  // was marked absent, the bus is at school, or the child has been dropped.
  String? _yellowTargetKind(Child child) {
    final bus = child.bus;
    final pos = child.livePosition;
    if (bus == null || pos == null || bus.status != 'running') return null;

    // Stale GPS: don't draw a yellow line to a position that may be wrong.
    final t = pos.recordedAt;
    if (t != null && DateTime.now().difference(t) > _staleAfter) return null;

    switch (child.tripStage) {
      case 'waiting':
      case 'reached':
        return 'stop';
      case 'picked_up':
        return 'school';
      default: // absent, at_school, dropped, or no trip info yet
        return null;
    }
  }

  // The yellow line for this child, as points from the bus to its target.
  Future<List<LL>?> _yellowFor(Child child) async {
    final kind = _yellowTargetKind(child);
    final pos = child.livePosition;
    if (kind == null || pos == null) {
      _yellowRoad.remove(child.id);
      return null;
    }

    final stopLat = child.pickupLat ?? child.dropLat;
    final stopLng = child.pickupLng ?? child.dropLng;
    final targetLat = kind == 'stop' ? stopLat : child.school.lat;
    final targetLng = kind == 'stop' ? stopLng : child.school.lng;
    if (targetLat == null || targetLng == null) return null;

    // 1. Bus is on the blue route: cut the yellow line out of it.
    final line = child.routeLine;
    if (line != null && line.length >= 2 && stopLat != null && stopLng != null) {
      // routeLine holds [lng, lat] pairs, and runs school -> stop.
      final slicer = _slicers[line] ??= RouteSlicer(
        line.map((c) => LL(c[1].toDouble(), c[0].toDouble())).toList(),
      );
      final bus = slicer.snap(LL(pos.lat, pos.lng));
      if (bus.off <= _trailToleranceM) {
        if (kind == 'stop') {
          final stop = slicer.snap(LL(stopLat, stopLng));
          if (bus.along >= stop.along - 5) return null; // at the stop
          return slicer.slice(bus, stop);
        } else {
          if (bus.along <= 5) return null; // at the school
          return slicer.head(bus).reversed.toList(); // bus -> school
        }
      }
    }

    // 2. Bus is somewhere else: follow the road from the bus to the target.
    return _roadYellow(child, kind, pos, targetLat, targetLng);
  }

  // Road path bus -> target via Mapbox Directions (straight line if that
  // fails). Refreshed when the bus has moved ~100 m, the target changed, or
  // 30 s passed.
  Future<List<LL>?> _roadYellow(
    Child child,
    String kind,
    BusPosition pos,
    double toLat,
    double toLng,
  ) async {
    final key = '$kind:$toLat,$toLng';
    final cached = _yellowRoad[child.id];
    final fresh = cached != null &&
        cached.key == key &&
        DateTime.now().difference(cached.at).inSeconds < 30 &&
        _distanceM(cached.fromLat, cached.fromLng, pos.lat, pos.lng) < 100;
    if (fresh) return cached!.line;
    if (_yellowBusy) return (cached != null && cached.key == key) ? cached.line : null;

    _yellowBusy = true;
    try {
      final road = await _service.fetchRoadRoute(
        fromLat: pos.lat,
        fromLng: pos.lng,
        toLat: toLat,
        toLng: toLng,
      );
      final points = road != null
          ? road.map((c) => LL(c[1], c[0])).toList() // [lng, lat] -> LL
          : [LL(pos.lat, pos.lng), LL(toLat, toLng)];
      _yellowRoad[child.id] = _RoadYellow(
        key: key,
        line: points,
        fromLat: pos.lat,
        fromLng: pos.lng,
      );
      return points;
    } finally {
      _yellowBusy = false;
    }
  }

  // Decides whether the bus should face left or right. Only changes when the
  // bus is actually moving, so it doesn't flip back and forth at a stop.
  void _updateFacing(
      String busId, double lat, double lng, num? heading, num? speedKmh) {
    final prev = _lastBusPoint[busId];

    double? dir;
    if (heading != null && (speedKmh ?? 0) >= _minSpeedForHeading) {
      dir = heading.toDouble();
    } else if (prev != null &&
        _distanceM(prev.lat, prev.lng, lat, lng) > _minMoveForHeading) {
      dir = _bearing(prev.lat, prev.lng, lat, lng);
    }

    // Only remember the point once it has moved enough (or it's the first).
    if (prev == null || dir != null) {
      _lastBusPoint[busId] = (lat: lat, lng: lng);
    }
    if (dir == null) return; // keep last facing

    // 0° = north, 90° = east. Eastbound half → face right.
    final d = (dir % 360 + 360) % 360;
    if (d == 0 || d == 180) return; // straight north/south: keep last facing
    _busFacingRight[busId] = d > 0 && d < 180;
  }

  double _bearing(double lat1, double lng1, double lat2, double lng2) {
    final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final dl = (lng2 - lng1) * math.pi / 180;
    final y = math.sin(dl) * math.cos(p2);
    final x = math.cos(p1) * math.sin(p2) -
        math.sin(p1) * math.cos(p2) * math.cos(dl);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  double _distanceM(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final x = (lng2 - lng1) *
        math.pi /
        180 *
        math.cos((lat1 + lat2) / 2 * math.pi / 180);
    final y = (lat2 - lat1) * math.pi / 180;
    return math.sqrt(x * x + y * y) * r;
  }

  // The main road route between the school and this child's stop. Always
  // drawable (both are fixed coordinates), so it shows even before the bus is
  // live. Falls back to a straight line if Mapbox Directions is unavailable.
  Future<void> _computeSchoolStopRoute(Child child) async {
    final stopLat = child.pickupLat ?? child.dropLat;
    final stopLng = child.pickupLng ?? child.dropLng;
    final sLat = child.school.lat, sLng = child.school.lng;
    if (stopLat == null || stopLng == null || sLat == null || sLng == null) {
      child.routeLine = null;
      return;
    }
    final line = await _service.fetchRoadRoute(
      fromLat: sLat,
      fromLng: sLng,
      toLat: stopLat,
      toLng: stopLng,
    );
    child.routeLine = line ??
        [
          [sLng, sLat],
          [stopLng, stopLat]
        ];
  }

  // Pre-rendered marker icons (PNG bytes), built once when the map is created.
  Uint8List? _schoolIcon;
  Uint8List? _stopIcon;
  Uint8List? _busIconOriginal; // as drawn in the asset
  Uint8List? _busIconMirrored; // flipped horizontally in code
  // Whether each marker came from a custom PNG (drawn larger) or from code.
  bool _schoolIconIsCustom = false;
  bool _stopIconIsCustom = false;

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    // Create the line layer FIRST: layers created later draw on top, so the
    // bus / school / stop markers sit above both the blue and yellow lines.
    _lineManager = await map.annotations.createPolylineAnnotationManager();
    _pointManager = await map.annotations.createPointAnnotationManager();

    // Keep every marker upright on screen, even when the map is tilted or
    // rotated. This is what stops the bus from "lying down" on the road.
    await _pointManager!
        .setIconRotationAlignment(IconRotationAlignment.VIEWPORT);
    await _pointManager!.setIconPitchAlignment(IconPitchAlignment.VIEWPORT);

    await map.location
        .updateSettings(LocationComponentSettings(enabled: false));

    // Build the school + stop marker images in code; load the bus image asset
    // and make a mirrored copy so the bus can face left or right.
    _schoolIcon = await _loadMarkerImage(_schoolMarkerAsset, _MarkerKind.school);
    _stopIcon = await _loadMarkerImage(_studentMarkerAsset, _MarkerKind.stop);
    _busIconOriginal = await _loadBusIcon();
    _busIconMirrored = await _mirrorPng(_busIconOriginal!);
    _redraw();
  }

  Child? get _selected => _children.isNotEmpty
      ? _children[_selectedIndex.clamp(0, _children.length - 1)]
      : null;

  // Picks the bus image whose front matches the direction of travel.
  Uint8List? _busIconFor(Child child) {
    final busId = child.bus?.id.toString();
    final wantRight = busId != null ? (_busFacingRight[busId] ?? true) : true;
    return wantRight == _busImageFacesRight
        ? _busIconOriginal
        : _busIconMirrored;
  }

  Future<void> _redraw() async {
    final map = _map;
    if (map == null || _pointManager == null || _lineManager == null) return;

    final child = _selected;

    // Work out the yellow line first: it may need a network call (Mapbox
    // Directions), and clearing the map before that would make it flicker.
    final yellow = child != null ? await _yellowFor(child) : null;

    await _pointManager!.deleteAll();
    await _lineManager!.deleteAll();

    if (child == null) return;

    // --- Blue route: school <-> this child's stop (always shown) ---
    final route = _routePoints(child);
    if (route != null) {
      await _lineManager!.create(PolylineAnnotationOptions(
        geometry: LineString(
          coordinates: route.map((p) => Position(p.lng, p.lat)).toList(),
        ),
        lineColor: AppColors.accent.value,
        lineWidth: 5.5,
      ));
    }

    // --- Yellow: bus -> where it is heading next for this child ---
    // Drawn after the blue line so it sits on top.
    if (yellow != null && yellow.length > 1) {
      await _lineManager!.create(PolylineAnnotationOptions(
        geometry: LineString(
          coordinates: yellow.map((p) => Position(p.lng, p.lat)).toList(),
        ),
        lineColor: AppColors.amber.value,
        lineWidth: 6.0,
      ));
    }

    // --- Markers (big custom icons) ---
    final points = <PointAnnotationOptions>[];

    if (child.school.lat != null &&
        child.school.lng != null &&
        _schoolIcon != null) {
      points.add(PointAnnotationOptions(
        geometry:
            Point(coordinates: Position(child.school.lng!, child.school.lat!)),
        image: _schoolIcon,
        iconSize: _schoolIconIsCustom ? _customMarkerIconSize : 1.0,
        iconAnchor: IconAnchor.BOTTOM,
        symbolSortKey: 1,
      ));
    }
    final stopLat = child.pickupLat ?? child.dropLat;
    final stopLng = child.pickupLng ?? child.dropLng;
    if (stopLat != null && stopLng != null && _stopIcon != null) {
      points.add(PointAnnotationOptions(
        geometry: Point(coordinates: Position(stopLng, stopLat)),
        image: _stopIcon,
        iconSize: _stopIconIsCustom ? _customMarkerIconSize : 1.0,
        iconAnchor: IconAnchor.BOTTOM,
        symbolSortKey: 2,
      ));
    }
    final pos = child.livePosition;
    final busImage = _busIconFor(child);
    if (pos != null && busImage != null) {
      points.add(PointAnnotationOptions(
        geometry: Point(coordinates: Position(pos.lng, pos.lat)),
        image: busImage,
        iconSize: 0.5,
        iconAnchor: IconAnchor.BOTTOM, // wheels sit on the road point
        iconRotate: 0, // never rotate the 3D image — it stays upright
        symbolSortKey: 3,
      ));
    }
    if (points.isNotEmpty) {
      await _pointManager!.createMulti(points);
    }

    // Keeps the bottom sheet's on-route line in step with the map.
    if (mounted) setState(() {});

    await _updateCamera(child);
  }

  /// Camera rules (see the notes at the top of the file). This is the only
  /// place _redraw touches the camera, and it never resets the user's zoom.
  Future<void> _updateCamera(Child child) async {
    final hasBus = child.livePosition != null;

    // First time for this child (first load or after switching child), or the
    // first time the bus shows up after we had to frame without it.
    if (_framedChildId != child.id || (!_framedOnBus && hasBus)) {
      _framedChildId = child.id;
      _framedOnBus = hasBus;
      await _focusBus(child);
      return;
    }

    // Otherwise only glide along with the bus, and only while following.
    if (_followBus && hasBus) {
      final pos = child.livePosition!;
      await _map?.easeTo(
        CameraOptions(center: Point(coordinates: Position(pos.lng, pos.lat))),
        MapAnimationOptions(duration: 600),
      );
    }
  }

  /// Centres on the bus at [_busZoom]. With no bus position yet, fits the
  /// school and stop instead.
  Future<void> _focusBus(Child child) async {
    final pos = child.livePosition;
    if (pos == null) {
      await _fitCamera(child);
      return;
    }
    await _map?.flyTo(
      CameraOptions(
        center: Point(coordinates: Position(pos.lng, pos.lat)),
        zoom: _busZoom,
        pitch: 45,
      ),
      MapAnimationOptions(duration: 800),
    );
  }

  void _recenterOnBus() {
    final child = _selected;
    if (child == null) return;
    setState(() => _followBus = true);
    _focusBus(child);
  }

  /// Uses the custom PNG at [assetPath] when it exists, otherwise falls back
  /// to the pin drawn in code — so missing artwork never breaks the map.
  Future<Uint8List> _loadMarkerImage(String assetPath, _MarkerKind kind) async {
    try {
      final data = await rootBundle.load(assetPath);
      if (kind == _MarkerKind.school) {
        _schoolIconIsCustom = true;
      } else {
        _stopIconIsCustom = true;
      }
      return data.buffer.asUint8List();
    } catch (_) {
      return _buildMarker(kind);
    }
  }

  // Loads the school-bus PNG asset as bytes.
  Future<Uint8List> _loadBusIcon() async {
    final data = await rootBundle.load('assets/bus_top.png');
    return data.buffer.asUint8List();
  }

  // Returns a horizontally mirrored copy of a PNG, so we don't need a second
  // asset for the opposite direction.
  Future<Uint8List> _mirrorPng(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final src = (await codec.getNextFrame()).image;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.translate(src.width.toDouble(), 0);
    canvas.scale(-1, 1);
    canvas.drawImage(
        src, Offset.zero, Paint()..filterQuality = FilterQuality.high);
    final out = await recorder.endRecording().toImage(src.width, src.height);
    final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  // Draws a rounded "pin" marker with an icon glyph inside, as PNG bytes.
  // Big (about 120px) so parents spot school/stop quickly.
  Future<Uint8List> _buildMarker(_MarkerKind kind) async {
    const double w = 120, h = 140;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final Color color = switch (kind) {
      _MarkerKind.school => AppColors.ink,
      _MarkerKind.stop => AppColors.accent,
      _MarkerKind.bus => AppColors.amber,
    };

    final center = Offset(w / 2, w / 2);
    const radius = 52.0;

    // Pin tail (triangle) for school/stop; bus is a plain circle.
    if (kind != _MarkerKind.bus) {
      final tail = Path()
        ..moveTo(w / 2 - 18, w / 2 + 34)
        ..lineTo(w / 2 + 18, w / 2 + 34)
        ..lineTo(w / 2, h - 6)
        ..close();
      canvas.drawPath(tail, Paint()..color = color);
    }

    // White outer ring + colored disc
    canvas.drawCircle(center, radius + 5, Paint()..color = Colors.white);
    canvas.drawCircle(center, radius, Paint()..color = color);

    // Glyph (Material icon) in white
    final icon = switch (kind) {
      _MarkerKind.school => Icons.school_rounded,
      _MarkerKind.stop => Icons.home_rounded,
      _MarkerKind.bus => Icons.directions_bus_rounded,
    };
    final tp = TextPainter(textDirection: TextDirection.ltr);
    tp.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: 52,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: Colors.white,
      ),
    );
    tp.layout();
    tp.paint(
        canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));

    final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  // Fallback framing used only when the bus has no position yet: fits school
  // and stop. Never called on refresh or GPS pings.
  Future<void> _fitCamera(Child child) async {
    final map = _map;
    if (map == null) return;
    final coords = <List<double>>[]; // [lng, lat]
    if (child.school.lat != null) {
      coords.add([child.school.lng!, child.school.lat!]);
    }
    final stopLat = child.pickupLat ?? child.dropLat;
    final stopLng = child.pickupLng ?? child.dropLng;
    if (stopLat != null && stopLng != null) coords.add([stopLng, stopLat]);
    if (child.livePosition != null) {
      coords.add([child.livePosition!.lng, child.livePosition!.lat]);
    }
    if (coords.isEmpty) return;

    // Compute a simple center + zoom from the bounding box of the points.
    // Avoids relying on cameraForCoordinates, whose signature shifts between
    // SDK minor versions — this is stable and good enough for 2-3 points.
    double minLat = coords.first[1], maxLat = coords.first[1];
    double minLng = coords.first[0], maxLng = coords.first[0];
    for (final c in coords) {
      minLng = c[0] < minLng ? c[0] : minLng;
      maxLng = c[0] > maxLng ? c[0] : maxLng;
      minLat = c[1] < minLat ? c[1] : minLat;
      maxLat = c[1] > maxLat ? c[1] : maxLat;
    }
    final centerLng = (minLng + maxLng) / 2;
    final centerLat = (minLat + maxLat) / 2;

    double zoom;
    if (coords.length == 1) {
      zoom = 15;
    } else {
      // Rough zoom from the span: larger span -> lower zoom.
      final span = ((maxLat - minLat).abs() > (maxLng - minLng).abs())
          ? (maxLat - minLat).abs()
          : (maxLng - minLng).abs();
      if (span > 0.2) {
        zoom = 9.5;
      } else if (span > 0.1) {
        zoom = 10.5;
      } else if (span > 0.05) {
        zoom = 11.5;
      } else if (span > 0.02) {
        zoom = 12.5;
      } else if (span > 0.01) {
        zoom = 13.5;
      } else {
        zoom = 15;
      }
    }

    await map.flyTo(
      CameraOptions(
        center: Point(coordinates: Position(centerLng, centerLat)),
        zoom: zoom,
        pitch: 45,
      ),
      MapAnimationOptions(duration: 800),
    );
  }

  void _selectChild(int i) {
    setState(() {
      _selectedIndex = i;
      _followBus = true;
    });
    // Forces the camera to be framed again for the newly selected child.
    _framedChildId = null;
    _framedOnBus = false;
    _redraw();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _ErrorView(
                    message: _error!,
                    onRetry: _load,
                    onSignOut: () => _service.signOut())
                : Stack(
                    children: [
                      // Map fills the screen. The Listener notices the user
                      // dragging / pinching so we stop following the bus.
                      Positioned.fill(
                        child: Listener(
                          onPointerMove: (e) {
                            if (_followBus && e.delta.distance > 2) {
                              setState(() => _followBus = false);
                            }
                          },
                          child: MapWidget(
                            key: const ValueKey('parentMap'),
                            styleUri: MapboxStyles.MAPBOX_STREETS,
                            cameraOptions: CameraOptions(
                              center:
                                  Point(coordinates: Position(76.04, 10.965)),
                              zoom: 12,
                              pitch: 45,
                            ),
                            onMapCreated: _onMapCreated,
                          ),
                        ),
                      ),

                      // Children bar on top
                      Positioned(
                        top: 8,
                        left: 8,
                        right: 8,
                        child: _ChildrenBar(
                          children: _children,
                          selectedIndex: _selectedIndex,
                          refreshing: _refreshing,
                          lastRefreshed: _lastRefreshed,
                          onRefresh: _refresh,
                          onSelect: _selectChild,
                          onOpenNotifications: () {
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const NotificationsScreen(),
                            ));
                          },
                          onChangePassword: () {
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const ChangePasswordScreen(),
                            ));
                          },
                          onSignOut: () => _service.signOut(),
                        ),
                      ),

                      // Bottom sheet with the selected child's bus details,
                      // plus the "Bus" recenter button while not following.
                      if (selected != null)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              if (!_followBus && selected.livePosition != null)
                                Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: FloatingActionButton.extended(
                                    heroTag: 'recenterBus',
                                    onPressed: _recenterOnBus,
                                    backgroundColor: Colors.white,
                                    foregroundColor: AppColors.accent,
                                    icon: const Icon(
                                        Icons.my_location_rounded,
                                        size: 20),
                                    label: const Text('Bus',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w700)),
                                  ),
                                ),
                              _BusDetailsSheet(
                                child: selected,
                                onRoute: _isBusOnRoute(selected),
                                liveConnected: _liveConnected,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }
}

/// A cached road path from the bus to the yellow line's target.
class _RoadYellow {
  final String key; // target kind + coordinates it was computed for
  final List<LL> line;
  final double fromLat;
  final double fromLng;
  final DateTime at = DateTime.now();
  _RoadYellow({
    required this.key,
    required this.line,
    required this.fromLat,
    required this.fromLng,
  });
}

class _ChildrenBar extends StatelessWidget {
  final List<Child> children;
  final int selectedIndex;
  final bool refreshing;
  final DateTime? lastRefreshed;
  final VoidCallback onRefresh;
  final ValueChanged<int> onSelect;
  final VoidCallback onOpenNotifications;
  final VoidCallback onChangePassword;
  final VoidCallback onSignOut;
  const _ChildrenBar({
    required this.children,
    required this.selectedIndex,
    required this.refreshing,
    required this.lastRefreshed,
    required this.onRefresh,
    required this.onSelect,
    required this.onOpenNotifications,
    required this.onChangePassword,
    required this.onSignOut,
  });

  String get _refreshTooltip {
    if (refreshing) return 'Refreshing\u2026';
    final t = lastRefreshed;
    if (t == null) return 'Refresh';
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'Updated just now';
    if (d.inMinutes < 60) return 'Updated ${d.inMinutes} min ago';
    return 'Updated ${d.inHours} h ago';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
              color: Color(0x1A202B49), blurRadius: 12, offset: Offset(0, 4))
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: children.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final c = children[i];
                  final active = i == selectedIndex;
                  return GestureDetector(
                    onTap: () => onSelect(i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: active ? AppColors.accentSoft : AppColors.paper,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: active ? AppColors.accent : AppColors.line,
                          width: active ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          _MiniAvatar(child: c),
                          const SizedBox(width: 8),
                          Text(
                            c.fullName.split(' ').first,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color:
                                  active ? AppColors.accent : AppColors.inkSoft,
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          IconButton(
            icon: refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: AppColors.accent),
                  )
                : const Icon(Icons.refresh_rounded, color: AppColors.ink),
            onPressed: refreshing ? null : onRefresh,
            tooltip: _refreshTooltip,
          ),
          IconButton(
            icon: const Icon(Icons.notifications_none_rounded,
                color: AppColors.ink),
            onPressed: onOpenNotifications,
            tooltip: 'Notifications',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: AppColors.inkFaint),
            tooltip: 'More',
            onSelected: (value) {
              if (value == 'password') onChangePassword();
              if (value == 'signout') onSignOut();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'password',
                child: Row(children: [
                  Icon(Icons.lock_outline_rounded, size: 20, color: AppColors.inkSoft),
                  SizedBox(width: 10),
                  Text('Change password'),
                ]),
              ),
              PopupMenuItem(
                value: 'signout',
                child: Row(children: [
                  Icon(Icons.logout, size: 20, color: AppColors.inkSoft),
                  SizedBox(width: 10),
                  Text('Sign out'),
                ]),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  final Child child;
  const _MiniAvatar({required this.child});
  @override
  Widget build(BuildContext context) {
    final initial =
        child.fullName.isNotEmpty ? child.fullName[0].toUpperCase() : '?';
    return Container(
      width: 30,
      height: 30,
      decoration: const BoxDecoration(
          shape: BoxShape.circle, color: AppColors.accentSoft),
      clipBehavior: Clip.antiAlias,
      child: child.photoUrl != null
          ? Image.network(child.photoUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _initialWidget(initial))
          : _initialWidget(initial),
    );
  }

  Widget _initialWidget(String initial) => Center(
        child: Text(initial,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.accent)),
      );
}

class _BusDetailsSheet extends StatelessWidget {
  final Child child;

  /// true = bus is on this child's blue route, false = away from it,
  /// null = can't tell yet (no live position or no route).
  final bool? onRoute;

  /// Whether the live (WebSocket) feed is currently connected.
  final bool liveConnected;

  const _BusDetailsSheet({required this.child, this.onRoute, this.liveConnected = false});

  @override
  Widget build(BuildContext context) {
    final bus = child.bus;
    final pos = child.livePosition;

    // If the last GPS update is old, don't claim the bus is running/moving.
    final isStale = pos?.recordedAt != null &&
        DateTime.now().difference(pos!.recordedAt!) > _staleAfter;

    String statusLabel = {
          'running': 'Running',
          'not_running': 'Not running',
          'maintenance': 'Maintenance',
        }[bus?.status] ??
        'Unknown';
    Color statusColor = {
          'running': AppColors.go,
          'not_running': AppColors.stop,
          'maintenance': AppColors.amber,
        }[bus?.status] ??
        AppColors.inkFaint;
    // The badge follows the trip: Running while the trip is in progress,
    // Not running otherwise. A missing GPS signal is explained in the text
    // below ("Bus is not sending its location"), not by changing the badge.

    final String speedText;
    if (pos == null) {
      speedText = 'Live tracking starts when the bus is on route';
    } else if (isStale) {
      speedText = 'Bus is not sending its location';
    } else if (pos.speedKmh != null) {
      speedText = pos.speedKmh! < _minSpeedForHeading
          ? 'Stopped'
          : 'Moving at ${pos.speedKmh!.round()} km/h';
    } else {
      speedText = 'Live location active';
    }

    // Explains a missing yellow line, so parents don't think tracking is broken.
    final bool showOffRouteNote = onRoute == false && !isStale && pos != null;

    return Container(
      margin: const EdgeInsets.all(10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
              color: Color(0x22202B49), blurRadius: 16, offset: Offset(0, 6))
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(child.fullName,
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink)),
              const SizedBox(width: 8),
              if (liveConnected)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.goSoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text('LIVE',
                      style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 0.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.go)),
                ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: [
                    Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: statusColor)),
                    const SizedBox(width: 6),
                    Text(statusLabel,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: statusColor)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.directions_bus_rounded,
                  size: 18, color: AppColors.inkFaint),
              const SizedBox(width: 8),
              Text(bus?.busNumber ?? 'No bus assigned',
                  style:
                      const TextStyle(fontSize: 14, color: AppColors.inkSoft)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.speed_rounded,
                  size: 18, color: AppColors.inkFaint),
              const SizedBox(width: 8),
              Text(speedText,
                  style:
                      const TextStyle(fontSize: 14, color: AppColors.inkSoft)),
            ],
          ),
          if (showOffRouteNote) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.alt_route_rounded,
                    size: 18, color: AppColors.inkFaint),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Bus is not on your route yet',
                      style:
                          TextStyle(fontSize: 14, color: AppColors.inkSoft)),
                ),
              ],
            ),
          ],
          if (pos?.recordedAt != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.schedule_rounded,
                    size: 18, color: AppColors.inkFaint),
                const SizedBox(width: 8),
                Text(
                    isStale
                        ? 'Last seen ${_ago(pos!.recordedAt!)}'
                        : 'Updated ${_ago(pos!.recordedAt!)}',
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.inkFaint)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    return '${d.inHours} h ago';
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onSignOut;
  const _ErrorView(
      {required this.message, required this.onRetry, required this.onSignOut});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.location_off_outlined,
                size: 44, color: AppColors.inkFaint),
            const SizedBox(height: 14),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.inkSoft, fontSize: 15)),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
                const SizedBox(width: 10),
                TextButton(onPressed: onSignOut, child: const Text('Sign out')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
