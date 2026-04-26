import 'dart:async';

import 'package:first/utils/sensor_reading_format.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Mirrors [the_basics] admin historical logs: filters, trend chart, paginated table, recent events.
/// Reads `sensor_logs` when available; falls back to latest row per sensor from `sensors`.
class RescuerHistoricalLogsPage extends StatefulWidget {
  const RescuerHistoricalLogsPage({super.key});

  @override
  State<RescuerHistoricalLogsPage> createState() => _RescuerHistoricalLogsPageState();
}

class HistoricalLogRow {
  final String id;
  final DateTime ts;
  final String location;
  final double waterLevelCm;

  const HistoricalLogRow({
    required this.id,
    required this.ts,
    required this.location,
    required this.waterLevelCm,
  });
}

enum FloodLabel { normal, lowFlood, deepFlood }

class _RescuerHistoricalLogsPageState extends State<RescuerHistoricalLogsPage> {
  final TextEditingController _searchCtrl = TextEditingController();

  DateTimeRange? _range;
  String _locationFilter = 'All';
  String _chartLocation = '';

  List<HistoricalLogRow> _allRows = const [];
  StreamSubscription<List<Map<String, dynamic>>>? _sub;
  bool _useSensorLogs = true;

  @override
  void initState() {
    super.initState();
    unawaited(_probeSensorLogsTableThenAttach());
  }

  /// If `sensor_logs` is missing or blocked, use `sensors` live rows (same as dashboard fallback).
  Future<void> _probeSensorLogsTableThenAttach() async {
    var useLogs = true;
    try {
      await Supabase.instance.client.from('sensor_logs').select('id').limit(1).maybeSingle();
    } catch (_) {
      useLogs = false;
    }
    if (!mounted) return;
    setState(() => _useSensorLogs = useLogs);
    _attachStream();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _attachStream() {
    _sub?.cancel();
    final client = Supabase.instance.client;
    if (_useSensorLogs) {
      _sub = client.from('sensor_logs').stream(primaryKey: ['id']).listen(
        _onRawRows,
        onError: (_) {
          if (!mounted) return;
          setState(() {
            _useSensorLogs = false;
            _allRows = const [];
          });
          _attachStream();
        },
      );
    } else {
      _sub = client.from('sensors').stream(primaryKey: ['id']).listen(_onSensorRowsAsLogs);
    }
  }

  void _onRawRows(List<Map<String, dynamic>> raw) {
    final rows = raw.map(_rowFromSensorLog).whereType<HistoricalLogRow>().toList()
      ..sort((a, b) => b.ts.compareTo(a.ts));
    if (!mounted) return;
    setState(() {
      _allRows = rows;
      _ensureChartLocation();
    });
  }

  void _onSensorRowsAsLogs(List<Map<String, dynamic>> raw) {
    final nodes = _parseSensorNodes(raw);
    final rows = nodes
        .map(
          (n) => HistoricalLogRow(
            id: 'LOG-${n.sensorId}-${n.lastSeen.millisecondsSinceEpoch}',
            ts: n.lastSeen,
            location: n.locationName,
            waterLevelCm: n.waterLevelCm,
          ),
        )
        .toList()
      ..sort((a, b) => b.ts.compareTo(a.ts));
    if (!mounted) return;
    setState(() {
      _allRows = rows;
      _ensureChartLocation();
    });
  }

  void _ensureChartLocation() {
    final locs = _locationNames;
    if (_chartLocation.isEmpty || !locs.contains(_chartLocation)) {
      _chartLocation = locs.isNotEmpty ? locs.first : '';
    }
    if (_locationFilter != 'All' && !locs.contains(_locationFilter)) {
      _locationFilter = 'All';
    }
  }

  List<String> get _locationNames {
    final set = <String>{};
    for (final r in _allRows) {
      if (r.location.isNotEmpty) set.add(r.location);
    }
    final list = set.toList()..sort();
    return list;
  }

  List<String> get _locations => ['All', ..._locationNames];

  HistoricalLogRow? _rowFromSensorLog(Map<String, dynamic> m) {
    final tsRaw = m['recorded_at'] ?? m['created_at'];
    final ts = DateTime.tryParse(tsRaw?.toString() ?? '')?.toLocal();
    if (ts == null) return null;
    final loc = (m['location_name'] ?? m['location'] ?? 'Unknown').toString();
    final id = (m['id'] ?? m['sensor_id'] ?? '').toString();
    return HistoricalLogRow(
      id: id.isEmpty ? 'log-${ts.millisecondsSinceEpoch}' : id,
      ts: ts,
      location: loc,
      waterLevelCm: _asDouble(m['water_level_cm']),
    );
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 1200;

    final filtered = _filteredRows();
    final chartRows = filtered.where((r) => r.location == _chartLocation).toList()
      ..sort((a, b) => a.ts.compareTo(b.ts));

    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FA),
      appBar: AppBar(
        title: const Text(
          'Historical Data Logs',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: const Color(0xFF101A24),
        foregroundColor: Colors.white,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (_allRows.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _useSensorLogs
                      ? 'No log rows yet. When sensor_logs fills (or sensors update), data appears here.'
                      : 'No sensor records found.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.55),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            );
          }

          final chartLocs = _locations.where((l) => l != 'All').toList();
          if (chartLocs.isEmpty) {
            return const Center(child: Text('No locations in dataset.'));
          }
          if (!chartLocs.contains(_chartLocation)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _chartLocation = chartLocs.first);
            });
          }

          return Padding(
            padding: const EdgeInsets.all(16),
            child: isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: Column(
                          children: [
                            _FiltersCard(
                              locations: _locations,
                              selectedLocation: _locationFilter,
                              onLocationChanged: (v) => setState(() => _locationFilter = v),
                              range: _range,
                              onPickRange: _pickRange,
                              searchCtrl: _searchCtrl,
                              onSearchChanged: (_) => setState(() {}),
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              child: _AnalyticsAndTable(
                                scheme: scheme,
                                chartLocations: chartLocs,
                                chartLocation: chartLocs.contains(_chartLocation) ? _chartLocation : chartLocs.first,
                                onChartLocationChanged: (v) => setState(() => _chartLocation = v),
                                chartRows: chartRows,
                                tableRows: filtered,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 360,
                        child: _RecentEventsSidebar(rows: filtered),
                      ),
                    ],
                  )
                : CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate(
                            [
                              _FiltersCard(
                                locations: _locations,
                                selectedLocation: _locationFilter,
                                onLocationChanged: (v) => setState(() => _locationFilter = v),
                                range: _range,
                                onPickRange: _pickRange,
                                searchCtrl: _searchCtrl,
                                onSearchChanged: (_) => setState(() {}),
                              ),
                              const SizedBox(height: 16),
                              _ExpandableLogCard(
                                title: 'Water Level Trend',
                                icon: Icons.show_chart,
                                initiallyExpanded: true,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    _LocationDropdown(
                                      label: 'Chart view',
                                      value: chartLocs.contains(_chartLocation) ? _chartLocation : chartLocs.first,
                                      locations: chartLocs,
                                      onChanged: (v) => setState(() => _chartLocation = v),
                                      fullWidth: true,
                                    ),
                                    const SizedBox(height: 12),
                                    SizedBox(
                                      height: 260,
                                      child: _WaterLevelLineChart(
                                        scheme: scheme,
                                        chartRows: chartRows,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              _ExpandableLogCard(
                                title: 'Data Logs',
                                icon: Icons.table_chart_outlined,
                                initiallyExpanded: true,
                                child: SizedBox(
                                  height: 380,
                                  child: Theme(
                                    data: Theme.of(context).copyWith(
                                      dividerColor: Colors.black.withValues(alpha: 0.06),
                                    ),
                                    child: _ScrollableDataLogsTable(rows: filtered),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              _ExpandableLogCard(
                                title: 'Recent Events',
                                icon: Icons.notifications_active_outlined,
                                initiallyExpanded: true,
                                child: SizedBox(
                                  height: 240,
                                  child: _RecentEventsListBody(rows: filtered),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final initial = _range ??
        DateTimeRange(
          start: now.subtract(const Duration(days: 7)),
          end: now,
        );

    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: initial,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 1),
      helpText: 'Select date range',
    );
    if (!mounted) return;
    if (picked != null) setState(() => _range = picked);
  }

  List<HistoricalLogRow> _filteredRows() {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _allRows.where((row) {
      if (_locationFilter != 'All' && row.location != _locationFilter) return false;

      if (_range != null) {
        final start = DateTime(_range!.start.year, _range!.start.month, _range!.start.day);
        final end = DateTime(_range!.end.year, _range!.end.month, _range!.end.day, 23, 59, 59);
        if (row.ts.isBefore(start) || row.ts.isAfter(end)) return false;
      }

      if (q.isEmpty) return true;
      final tsStr = _HistoricalLogsFormat.formatTs(row.ts).toLowerCase();
      return row.id.toLowerCase().contains(q) || tsStr.contains(q);
    }).toList()
      ..sort((a, b) => b.ts.compareTo(a.ts));
  }
}

// --- Sensor fallback parsing (aligned with RescuerSensorNetworkPage) ---

class _SensorNodeLite {
  final String locationName;
  final String sensorId;
  final DateTime lastSeen;
  final double waterLevelCm;

  const _SensorNodeLite({
    required this.locationName,
    required this.sensorId,
    required this.lastSeen,
    required this.waterLevelCm,
  });
}

List<_SensorNodeLite> _parseSensorNodes(List<Map<String, dynamic>> rows) {
  return rows.map((r) {
    final lastUpdated = DateTime.tryParse((r['last_updated'] ?? '').toString()) ?? DateTime.now();
    return _SensorNodeLite(
      locationName: (r['location_name'] ?? 'Unknown Location').toString(),
      sensorId: (r['sensor_id'] ?? (r['id'] ?? '')).toString(),
      lastSeen: lastUpdated.toLocal(),
      waterLevelCm: _snAsDouble(r['water_level_cm']),
    );
  }).toList();
}

double _snAsDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0.0;
  return 0.0;
}

// --- UI widgets (mirrored from the_basics historical_logs.dart) ---

class _FiltersCard extends StatelessWidget {
  final List<String> locations;
  final String selectedLocation;
  final ValueChanged<String> onLocationChanged;
  final DateTimeRange? range;
  final VoidCallback onPickRange;
  final TextEditingController searchCtrl;
  final ValueChanged<String> onSearchChanged;

  const _FiltersCard({
    required this.locations,
    required this.selectedLocation,
    required this.onLocationChanged,
    required this.range,
    required this.onPickRange,
    required this.searchCtrl,
    required this.onSearchChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const _CardTitle(icon: Icons.filter_alt_outlined, title: 'Filters'),
            _RangeButton(range: range, onPick: onPickRange),
            _LocationDropdown(
              label: 'Location',
              value: selectedLocation,
              locations: locations,
              onChanged: onLocationChanged,
            ),
            SizedBox(
              width: 320,
              child: TextField(
                controller: searchCtrl,
                onChanged: onSearchChanged,
                decoration: InputDecoration(
                  hintText: 'Search timestamps or IDs…',
                  prefixIcon: const Icon(Icons.search),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnalyticsAndTable extends StatelessWidget {
  final ColorScheme scheme;
  final List<String> chartLocations;
  final String chartLocation;
  final ValueChanged<String> onChartLocationChanged;
  final List<HistoricalLogRow> chartRows;
  final List<HistoricalLogRow> tableRows;

  const _AnalyticsAndTable({
    required this.scheme,
    required this.chartLocations,
    required this.chartLocation,
    required this.onChartLocationChanged,
    required this.chartRows,
    required this.tableRows,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 320,
          child: _TrendCard(
            scheme: scheme,
            chartLocations: chartLocations,
            chartLocation: chartLocation,
            onChartLocationChanged: onChartLocationChanged,
            chartRows: chartRows,
          ),
        ),
        const SizedBox(height: 16),
        Expanded(child: _TableCard(rows: tableRows)),
      ],
    );
  }
}

class _TrendCard extends StatelessWidget {
  final ColorScheme scheme;
  final List<String> chartLocations;
  final String chartLocation;
  final ValueChanged<String> onChartLocationChanged;
  final List<HistoricalLogRow> chartRows;

  const _TrendCard({
    required this.scheme,
    required this.chartLocations,
    required this.chartLocation,
    required this.onChartLocationChanged,
    required this.chartRows,
  });

  @override
  Widget build(BuildContext context) {
    final narrowHeader = MediaQuery.sizeOf(context).width < 560;
    return _CardShell(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (narrowHeader)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _CardTitle(icon: Icons.show_chart, title: 'Water Level Trend'),
                  const SizedBox(height: 10),
                  _LocationDropdown(
                    label: 'Chart view',
                    value: chartLocation,
                    locations: chartLocations,
                    onChanged: onChartLocationChanged,
                    fullWidth: true,
                  ),
                ],
              )
            else
              Row(
                children: [
                  const Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _CardTitle(icon: Icons.show_chart, title: 'Water Level Trend'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: _LocationDropdown(
                      label: 'Chart view',
                      value: chartLocation,
                      locations: chartLocations,
                      onChanged: onChartLocationChanged,
                      compact: true,
                      fullWidth: true,
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            Expanded(
              child: _WaterLevelLineChart(
                scheme: scheme,
                chartRows: chartRows,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Line chart only (shared by desktop trend card and mobile expandable section).
class _WaterLevelLineChart extends StatelessWidget {
  final ColorScheme scheme;
  final List<HistoricalLogRow> chartRows;

  const _WaterLevelLineChart({
    required this.scheme,
    required this.chartRows,
  });

  @override
  Widget build(BuildContext context) {
    final primary = scheme.primary;
    final spots = <FlSpot>[];

    for (int i = 0; i < chartRows.length; i++) {
      spots.add(FlSpot(i.toDouble(), chartRows[i].waterLevelCm));
    }

    final maxY =
        (chartRows.isEmpty ? 40.0 : chartRows.map((e) => e.waterLevelCm).reduce((a, b) => a > b ? a : b)) + 5;

    if (chartRows.isEmpty) {
      return Center(
        child: Text(
          'No data for selected filters.',
          style: TextStyle(color: Colors.black.withValues(alpha: 0.55), fontWeight: FontWeight.w700),
        ),
      );
    }

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY,
        gridData: const FlGridData(show: true, drawVerticalLine: false, horizontalInterval: 10),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 56,
              interval: 10,
              getTitlesWidget: (v, meta) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${formatSensorReading(v)}cm',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.blueGrey,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: (chartRows.length / 4).clamp(1, 9999).toDouble(),
              getTitlesWidget: (v, meta) {
                final idx = v.round().clamp(0, chartRows.length - 1);
                final ts = chartRows[idx].ts;
                String two(int x) => x.toString().padLeft(2, '0');
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${two(ts.hour)}:${two(ts.minute)}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.blueGrey,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            isCurved: true,
            curveSmoothness: 0.25,
            spots: spots,
            barWidth: 3,
            color: primary,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  primary.withValues(alpha: 0.28),
                  primary.withValues(alpha: 0.00),
                ],
              ),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          handleBuiltInTouches: true,
          touchTooltipData: LineTouchTooltipData(
            tooltipRoundedRadius: 12,
            getTooltipItems: (items) {
              return items.map((it) {
                final idx = it.x.round().clamp(0, chartRows.length - 1);
                final row = chartRows[idx];
                return LineTooltipItem(
                  '${_HistoricalLogsFormat.formatTs(row.ts)}\n${formatSensorReading(row.waterLevelCm)} cm',
                  const TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
                );
              }).toList();
            },
          ),
        ),
      ),
    );
  }
}

class _ExpandableLogCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final bool initiallyExpanded;

  const _ExpandableLogCard({
    required this.title,
    required this.icon,
    required this.child,
    this.initiallyExpanded = true,
  });

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
          shape: const Border(),
          collapsedShape: const Border(),
          iconColor: Colors.blueGrey.shade700,
          collapsedIconColor: Colors.blueGrey.shade700,
          title: Row(
            children: [
              Icon(icon, size: 20, color: Colors.blueGrey),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
                ),
              ),
            ],
          ),
          children: [child],
        ),
      ),
    );
  }
}

class _HistoricalLogsFormat {
  _HistoricalLogsFormat._();

  static FloodLabel labelFor(double cm) {
    if (cm < 15) return FloodLabel.normal;
    if (cm <= 30) return FloodLabel.lowFlood;
    return FloodLabel.deepFlood;
  }

  static String formatTs(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _TableCard extends StatefulWidget {
  final List<HistoricalLogRow> rows;
  final int? initialRowsPerPage;
  final bool wrapWithCard;

  const _TableCard({
    required this.rows,
    this.initialRowsPerPage,
    this.wrapWithCard = true,
  });

  @override
  State<_TableCard> createState() => _TableCardState();
}

class _TableCardState extends State<_TableCard> {
  late int _rowsPerPage;

  @override
  void initState() {
    super.initState();
    _rowsPerPage = widget.initialRowsPerPage ?? PaginatedDataTable.defaultRowsPerPage;
  }

  @override
  void didUpdateWidget(_TableCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialRowsPerPage != null && widget.initialRowsPerPage != oldWidget.initialRowsPerPage) {
      _rowsPerPage = widget.initialRowsPerPage!;
    }
  }

  @override
  Widget build(BuildContext context) {
    final table = Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.black.withValues(alpha: 0.06),
      ),
      child: PaginatedDataTable(
        header: const Row(
          children: [
            Icon(Icons.table_chart_outlined, size: 18),
            SizedBox(width: 10),
            Text('Data Logs', style: TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
        columns: const [
          DataColumn(label: Text('Time & Date')),
          DataColumn(label: Text('Location')),
          DataColumn(label: Text('Water Level (cm)')),
          DataColumn(label: Text('Flood Label')),
        ],
        source: _LogsTableSource(widget.rows),
        rowsPerPage: _rowsPerPage,
        availableRowsPerPage: widget.initialRowsPerPage != null ? const [5, 10, 20, 50] : const [10, 20, 50, 100],
        onRowsPerPageChanged: (v) {
          if (v == null) return;
          setState(() => _rowsPerPage = v);
        },
        showFirstLastButtons: true,
      ),
    );

    if (!widget.wrapWithCard) return table;
    return _CardShell(child: table);
  }
}

DataRow _buildHistoricalDataRow(HistoricalLogRow r, int index) {
  final label = _HistoricalLogsFormat.labelFor(r.waterLevelCm);
  final badge = _FloodBadge(label: label);
  return DataRow.byIndex(
    index: index,
    cells: [
      DataCell(Text(_HistoricalLogsFormat.formatTs(r.ts), style: const TextStyle(fontWeight: FontWeight.w700))),
      DataCell(Text(r.location)),
      DataCell(Text(formatSensorReading(r.waterLevelCm), style: const TextStyle(fontWeight: FontWeight.w800))),
      DataCell(badge),
    ],
  );
}

/// Mobile-friendly: [PaginatedDataTable] overflows fixed heights; this scrolls vertically and horizontally.
class _ScrollableDataLogsTable extends StatelessWidget {
  final List<HistoricalLogRow> rows;

  const _ScrollableDataLogsTable({required this.rows});

  static const List<DataColumn> _columns = [
    DataColumn(label: Text('Time & Date')),
    DataColumn(label: Text('Location')),
    DataColumn(label: Text('Water Level (cm)')),
    DataColumn(label: Text('Flood Label')),
  ];

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).dividerColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
          child: Row(
            children: [
              const Icon(Icons.table_chart_outlined, size: 18),
              const SizedBox(width: 10),
              Text('Data Logs', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.grey.shade900)),
            ],
          ),
        ),
        Expanded(
          child: Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              primary: false,
              physics: const AlwaysScrollableScrollPhysics(),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                primary: false,
                child: DataTable(
                  dividerThickness: 1,
                  border: TableBorder(
                    horizontalInside: BorderSide(color: divider.withValues(alpha: 0.12)),
                  ),
                  columnSpacing: 16,
                  horizontalMargin: 12,
                  headingRowHeight: 44,
                  dataRowMinHeight: 44,
                  dataRowMaxHeight: 56,
                  columns: _columns,
                  rows: [
                    for (var i = 0; i < rows.length; i++) _buildHistoricalDataRow(rows[i], i),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LogsTableSource extends DataTableSource {
  final List<HistoricalLogRow> rows;
  _LogsTableSource(this.rows);

  @override
  DataRow? getRow(int index) {
    if (index < 0 || index >= rows.length) return null;
    return _buildHistoricalDataRow(rows[index], index);
  }

  @override
  bool get isRowCountApproximate => false;

  @override
  int get rowCount => rows.length;

  @override
  int get selectedRowCount => 0;
}

/// Scrollable critical events list (no outer card — for mobile [ExpansionTile]).
class _RecentEventsListBody extends StatelessWidget {
  final List<HistoricalLogRow> rows;
  const _RecentEventsListBody({required this.rows});

  @override
  Widget build(BuildContext context) {
    final critical = rows
        .where((r) => _HistoricalLogsFormat.labelFor(r.waterLevelCm) == FloodLabel.deepFlood)
        .take(12)
        .toList();

    if (critical.isEmpty) {
      return Center(
        child: Text(
          'No recent critical updates.',
          style: TextStyle(color: Colors.black.withValues(alpha: 0.55), fontWeight: FontWeight.w700),
        ),
      );
    }

    return ListView.separated(
      physics: const BouncingScrollPhysics(),
      itemCount: critical.length,
      separatorBuilder: (_, __) => Divider(color: Colors.black.withValues(alpha: 0.06)),
      itemBuilder: (context, i) {
        final r = critical[i];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(top: 5),
              decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${r.location} reached Danger Level',
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_HistoricalLogsFormat.formatTs(r.ts)} • ${formatSensorReading(r.waterLevelCm)} cm',
                    style: const TextStyle(
                      color: Colors.blueGrey,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RecentEventsSidebar extends StatelessWidget {
  final List<HistoricalLogRow> rows;
  const _RecentEventsSidebar({required this.rows});

  @override
  Widget build(BuildContext context) {
    return _CardShell(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _CardTitle(icon: Icons.notifications_active_outlined, title: 'Recent Events'),
            const SizedBox(height: 12),
            Expanded(
              child: _RecentEventsListBody(rows: rows),
            ),
          ],
        ),
      ),
    );
  }
}

class _FloodBadge extends StatelessWidget {
  final FloodLabel label;
  const _FloodBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    final (text, bg, fg) = switch (label) {
      FloodLabel.normal => ('Normal', Colors.green, Colors.white),
      FloodLabel.lowFlood => ('Low Flood', Colors.orange, Colors.white),
      FloodLabel.deepFlood => ('Deep Flood', Colors.redAccent, Colors.white),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [BoxShadow(color: bg.withValues(alpha: 0.18), blurRadius: 16, offset: const Offset(0, 10))],
      ),
      child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w900, fontSize: 11)),
    );
  }
}

class _CardShell extends StatelessWidget {
  final Widget child;
  const _CardShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 16, offset: const Offset(0, 10))],
      ),
      child: child,
    );
  }
}

class _CardTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  const _CardTitle({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: Colors.blueGrey),
        const SizedBox(width: 10),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
      ],
    );
  }
}

class _LocationDropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<String> locations;
  final ValueChanged<String> onChanged;
  final bool compact;
  final bool fullWidth;

  const _LocationDropdown({
    required this.label,
    required this.value,
    required this.locations,
    required this.onChanged,
    this.compact = false,
    this.fullWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    final child = DropdownButtonFormField<String>(
      key: ValueKey(value),
      isExpanded: true,
      initialValue: locations.contains(value) ? value : (locations.isNotEmpty ? locations.first : null),
      items: locations.map((l) => DropdownMenuItem(value: l, child: Text(l, overflow: TextOverflow.ellipsis))).toList(),
      onChanged: (v) {
        if (v == null) return;
        onChanged(v);
      },
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        isDense: true,
      ),
    );

    if (fullWidth) {
      return SizedBox(width: double.infinity, child: child);
    }
    if (!compact) return SizedBox(width: 260, child: child);
    return SizedBox(width: 260, height: 44, child: child);
  }
}

class _RangeButton extends StatelessWidget {
  final DateTimeRange? range;
  final VoidCallback onPick;
  const _RangeButton({required this.range, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final text = range == null
        ? 'Pick date range'
        : '${range!.start.year}-${range!.start.month.toString().padLeft(2, '0')}-${range!.start.day.toString().padLeft(2, '0')} → '
            '${range!.end.year}-${range!.end.month.toString().padLeft(2, '0')}-${range!.end.day.toString().padLeft(2, '0')}';

    return OutlinedButton.icon(
      onPressed: onPick,
      icon: const Icon(Icons.date_range),
      label: Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: Colors.black.withValues(alpha: 0.12)),
      ),
    );
  }
}
