# Rescuer SOS + Rescue Center setup

Run SQL in **Supabase → SQL Editor** in this order (adjust if your DB already has some objects):

1. [`sql/profiles_rescuer_duty_location.sql`](sql/profiles_rescuer_duty_location.sql)
2. [`sql/sos_dispatches_emergency_type.sql`](sql/sos_dispatches_emergency_type.sql) (if not already applied)
3. [`sql/device_tokens.sql`](sql/device_tokens.sql)
4. [`sql/sos_dispatch_offers.sql`](sql/sos_dispatch_offers.sql)
5. [`sql/sos_dispatches_assigned_rescuer.sql`](sql/sos_dispatches_assigned_rescuer.sql)
6. [`sql/sos_dispatch_offers_trigger_and_rpc.sql`](sql/sos_dispatch_offers_trigger_and_rpc.sql)
7. [`sql/profiles_rls_own_and_rescuer_read_citizen.sql`](sql/profiles_rls_own_and_rescuer_read_citizen.sql) — enables RLS on `profiles`, policies for **own** select/insert/update, and **rescuer** select for citizens tied to an SOS offer (so Rescue Center can show **username**). If you already use custom `profiles` RLS, review for conflicts before running.
8. [`sql/set_rescuer_on_duty_rpc.sql`](sql/set_rescuer_on_duty_rpc.sql) — `set_rescuer_on_duty(boolean)` so the app can toggle **Active duty** reliably (direct `UPDATE` can be blocked by RLS in some projects).
9. [`sql/set_rescuer_last_location_rpc.sql`](sql/set_rescuer_last_location_rpc.sql) — `set_rescuer_last_location(lat, lng)` for GPS heartbeat (`last_latitude`, `last_longitude`, `last_location_at`).
10. [`sql/sos_dispatches_status_realtime.sql`](sql/sos_dispatches_status_realtime.sql) — enables `sos_dispatches` realtime publication and `replica identity full` (needed for live destination updates in rescuer navigation).

The rescuer policy matches **whole** citizen rows for those offers (not only `username`). To limit columns, add a view or RPC later.

## Edge Function + FCM

1. Install [Supabase CLI](https://supabase.com/docs/guides/cli), link the project, deploy:

Install CLI using npm(node.js) //npm install supabase --save-dev
supabase login
supabase init
supabase link --project-ref ttsrktldvvqrgkfhsbbl

   ```bash
   supabase functions deploy sos-dispatch-notify --no-verify-jwt #take the code you wrote on your computer and upload it to their servers so it can run live.
   ```

2. In **Project Settings → Edge Functions → Secrets**, set:

   - `FCM_SERVICE_ACCOUNT_JSON` — full JSON of a Firebase service account with Firebase Cloud Messaging API enabled
   - `SOS_WEBHOOK_SECRET` — random string (optional, for `x-webhook-secret` header) XXXXXXXXXXXXXXXXX

3. **Database Webhooks** (Supabase Dashboard): create a webhook on `public.sos_dispatches` **INSERT** → URL `https://<project-ref>.supabase.co/functions/v1/sos-dispatch-notify` with header `x-webhook-secret: <same as secret>` if used.

https://ttsrktldvvqrgkfhsbbl.supabase.co/functions/v1/sos-dispatch-notify

## Flutter / Firebase (Android)

1. Add `android/app/google-services.json` from the Firebase Console (same project as the service account).
2. Optionally pass Firebase keys at build time, or run `flutterfire configure` and replace [`lib/firebase_options.dart`](../lib/firebase_options.dart).

Without valid Firebase options, the app still runs; FCM init is skipped and pushes are disabled until configured.

## Testing checklist

- Rescuer: **Active Duty** on, GPS updating (`profiles.last_location_*` recent).
- Citizen within **10 km** of an on-duty rescuer (fresh location <= 60 min) creates SOS → `sos_dispatch_offers` rows + optional FCM.
- Second rescuer farther than 10 km gets **no** offer.
- Off-duty rescuer gets **no** offer.
- After INSERT, if at least one offer row is created, `sos_dispatches.status` moves **`submitted` → `received`** (citizen stepper shows **Received** before **Dispatch**). **Accept** then sets **`received` → `dispatching`**.
- **Accept** assigns `assigned_rescuer_id`, expires other pendings; late **Accept** returns `already_assigned`.
- **Decline** only updates that rescuer’s offer.
