import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:first/utils/sensor_reading_format.dart';

/// Live flood-related alerts: sensor readings and community reports.
/// Only shows items that pass [shouldIncludeSensorStatus] / [shouldIncludeReportDecision].
class AlertsPage extends StatefulWidget {
  const AlertsPage({super.key});

  @override
  State<AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<AlertsPage> {
  late Future<_AlertsData> _load;

  @override
  void initState() {
    super.initState();
    _load = _fetchAlerts();
  }

  Future<void> _refresh() async {
    setState(() {
      _load = _fetchAlerts();
    });
    await _load;
  }

  Future<_AlertsData> _fetchAlerts() async {
    final client = Supabase.instance.client;
    final sensorRes = await client
        .from('sensor_logs')
        .select('id,sensor_id,water_level_cm,rssi_dbm,status,created_at')
        .order('created_at', ascending: false)
        .limit(100);
    final reportRes = await client
        .from('user_reports')
        .select(
          'id,user_id,location_name,user_comments,image_url,latitude,longitude,admin_decision,created_at',
        )
        .order('created_at', ascending: false)
        .limit(100);

    final sensorRows = List<Map<String, dynamic>>.from(sensorRes as List);
    final reportRows = List<Map<String, dynamic>>.from(reportRes as List);

    final sensors = <Map<String, dynamic>>[];
    for (final row in sensorRows) {
      final status = row['status']?.toString();
      if (!shouldIncludeSensorStatus(status)) continue;
      sensors.add(row);
    }

    final reports = <Map<String, dynamic>>[];
    for (final row in reportRows) {
      final decision = row['admin_decision']?.toString();
      if (!shouldIncludeReportDecision(decision)) continue;
      reports.add(row);
    }

    return _AlertsData(sensors: sensors, reports: reports);
  }

  /// Shown in Alerts list: risky, danger, critical, impassable; also common DB values
  /// like "Severe Flooding" (treated as critical).
  static bool shouldIncludeSensorStatus(String? status) {
    final tier = _sensorStatusTier(status);
    return tier != null;
  }

  /// Shown in Alerts list for [user_reports.admin_decision] (no status shown on card).
  static bool shouldIncludeReportDecision(String? adminDecision) {
    final s = (adminDecision ?? '').trim().toLowerCase();
    if (s.isEmpty) return false;
    if (s == 'pending' || s == 'passable' || s == 'normal' || s == 'safe') {
      return false;
    }
    const allow = {
      'risky',
      'danger',
      'critical',
      'impassable',
      'severe_flood',
      'severe flooding',
    };
    if (allow.contains(s)) return true;
    if (s.contains('severe')) return true;
    if (s.contains('impassable')) return true;
    if (s.contains('risk')) return true;
    if (s.contains('danger') || s.contains('critical')) return true;
    return false;
  }

  static _AlertDisplayTier? _sensorStatusTier(String? status) {
    final raw = (status ?? '').trim();
    if (raw.isEmpty) return null;
    final t = raw.toLowerCase();
    if (t == 'normal' || (t.contains('safe') && !t.contains('unsafe'))) {
      return null;
    }
    if (t.contains('severe') || t.contains('critical')) {
      return _AlertDisplayTier.critical;
    }
    if (t.contains('impassable') || t.contains('impass')) {
      return _AlertDisplayTier.impassable;
    }
    if (t.contains('danger')) {
      return _AlertDisplayTier.danger;
    }
    if (t.contains('risky') || t.contains('risk') || t.contains('warning')) {
      return _AlertDisplayTier.risky;
    }
    if (t.contains('flood') && (t.contains('high') || t.contains('deep'))) {
      return _AlertDisplayTier.danger;
    }
    return null;
  }

  static _AlertDisplayTier _reportDecisionTier(String? decision) {
    final s = (decision ?? '').trim().toLowerCase();
    if (s.contains('severe') || s.contains('critical')) return _AlertDisplayTier.critical;
    if (s == 'impassable') return _AlertDisplayTier.impassable;
    if (s.contains('danger')) return _AlertDisplayTier.danger;
    if (s == 'risky' || s.contains('risk')) return _AlertDisplayTier.risky;
    return _AlertDisplayTier.danger;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: FutureBuilder<_AlertsData>(
        future: _load,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                    const SizedBox(height: 12),
                    Text(
                      'Could not load alerts',
                      style: TextStyle(
                        color: Colors.grey.shade800,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      snapshot.error.toString(),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _refresh,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          final data = snapshot.data ?? const _AlertsData(sensors: [], reports: []);
          final total = data.sensors.length + data.reports.length;

          return RefreshIndicator(
            onRefresh: _refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Expanded(
                          child: Text(
                            'Alerts',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (total > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFE4E1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFE53935),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '$total active',
                                  style: TextStyle(
                                    color: Colors.red.shade900,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: _StatusLegend(),
                  ),
                ),
                if (data.sensors.isEmpty && data.reports.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          'No active flood alerts right now.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 15),
                        ),
                      ),
                    ),
                  )
                else ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  if (data.sensors.isNotEmpty)
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => _SensorAlertCard(row: data.sensors[i]),
                        childCount: data.sensors.length,
                      ),
                    ),
                  if (data.reports.isNotEmpty)
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => _ReportAlertCard(row: data.reports[i]),
                        childCount: data.reports.length,
                      ),
                    ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
          );
        },
      ),
      ),
    );
  }

}

class _AlertsData {
  final List<Map<String, dynamic>> sensors;
  final List<Map<String, dynamic>> reports;

  const _AlertsData({required this.sensors, required this.reports});
}

enum _AlertDisplayTier { risky, danger, critical, impassable }

/// Matches mock: grey labels, navy bold values.
const TextStyle _kAlertMetricLabelStyle = TextStyle(
  color: Color(0xFF757575),
  fontSize: 13,
  fontWeight: FontWeight.w500,
);
const TextStyle _kAlertMetricValueStyle = TextStyle(
  color: Color(0xFF1A237E),
  fontSize: 13,
  fontWeight: FontWeight.w700,
);

/// Maps severity tier to mock-style second badge: MODERATE / DANGER / HIGH (pale red).
(String, Color, Color) _severityChipStyle(_AlertDisplayTier tier) {
  switch (tier) {
    case _AlertDisplayTier.risky:
      return ('MODERATE', const Color(0xFFFFF8E1), const Color(0xFFE65100));
    case _AlertDisplayTier.danger:
      return ('DANGER', const Color(0xFFFFEBEE), const Color(0xFFC62828));
    case _AlertDisplayTier.critical:
    case _AlertDisplayTier.impassable:
      return ('HIGH', const Color(0xFFFFEBEE), const Color(0xFFC62828));
  }
}

Widget _metricBlock({
  required String label,
  required String value,
  required TextStyle labelStyle,
  required TextStyle valueStyle,
}) {
  return Text.rich(
    TextSpan(
      children: [
        TextSpan(text: '$label: ', style: labelStyle),
        TextSpan(text: value, style: valueStyle),
      ],
    ),
  );
}

/// Rounded pill badge (SENSOR, HIGH, REPORTED, …).
Widget _badgeChip(String label, Color bg, Color fg) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: fg,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.4,
      ),
    ),
  );
}

class _SensorAlertCard extends StatelessWidget {
  final Map<String, dynamic> row;

  const _SensorAlertCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final status = row['status']?.toString() ?? '';
    final tier = _AlertsPageState._sensorStatusTier(status) ?? _AlertDisplayTier.danger;
    final sensorId = row['sensor_id']?.toString() ?? 'Sensor';
    final depth = row['water_level_cm'];
    final created = _parseTime(row['created_at']);
    final sev = _severityChipStyle(tier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: _AlertCardShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _badgeChip('SENSOR', const Color(0xFFE8F4FD), const Color(0xFF0D47A1)),
                const SizedBox(width: 8),
                _badgeChip(sev.$1, sev.$2, sev.$3),
                const Spacer(),
                Text(
                  _timeAgo(created),
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              sensorId,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 17,
                color: Color(0xFF0D1B2A),
                height: 1.25,
              ),
            ),
            const SizedBox(height: 12),
            _metricBlock(
              label: 'Depth',
              value: '${formatSensorReading(_num(depth) ?? 0)} cm',
              labelStyle: _kAlertMetricLabelStyle,
              valueStyle: _kAlertMetricValueStyle,
            ),
            const SizedBox(height: 14),
            Divider(height: 1, thickness: 1, color: Colors.grey.shade200),
            const SizedBox(height: 2),
            _SafetyGuideExpansion(tier: tier, isSensor: true),
          ],
        ),
      ),
    );
  }
}

class _ReportAlertCard extends StatelessWidget {
  final Map<String, dynamic> row;

  const _ReportAlertCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final loc = row['location_name']?.toString() ?? 'Reported location';
    final comments = row['user_comments']?.toString().trim();
    final created = _parseTime(row['created_at']);
    final tier = _AlertsPageState._reportDecisionTier(row['admin_decision']?.toString());
    final sev = _severityChipStyle(tier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: _AlertCardShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _badgeChip('REPORTED', const Color(0xFFF3E5F5), const Color(0xFF6A1B9A)),
                const SizedBox(width: 8),
                _badgeChip(sev.$1, sev.$2, sev.$3),
                const Spacer(),
                Text(
                  _timeAgo(created),
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              loc,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 17,
                color: Color(0xFF0D1B2A),
                height: 1.25,
              ),
            ),
            if (comments != null && comments.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                comments,
                style: TextStyle(color: Colors.grey.shade700, fontSize: 13, height: 1.35),
              ),
            ],
            const SizedBox(height: 12),
            _metricBlock(
              label: 'Depth',
              value: '—',
              labelStyle: _kAlertMetricLabelStyle,
              valueStyle: _kAlertMetricValueStyle,
            ),
            const SizedBox(height: 14),
            Divider(height: 1, thickness: 1, color: Colors.grey.shade200),
            const SizedBox(height: 2),
            _SafetyGuideExpansion(tier: tier, isSensor: false),
          ],
        ),
      ),
    );
  }
}

class _AlertCardShell extends StatelessWidget {
  final Widget child;

  const _AlertCardShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFFFCDD2), width: 1),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(10),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }
}

class _SafetyGuideExpansion extends StatelessWidget {
  final _AlertDisplayTier tier;
  final bool isSensor;

  const _SafetyGuideExpansion({required this.tier, required this.isSensor});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 6, bottom: 4),
        iconColor: Colors.grey.shade400,
        collapsedIconColor: Colors.grey.shade400,
        title: Text(
          'Safety guide',
          style: TextStyle(
            fontWeight: FontWeight.w400,
            fontSize: 14,
            color: Colors.grey.shade600,
          ),
        ),
        controlAffinity: ListTileControlAffinity.trailing,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _guideBody(tier, isSensor),
              style: TextStyle(
                color: Colors.grey.shade800,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _guideBody(_AlertDisplayTier tier, bool sensor) {
    final prefix = sensor
        ? 'Sensor readings help estimate conditions but local variation still happens (drains, slope, vehicles). '
        : 'This location was reported by someone in the community. Conditions can change quickly—use your judgment and official advisories when available. ';

    switch (tier) {
      case _AlertDisplayTier.risky:
        return '$prefix'
            'Risky (shallow to moderate flood risk)\n\n'
            '• Slow down and increase following distance; water hides potholes and debris.\n'
            '• Motorcycles and small cars are most affected—consider turning around or parking above flood level.\n'
            '• If water reaches wheel hubs or you see spray into the engine bay, stop and reverse out.\n'
            '• After passing through shallow water, tap brakes gently to dry them.\n'
            '• Never enter moving water, even if it looks shallow.';
      case _AlertDisplayTier.danger:
        return '$prefix'
            'Danger (deeper water likely)\n\n'
            '• Do not drive through if you cannot see the road surface or if water is moving.\n'
            '• Turn around and use Floote’s safer route suggestion when offered.\n'
            '• If you must leave the area, walk to higher ground on foot if driving is unsafe.\n'
            '• Keep phone charged; avoid underground parking and basement access.\n'
            '• Help others only if it is safe—call emergency services for trapped vehicles.';
      case _AlertDisplayTier.critical:
      case _AlertDisplayTier.impassable:
        return '$prefix'
            'Critical / impassable conditions\n\n'
            '• Assume the road may be unwalkable or unsafe for most vehicles.\n'
            '• Do not enter flooded streets; currents can sweep people and stall engines instantly.\n'
            '• Move to the highest safe floor; avoid contact with floodwater (contamination risk).\n'
            '• Follow evacuation routes from barangay/LGU; avoid driving around barricades.\n'
            '• If trapped in rising water, exit the vehicle if safe and move to higher ground; call emergency lines.\n'
            '• Help children, older adults, and persons with disabilities reach safe shelter first.';
    }
  }
}

class _StatusLegend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Status',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 13,
              color: Colors.grey.shade800,
            ),
          ),
          const SizedBox(height: 10),
          _legendRow(Icons.circle, const Color(0xFF43A047), 'Safe — normal conditions'),
          _divider(),
          _legendRow(Icons.circle, const Color(0xFFFFC107), 'Risky — exercise caution'),
          _divider(),
          _legendRow(Icons.circle, const Color(0xFFE53935), 'Danger — avoid travel through water'),
          _divider(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.sentiment_very_dissatisfied, size: 18, color: Colors.black54),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Critical — severe hazard; prioritize evacuation and safety',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800, height: 1.3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _divider() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Divider(height: 1, color: Colors.grey.shade300),
      );

  Widget _legendRow(IconData icon, Color color, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800, height: 1.3),
          ),
        ),
      ],
    );
  }
}

DateTime _parseTime(dynamic v) {
  if (v == null) return DateTime.now().toUtc();
  if (v is DateTime) return v.toUtc();
  return DateTime.tryParse(v.toString())?.toUtc() ?? DateTime.now().toUtc();
}

String _timeAgo(DateTime t) {
  final now = DateTime.now().toUtc();
  final d = now.difference(t.toUtc());
  if (d.inSeconds < 45) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} d ago';
  return '${t.toLocal().year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

num? _num(dynamic v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v);
  return null;
}
