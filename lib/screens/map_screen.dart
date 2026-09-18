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

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _service = ParentService();

  MapboxMap? _map;
  PointAnnotationManager? _pointManager;
  PolylineAnnotationManager? _lineManager;

  List<Child> _children = [];
  int _selectedIndex = 0;
  bool _loading = true;
  String? _error;

  final List<RealtimeChannel> _channels = [];

  // Per-bus direction state (keyed by bus id).
  final Map<String, bool> _busFacingRight = {};
  final Map<String, ({double lat, double lng})> _lastBusPoint = {};

  @override
  void initState() {
    super.initState();
    MapboxOptions.setAccessToken(AppConfig.mapboxPublicToken);
    _load();
  }

  @override
  void dispose() {
    for (final ch in _channels) {
      ch.unsubscribe();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final children = await _service.loadChildren();
      if (children.isEmpty) {
        setState(() {
          _error =
              'No children are linked to your account yet. Contact your school office.';
          _loading = false;
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
        await _computeBusSegment(child);

        final channel = _service.subscribeBusPosition(bus.id, (newPos) {
          child.livePosition = newPos;
          _updateFacing(bus.id.toString(), newPos.lat, newPos.lng,
              newPos.heading, newPos.speedKmh);
          _computeBusSegment(child).then((_) => _redraw());
          _redraw();
        });
        _channels.add(channel);
      }

      setState(() {
        _children = children;
        _loading = false;
      });
      _redraw();
    } catch (e) {
      setState(() {
        _error = 'Could not load your children. Pull to retry.';
        _loading = false;
      });
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

  // Optional road segment from the live bus to the child's stop, drawn on top
  // of the base route in a highlighted color. Null when there's no live bus.
  Future<void> _computeBusSegment(Child child) async {
    final pos = child.livePosition;
    final stopLat = child.pickupLat ?? child.dropLat;
    final stopLng = child.pickupLng ?? child.dropLng;
    if (pos == null || stopLat == null || stopLng == null) {
      child.busSegment = null;
      return;
    }
    final line = await _service.fetchRoadRoute(
      fromLat: pos.lat,
      fromLng: pos.lng,
      toLat: stopLat,
      toLng: stopLng,
    );
    child.busSegment = line ??
        [
          [pos.lng, pos.lat],
          [stopLng, stopLat]
        ];
  }

  // Pre-rendered marker icons (PNG bytes), built once when the map is created.
  Uint8List? _schoolIcon;
  Uint8List? _stopIcon;
  Uint8List? _busIconOriginal; // as drawn in the asset
  Uint8List? _busIconMirrored; // flipped horizontally in code

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    _pointManager = await map.annotations.createPointAnnotationManager();
    _lineManager = await map.annotations.createPolylineAnnotationManager();

    // Keep every marker upright on screen, even when the map is tilted or
    // rotated. This is what stops the bus from "lying down" on the road.
    await _pointManager!
        .setIconRotationAlignment(IconRotationAlignment.VIEWPORT);
    await _pointManager!.setIconPitchAlignment(IconPitchAlignment.VIEWPORT);

    await map.location
        .updateSettings(LocationComponentSettings(enabled: false));

    // Build the school + stop marker images in code; load the bus image asset
    // and make a mirrored copy so the bus can face left or right.
    _schoolIcon = await _buildMarker(_MarkerKind.school);
    _stopIcon = await _buildMarker(_MarkerKind.stop);
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

    await _pointManager!.deleteAll();
    await _lineManager!.deleteAll();

    final child = _selected;
    if (child == null) return;

    // --- Route lines (draw the base school<->stop first, bus segment on top) ---
    if (child.routeLine != null && child.routeLine!.length >= 2) {
      await _lineManager!.create(PolylineAnnotationOptions(
        geometry: LineString(
          coordinates:
              child.routeLine!.map((c) => Position(c[0], c[1])).toList(),
        ),
        lineColor: AppColors.accent.value,
        lineWidth: 5.5,
      ));
    }
    if (child.busSegment != null && child.busSegment!.length >= 2) {
      await _lineManager!.create(PolylineAnnotationOptions(
        geometry: LineString(
          coordinates:
              child.busSegment!.map((c) => Position(c[0], c[1])).toList(),
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
        iconSize: 1.0,
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
        iconSize: 1.0,
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

    await _fitCamera(child);
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

  Future<void> _fitCamera(Child child) async {
    final map = _map;
    if (map == null) return;
    final coords = <List<double>>[]; // [lng, lat]
    if (child.school.lat != null)
      coords.add([child.school.lng!, child.school.lat!]);
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
        zoom = 11;
      } else if (span > 0.1) {
        zoom = 9.5;
      } else if (span > 0.05) {
        zoom = 11.5;
      } else if (span > 0.02) {
        zoom = 12.5;
      } else if (span > 0.01) {
        zoom = 13.5;
      } else {
        zoom = 17.5;
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
    setState(() => _selectedIndex = i);
    _redraw();
  }

  @override
  Widget build(BuildContext context) {
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
                      // Map fills the screen
                      Positioned.fill(
                        child: MapWidget(
                          key: const ValueKey('parentMap'),
                          styleUri: MapboxStyles.MAPBOX_STREETS,
                          cameraOptions: CameraOptions(
                            center: Point(coordinates: Position(76.04, 10.965)),
                            zoom: 12,
                            pitch: 45,
                          ),
                          onMapCreated: _onMapCreated,
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
                          onSelect: _selectChild,
                          onOpenNotifications: () {
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const NotificationsScreen(),
                            ));
                          },
                          onSignOut: () => _service.signOut(),
                        ),
                      ),

                      // Bottom sheet with the selected child's bus details
                      if (_selected != null)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: _BusDetailsSheet(child: _selected!),
                        ),
                    ],
                  ),
      ),
    );
  }
}

class _ChildrenBar extends StatelessWidget {
  final List<Child> children;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onOpenNotifications;
  final VoidCallback onSignOut;
  const _ChildrenBar({
    required this.children,
    required this.selectedIndex,
    required this.onSelect,
    required this.onOpenNotifications,
    required this.onSignOut,
  });

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
            icon: const Icon(Icons.notifications_none_rounded,
                color: AppColors.ink),
            onPressed: onOpenNotifications,
            tooltip: 'Notifications',
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: AppColors.inkFaint),
            onPressed: onSignOut,
            tooltip: 'Sign out',
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
  const _BusDetailsSheet({required this.child});

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
    if (bus?.status == 'running' && isStale) {
      statusLabel = 'Offline';
      statusColor = AppColors.inkFaint;
    }

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