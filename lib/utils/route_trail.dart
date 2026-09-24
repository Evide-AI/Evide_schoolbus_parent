import 'dart:math' as math;

/// Keeps the yellow bus trail on the blue route only.
///
/// The blue line runs between the student's stop and the school. The bus often
/// drives elsewhere before and after that stretch (other stops, the depot,
/// parallel roads). Passing the raw trail to the map draws those parts too.
///
/// [clipTrailToRoute] returns only the parts of the trail that sit on the blue
/// line, split into separate pieces wherever the bus left it. Draw one polyline
/// per piece, so the map doesn't join them with a straight line across the map.
///
/// Usage with mapbox_maps_flutter:
///
///   final pieces = clipTrailToRoute(
///     trail: busTrail.map((p) => GeoPoint(p.lat, p.lng)).toList(),
///     route: routePolyline.map((p) => GeoPoint(p.lat, p.lng)).toList(),
///   );
///
///   await trailManager.deleteAll();
///   for (final piece in pieces) {
///     await trailManager.create(PolylineAnnotationOptions(
///       geometry: LineString(
///         coordinates: piece.map((p) => Position(p.lng, p.lat)).toList()),
///       lineColor: 0xFFF2B300, // yellow
///       lineWidth: 5.0,
///     ));
///   }
///
/// When the bus is off the route the list comes back empty and no yellow line
/// is drawn, which is the behaviour you asked for.

class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);
}

const double _earthRadius = 6371000; // metres

class _XY {
  final double x;
  final double y;
  const _XY(this.x, this.y);
}

/// Flat-earth projection. Accurate to a few centimetres over a school route,
/// and far cheaper than proper geodesics for a per-frame redraw.
_XY _project(GeoPoint p, double lat0) {
  const rad = math.pi / 180;
  return _XY(
    _earthRadius * (p.lng * rad) * math.cos(lat0 * rad),
    _earthRadius * (p.lat * rad),
  );
}

double _distanceToSegment(_XY p, _XY a, _XY b) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  final lengthSquared = dx * dx + dy * dy;
  var t = lengthSquared == 0
      ? 0.0
      : ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared;
  t = t.clamp(0.0, 1.0);
  final cx = a.x + t * dx;
  final cy = a.y + t * dy;
  return math.sqrt(math.pow(p.x - cx, 2) + math.pow(p.y - cy, 2));
}

/// Shortest distance in metres from [point] to the route line.
double distanceToRoute(GeoPoint point, List<GeoPoint> route) {
  if (route.length < 2) return double.infinity;
  final lat0 = route.first.lat;
  final p = _project(point, lat0);
  var best = double.infinity;
  for (var i = 0; i < route.length - 1; i++) {
    final d = _distanceToSegment(
        p, _project(route[i], lat0), _project(route[i + 1], lat0));
    if (d < best) best = d;
  }
  return best;
}

/// True when the bus is currently on the blue line.
/// Handy for showing "On route" / "Off route" on the status card.
bool isOnRoute(GeoPoint position, List<GeoPoint> route,
        {double toleranceMetres = 60}) =>
    distanceToRoute(position, route) <= toleranceMetres;

/// Splits [trail] into the pieces that lie on [route].
///
/// [toleranceMetres] is how far off the line a point may be and still count.
/// 60 m suits Kerala roads: it covers GPS drift and dual carriageways without
/// picking up a parallel street. Raise it if trails look broken in narrow lanes.
///
/// [graceGap] bridges short jumps away from the line (GPS jitter at stops or
/// under trees) so one continuous drive stays one line instead of many stubs.
List<List<GeoPoint>> clipTrailToRoute({
  required List<GeoPoint> trail,
  required List<GeoPoint> route,
  double toleranceMetres = 60,
  int graceGap = 2,
}) {
  if (route.length < 2 || trail.length < 2) return const [];

  final lat0 = route.first.lat;
  final projectedRoute = route.map((p) => _project(p, lat0)).toList();

  bool near(GeoPoint point) {
    final p = _project(point, lat0);
    for (var i = 0; i < projectedRoute.length - 1; i++) {
      if (_distanceToSegment(p, projectedRoute[i], projectedRoute[i + 1]) <=
          toleranceMetres) {
        return true;
      }
    }
    return false;
  }

  final onRoute = trail.map(near).toList();

  // Bridge short off-route runs that sit between two on-route stretches.
  for (var i = 0; i < onRoute.length; i++) {
    if (onRoute[i]) continue;
    var j = i;
    while (j < onRoute.length && !onRoute[j]) {
      j++;
    }
    final gap = j - i;
    if (i > 0 && j < onRoute.length && gap <= graceGap) {
      for (var k = i; k < j; k++) {
        onRoute[k] = true;
      }
    }
    i = j - 1;
  }

  final pieces = <List<GeoPoint>>[];
  var current = <GeoPoint>[];
  for (var i = 0; i < trail.length; i++) {
    if (onRoute[i]) {
      current.add(trail[i]);
    } else {
      if (current.length > 1) pieces.add(current);
      current = <GeoPoint>[];
    }
  }
  if (current.length > 1) pieces.add(current);

  return pieces;
}
