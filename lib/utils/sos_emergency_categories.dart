/// Stable keys for [public.sos_dispatches.emergency_main_category] /
/// [emergency_subcategory] (citizen SOS wizard).
abstract final class SosEmergencyMainKeys {
  SosEmergencyMainKeys._();
  static const naturalDisaster = 'natural_disaster';
  static const medical = 'medical';
  static const fire = 'fire';
  static const crime = 'crime';
  static const roadAccident = 'road_accident';
}

/// Ordered main categories (UI + iteration).
const List<String> sosEmergencyMainOrder = [
  SosEmergencyMainKeys.naturalDisaster,
  SosEmergencyMainKeys.medical,
  SosEmergencyMainKeys.fire,
  SosEmergencyMainKeys.crime,
  SosEmergencyMainKeys.roadAccident,
];

const Map<String, String> sosEmergencyMainEmoji = {
  SosEmergencyMainKeys.naturalDisaster: '🌊',
  SosEmergencyMainKeys.medical: '🏥',
  SosEmergencyMainKeys.fire: '🔥',
  SosEmergencyMainKeys.crime: '🚨',
  SosEmergencyMainKeys.roadAccident: '🚗',
};

const Map<String, String> sosEmergencyMainLabels = {
  SosEmergencyMainKeys.naturalDisaster: 'Natural disaster',
  SosEmergencyMainKeys.medical: 'Medical emergency',
  SosEmergencyMainKeys.fire: 'Fire',
  SosEmergencyMainKeys.crime: 'Crime in progress',
  SosEmergencyMainKeys.roadAccident: 'Road accident',
};

/// Sub keys per main (order preserved for UI).
const Map<String, List<String>> sosEmergencySubKeysByMain = {
  SosEmergencyMainKeys.naturalDisaster: [
    'flood',
    'earthquake',
    'landslide',
    'other',
  ],
  SosEmergencyMainKeys.medical: [
    'injury',
    'unconscious',
    'chest_pain',
    'other',
  ],
  SosEmergencyMainKeys.fire: [
    'building',
    'house',
    'vehicle',
    'other',
  ],
  SosEmergencyMainKeys.crime: [
    'theft',
    'assault',
    'threat',
    'other',
  ],
  SosEmergencyMainKeys.roadAccident: [
    'collision',
    'vehicle_overturned',
    'other',
  ],
};

String sosEmergencySubLabel(String mainKey, String subKey) {
  final map = sosEmergencySubLabelsByMain[mainKey];
  if (map == null) return subKey;
  return map[subKey] ?? subKey;
}

const Map<String, Map<String, String>> sosEmergencySubLabelsByMain = {
  SosEmergencyMainKeys.naturalDisaster: {
    'flood': 'Flood',
    'earthquake': 'Earthquake',
    'landslide': 'Landslide',
    'other': 'Other',
  },
  SosEmergencyMainKeys.medical: {
    'injury': 'Injury',
    'unconscious': 'Unconscious',
    'chest_pain': 'Chest pain',
    'other': 'Other',
  },
  SosEmergencyMainKeys.fire: {
    'building': 'Building',
    'house': 'House',
    'vehicle': 'Vehicle',
    'other': 'Other',
  },
  SosEmergencyMainKeys.crime: {
    'theft': 'Theft',
    'assault': 'Assault',
    'threat': 'Threat',
    'other': 'Other',
  },
  SosEmergencyMainKeys.roadAccident: {
    'collision': 'Collision',
    'vehicle_overturned': 'Vehicle overturned',
    'other': 'Other',
  },
};

/// Human-readable line for SOS Details (e.g. `Natural disaster (Flood)`).
String formatSosEmergencyTypeLine(
  String? mainKey,
  String? subKey,
  String? otherNote,
) {
  final m = mainKey?.trim() ?? '';
  final s = subKey?.trim() ?? '';
  if (m.isEmpty || s.isEmpty) return '—';
  final main = sosEmergencyMainLabels[m] ?? m;
  if (s == 'other') {
    final note = otherNote?.trim() ?? '';
    if (note.isNotEmpty) return '$main (Other: $note)';
    return '$main (Other)';
  }
  final sub = sosEmergencySubLabel(m, s);
  return '$main ($sub)';
}
