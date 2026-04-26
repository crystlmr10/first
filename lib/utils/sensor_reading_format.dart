/// Formats sensor numeric readings for UI without rounding away stored precision.
String formatSensorReading(num value) {
  if (value is int) return value.toString();
  return value.toDouble().toString();
}
