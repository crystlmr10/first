# Floote

Flood-aware routing and dispatch application (Flutter mobile + FastAPI).

## Secrets & local setup

Do **not** commit API keys or `google-services.json`. This repo uses compile-time configuration.

1. **Copy templates**
   - `cp android/app/google-services.json.example android/app/google-services.json` and replace values from the [Firebase Console](https://console.firebase.google.com/) (download **google-services.json** for your Android app, or merge keys into the example structure).
   - Set `android/app/src/main/res/values/google_maps_api.xml` to your **Maps SDK for Android** key (replace `YOUR_GOOGLE_MAPS_ANDROID_KEY`), or keep the placeholder until you add a real key.

2. **Dart defines (Supabase + Firebase options)**  
   Copy `secrets.example.json` to `secrets.json` (gitignored), fill in real values, then run:

   ```bash
   flutter run --dart-define-from-file=secrets.json
   ```

   Or pass variables individually:

   ```bash
   flutter run \
     --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
     --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY \
     --dart-define=FIREBASE_ANDROID_API_KEY=YOUR_KEY \
     --dart-define=FIREBASE_ANDROID_APP_ID=YOUR_APP_ID \
     --dart-define=FIREBASE_MESSAGING_SENDER_ID=YOUR_SENDER_ID \
     --dart-define=FIREBASE_PROJECT_ID=YOUR_PROJECT_ID \
     --dart-define=FIREBASE_STORAGE_BUCKET=YOUR_BUCKET
   ```

   Values match the fields in `lib/firebase_options.dart` and `lib/main.dart`.

3. **If keys were ever pushed to a public remote**, rotate them in Google Cloud, Firebase, and Supabase and treat the old keys as compromised.

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
