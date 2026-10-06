import 'dart:math';

/// Simple lat/lng pair (kept independent of any map SDK).
class LL {
  final double lat, lng;
  const LL(this.lat, this.lng);
}

/// Haversine distance in metres.
double distanceMeters(LL a, LL b) {
  const r = 6371000.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(b.lat - a.lat), dLng = rad(b.lng - a.lng);
  final h = pow(sin(dLat / 2), 2) +
      cos(rad(a.lat)) * cos(rad(b.lat)) * pow(sin(dLng / 2), 2);
  return 2 * r * asin(sqrt(h));
}

/// Result of snapping a GPS point onto the route.
class Snap {
  final int seg; // index of the segment's start vertex
  final LL point; // snapped point on the route
  final double along; // metres from route start
  final double off; // metres between the original point and the route
  const Snap(this.seg, this.point, this.along, this.off);
}

class RouteSlicer {
  final List<LL> pts;
  late final List<double> cum; // cumulative metres at each vertex

  RouteSlicer(this.pts) {
    cum = [0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum.last + distanceMeters(pts[i - 1], pts[i]));
    }
  }

  double get totalMeters => cum.isEmpty ? 0 : cum.last;

  /// Snap [p] to the nearest route segment.
  /// [minAlong] keeps the result from jumping backwards (30 m tolerance),
  /// which matters when the route passes the same road twice.
  Snap snap(LL p, {double minAlong = 0}) {
    return _snap(p, minAlong) ?? _snap(p, 0)!;
  }

  Snap? _snap(LL p, double minAlong) {
    if (pts.length < 2) return Snap(0, pts.first, 0, distanceMeters(p, pts.first));
    Snap? best;
    final kx = cos(p.lat * pi / 180);
    for (var i = 0; i < pts.length - 1; i++) {
      if (cum[i + 1] < minAlong - 30) continue;
      final a = pts[i], b = pts[i + 1];
      // Local flat projection with p at the origin.
      final ax = (a.lng - p.lng) * kx, ay = a.lat - p.lat;
      final bx = (b.lng - p.lng) * kx, by = b.lat - p.lat;
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      var t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2);
      t = t.clamp(0.0, 1.0);
      final q = LL(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t);
      final off = distanceMeters(p, q);
      if (best == null || off < best.off) {
        best = Snap(i, q, cum[i] + distanceMeters(a, q), off);
      }
    }
    return best;
  }

  /// Route from [from] to [to] (from must be before to).
  List<LL> slice(Snap from, Snap to) =>
      [from.point, ...pts.sublist(from.seg + 1, to.seg + 1), to.point];

  /// Part of the route already travelled.
  List<LL> head(Snap s) => [...pts.sublist(0, s.seg + 1), s.point];

  /// Part of the route after [s].
  List<LL> tail(Snap s) => [s.point, ...pts.sublist(s.seg + 1)];
}

/// Decode a Google/Mapbox encoded polyline.
/// Use precision 6 for Mapbox `polyline6`, 5 for the default `polyline`.
List<LL> decodePolyline(String encoded, {int precision = 6}) {
  final factor = pow(10, precision).toDouble();
  final out = <LL>[];
  int index = 0, lat = 0, lng = 0;
  while (index < encoded.length) {
    int shift = 0, result = 0, b;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

    out.add(LL(lat / factor, lng / factor));
  }
  return out;
}
