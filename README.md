# Floote

Flood-aware routing and dispatch app (Flutter + FastAPI).

## Quick Setup (CMD only)

Run these in **Command Prompt** at project root:

```cmd
copy secrets.example.json secrets.json
copy android\app\google-services.json.example android\app\google-services.json
copy android\app\google_maps_api.xml.example android\app\src\main\res\values\google_maps_api.xml
```

Then:
- Edit `secrets.json` with your real keys.
- Edit `android\app\google-services.json` with your Firebase Android config.
- Edit `android\app\src\main\res\values\google_maps_api.xml` and set your Maps key.

## Run

```cmd
flutter run --dart-define-from-file=secrets.json
```

## Important

- Do **not** use `--dart-define=secrets.json` (invalid format).
- Keep these local only (already gitignored):
  - `secrets.json`
  - `android\app\google-services.json`
  - `android\app\src\main\res\values\google_maps_api.xml`
- If keys were exposed before, rotate them in Google/Firebase/Supabase.
