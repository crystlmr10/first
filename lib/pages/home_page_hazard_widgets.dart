part of 'home_page.dart';

class _HomePageHazardWidgets {
  static List<Polyline> buildHazardRadiusRings(
    List<Map<String, dynamic>> reports,
    Color dangerColor,
  ) {
    const Distance distance = Distance();
    final List<Polyline> rings = [];

    for (final report in reports) {
      final decision = (report['admin_decision'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (decision != 'impassable' && decision != 'risky') continue;

      final lat = (report['latitude'] as num?)?.toDouble();
      final lng = (report['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;

      final center = LatLng(lat, lng);
      final radiusMeters = decision == 'impassable' ? 150.0 : 80.0;
      final ringColor = decision == 'impassable'
          ? dangerColor.withAlpha(220)
          : Colors.orangeAccent.withAlpha(220);

      // Draw a broken circle using many short arc segments.
      const int segments = 36; // 10 degrees each around the circle
      for (int i = 0; i < segments; i++) {
        if (i.isOdd) continue; // every other segment is skipped (gap)

        final startBearing = i * (360.0 / segments);
        final midBearing = startBearing + 4.0;
        final endBearing = startBearing + 8.0;

        final p1 = distance.offset(center, radiusMeters, startBearing);
        final p2 = distance.offset(center, radiusMeters, midBearing);
        final p3 = distance.offset(center, radiusMeters, endBearing);

        rings.add(
          Polyline(
            points: [p1, p2, p3],
            color: ringColor,
            strokeWidth: 3.0,
            borderColor: Colors.black.withAlpha(80),
            borderStrokeWidth: 0.8,
          ),
        );
      }
    }

    return rings;
  }

  static double readWaterLevelCm(Map<String, dynamic> report) {
    const keys = [
      'water_level_cm',
      'water_level',
      'depth_cm',
      'flood_depth_cm',
    ];
    for (final key in keys) {
      final value = report[key];
      if (value is num) return value.toDouble();
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return 0;
  }

  static void showReportDetails(
    _HomePageState state,
    Map<String, dynamic> report,
  ) {
    showModalBottomSheet(
      context: state.context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Color(0xFF2D3848),
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (report['image_url'] != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: Image.network(
                  report['image_url'],
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            const SizedBox(height: 15),
            Text(
              report['location_name'] ?? "Flood Report",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            state._buildDetailRow(
              Icons.comment,
              "Note",
              report['user_comments'] ?? "No description.",
            ),
          ],
        ),
      ),
    );
  }

  static Widget buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF00FBFF), size: 20),
          const SizedBox(width: 12),
          Text(
            "$label: ",
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
