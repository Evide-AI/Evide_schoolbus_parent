import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config.dart';
import '../models/models.dart';

class ParentService {
  final SupabaseClient _db = Supabase.instance.client;

  /// Loads all children linked to the signed-in parent, each joined with their
  /// bus and school. Returns [] if the parent isn't linked to any students.
  Future<List<Child>> loadChildren() async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return [];

    // Find the parent_users row for this auth user.
    final parentRow = await _db
        .from('parent_users')
        .select('id')
        .eq('auth_user_id', userId)
        .maybeSingle();
    if (parentRow == null) return [];
    final parentId = parentRow['id'] as String;

    // Linked student ids.
    final links = await _db
        .from('parent_student_links')
        .select('student_id')
        .eq('parent_user_id', parentId);
    final studentIds = (links as List).map((l) => l['student_id'] as String).toList();
    if (studentIds.isEmpty) return [];

    // Students joined with bus + school.
    final rows = await _db
        .from('students')
        .select(
            'id, full_name, admission_number, photo_path, pickup_lat, pickup_lng, drop_lat, drop_lng, '
            'buses(id, bus_number, status), schools(id, name, latitude, longitude)')
        .inFilter('id', studentIds);

    final children = <Child>[];
    for (final m in rows as List) {
      final map = m as Map<String, dynamic>;
      final schoolMap = map['schools'] as Map<String, dynamic>?;
      final busMap = map['buses'] as Map<String, dynamic>?;
      children.add(Child(
        id: map['id'] as String,
        fullName: map['full_name'] as String,
        admissionNumber: map['admission_number'] as String,
        pickupLat: (map['pickup_lat'] as num?)?.toDouble(),
        pickupLng: (map['pickup_lng'] as num?)?.toDouble(),
        dropLat: (map['drop_lat'] as num?)?.toDouble(),
        dropLng: (map['drop_lng'] as num?)?.toDouble(),
        bus: busMap != null ? BusInfo.fromMap(busMap) : null,
        school: schoolMap != null
            ? SchoolInfo.fromMap(schoolMap)
            : SchoolInfo(id: '', name: 'School'),
      ));
    }

    // Signed photo URLs.
    final withPhotos = <String, String>{};
    final photoPaths = <String>[];
    for (final m in rows as List) {
      final map = m as Map<String, dynamic>;
      if (map['photo_path'] != null) {
        withPhotos[map['id'] as String] = map['photo_path'] as String;
        photoPaths.add(map['photo_path'] as String);
      }
    }
    if (photoPaths.isNotEmpty) {
      try {
        final signed = await _db.storage.from('student-photos').createSignedUrls(photoPaths, 3600);
        int i = 0;
        withPhotos.forEach((childId, path) {
          final url = signed[i].signedUrl;
          final idx = children.indexWhere((c) => c.id == childId);
          if (idx != -1) {
            children[idx] = _copyWithPhoto(children[idx], url);
          }
          i++;
        });
      } catch (_) {/* fall back to initials */}
    }

    return children;
  }

  Child _copyWithPhoto(Child c, String url) => Child(
        id: c.id,
        fullName: c.fullName,
        admissionNumber: c.admissionNumber,
        school: c.school,
        photoUrl: url,
        pickupLat: c.pickupLat,
        pickupLng: c.pickupLng,
        dropLat: c.dropLat,
        dropLng: c.dropLng,
        bus: c.bus,
        livePosition: c.livePosition,
        routeLine: c.routeLine,
      );

  /// Latest known position for a bus (one-time fetch; Realtime handles updates).
  Future<BusPosition?> fetchBusPosition(String busId) async {
    final row = await _db
        .from('bus_live_position')
        .select('latitude, longitude, speed_kmh, heading, recorded_at')
        .eq('bus_id', busId)
        .maybeSingle();
    if (row == null) return null;
    return BusPosition.fromMap(row);
  }

  /// Draws a road-following line from the bus's current position through the
  /// child's stop, via Mapbox Directions. Falls back to null (caller draws a
  /// straight line) on any failure. Returns [ [lng,lat], ... ].
  Future<List<List<double>>?> fetchRoadRoute({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) async {
    final token = AppConfig.mapboxPublicToken;
    if (token == 'YOUR_MAPBOX_PUBLIC_TOKEN') return null;
    final url = Uri.parse(
      'https://api.mapbox.com/directions/v5/mapbox/driving/'
      '$fromLng,$fromLat;$toLng,$toLat'
      '?geometries=geojson&overview=full&access_token=$token',
    );
    try {
      final res = await http.get(url);
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return null;
      final coords = routes[0]['geometry']['coordinates'] as List;
      return coords.map<List<double>>((c) => [(c[0] as num).toDouble(), (c[1] as num).toDouble()]).toList();
    } catch (_) {
      return null;
    }
  }

  /// Notifications relevant to this parent's school(s).
  Future<List<AppNotification>> loadNotifications() async {
    final rows = await _db
        .from('notifications')
        .select('id, title, body, category, created_at')
        .order('created_at', ascending: false)
        .limit(50);
    return (rows as List).map((m) => AppNotification.fromMap(m as Map<String, dynamic>)).toList();
  }

  /// Registers this device's FCM token so the backend can push alarms.
  Future<void> registerDeviceToken(String fcmToken, String platform) async {
    final userId = _db.auth.currentUser?.id;
    if (userId == null) return;
    final parentRow = await _db
        .from('parent_users')
        .select('id')
        .eq('auth_user_id', userId)
        .maybeSingle();
    if (parentRow == null) return;
    await _db.from('device_tokens').upsert(
      {
        'parent_user_id': parentRow['id'],
        'fcm_token': fcmToken,
        'platform': platform,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      onConflict: 'fcm_token',
    );
  }

  /// Realtime subscription to a bus's live position. Calls [onUpdate] on change.
  RealtimeChannel subscribeBusPosition(String busId, void Function(BusPosition) onUpdate) {
    final channel = _db.channel('bus_pos_$busId');
    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'bus_live_position',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'bus_id',
            value: busId,
          ),
          callback: (payload) {
            final rec = payload.newRecord;
            if (rec.isNotEmpty) onUpdate(BusPosition.fromMap(rec));
          },
        )
        .subscribe();
    return channel;
  }

  Future<void> signOut() => _db.auth.signOut();
}
