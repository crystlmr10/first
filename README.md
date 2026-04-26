# Floote

Flood-aware routing and dispatch application (Flutter mobile + FastAPI).

## Runtime Flags

Use `--dart-define` to configure providers without code changes:

- `GOOGLE_MAPS_API_KEY`: Android map rendering key (stored in Android resources).
- `GOOGLE_PLACES_API_KEY`: Places (autocomplete/place details).
- `GOOGLE_GEOCODING_API_KEY`: Geocoding/reverse geocoding (optional if using Places key for geocode endpoint access).
- `GOOGLE_MAPS_WEB_SERVICES_API_KEY`: Routes/Roads web services for route shaping/snap.
- `USE_GOOGLE_ROUTING`: `true|false` toggle for Google Routes/Roads geometry shaping.
- `ALLOW_LEGACY_ROUTING_FALLBACK`: `true|false` allows fallback to OSRM if Google call fails.
- `ALLOW_LEGACY_GEOCODER_FALLBACK`: `true|false` allows Mapbox/Nominatim fallback when Google search/geocode returns empty.
- `ROUTING_DEBUG`: `true|false` emits route quality telemetry (`shapedPolyline` vs `cleanedPolyline`).

Example:

```bash
flutter run \
  --dart-define=GOOGLE_PLACES_API_KEY=YOUR_KEY \
  --dart-define=GOOGLE_MAPS_WEB_SERVICES_API_KEY=YOUR_KEY \
  --dart-define=GOOGLE_GEOCODING_API_KEY=YOUR_KEY \
  --dart-define=USE_GOOGLE_ROUTING=true \
  --dart-define=ALLOW_LEGACY_ROUTING_FALLBACK=true \
  --dart-define=ALLOW_LEGACY_GEOCODER_FALLBACK=false \
  --dart-define=ROUTING_DEBUG=true
```

## Staged Rollout Checklist

1. Enable `ROUTING_DEBUG=true` and record logs for known reroute scenarios.
2. Compare `shapedPolyline` vs `cleanedPolyline` max segment distance.
3. Verify no-road jumps on at least:
   - no-flood route
   - single impassable hazard
   - multi-hazard reroute
   - SOS dispatch map view
4. Keep legacy fallback enabled during initial rollout:
   - `ALLOW_LEGACY_ROUTING_FALLBACK=true`
5. After stability window, disable legacy fallback:
   - `ALLOW_LEGACY_ROUTING_FALLBACK=false`
   - `ALLOW_LEGACY_GEOCODER_FALLBACK=false`

## Key Restrictions

Restrict Google API keys per platform/API:

- Android map key: package + SHA1 restriction.
- Web service key: API-restricted to Routes/Roads/Geocoding/Places and not exposed publicly when possible.
- Do not commit raw secrets in source control.
