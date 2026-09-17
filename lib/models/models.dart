// Models for the parent app.

class SchoolInfo {
  final String id;
  final String name;
  final double? lat;
  final double? lng;
  SchoolInfo({required this.id, required this.name, this.lat, this.lng});
  factory SchoolInfo.fromMap(Map<String, dynamic> m) => SchoolInfo(
        id: m['id'] as String,
        name: m['name'] as String? ?? 'School',
        lat: (m['latitude'] as num?)?.toDouble(),
        lng: (m['longitude'] as num?)?.toDouble(),
      );
}

class BusInfo {
  final String id;
  final String busNumber;
  final String status;
  BusInfo({required this.id, required this.busNumber, required this.status});
  factory BusInfo.fromMap(Map<String, dynamic> m) => BusInfo(
        id: m['id'] as String,
        busNumber: m['bus_number'] as String? ?? 'Bus',
        status: m['status'] as String? ?? 'not_running',
      );
}

class BusPosition {
  final double lat;
  final double lng;
  final double? speedKmh;
  final double? heading;
  final DateTime? recordedAt;
  BusPosition({required this.lat, required this.lng, this.speedKmh, this.heading, this.recordedAt});
  factory BusPosition.fromMap(Map<String, dynamic> m) => BusPosition(
        lat: (m['latitude'] as num).toDouble(),
        lng: (m['longitude'] as num).toDouble(),
        speedKmh: (m['speed_kmh'] as num?)?.toDouble(),
        heading: (m['heading'] as num?)?.toDouble(),
        recordedAt: m['recorded_at'] != null ? DateTime.tryParse(m['recorded_at'] as String) : null,
      );
}

class Child {
  final String id;
  final String fullName;
  final String admissionNumber;
  final String? photoUrl;
  final double? pickupLat;
  final double? pickupLng;
  final double? dropLat;
  final double? dropLng;
  final BusInfo? bus;
  final SchoolInfo school;

  BusPosition? livePosition;
  List<List<double>>? routeLine;   // school <-> stop, [ [lng,lat], ... ]
  List<List<double>>? busSegment;  // live bus -> stop, drawn on top when live

  Child({
    required this.id,
    required this.fullName,
    required this.admissionNumber,
    required this.school,
    this.photoUrl,
    this.pickupLat,
    this.pickupLng,
    this.dropLat,
    this.dropLng,
    this.bus,
    this.livePosition,
    this.routeLine,
  });
}

class AppNotification {
  final String id;
  final String title;
  final String body;
  final String? category;
  final DateTime createdAt;
  AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.category,
    required this.createdAt,
  });
  factory AppNotification.fromMap(Map<String, dynamic> m) => AppNotification(
        id: m['id'] as String,
        title: m['title'] as String? ?? '',
        body: m['body'] as String? ?? '',
        category: m['category'] as String?,
        createdAt: DateTime.tryParse(m['created_at'] as String? ?? '') ?? DateTime.now(),
      );
}
