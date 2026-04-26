// Supabase Edge Function: FCM data messages to rescuers with pending offers after SOS insert.
// Webhook: Database Webhook on public.sos_dispatches INSERT → POST this function.
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, FCM_SERVICE_ACCOUNT_JSON, SOS_WEBHOOK_SECRET (optional).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import { GoogleAuth } from "npm:google-auth-library@9.14.2";

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-webhook-secret",
};

interface WebhookPayload {
  type?: string;
  table?: string;
  record?: Record<string, unknown>;
}

async function sendFcmDataMessage(
  projectId: string,
  accessToken: string,
  fcmToken: string,
  data: Record<string, string>,
): Promise<Response> {
  const url =
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;
  return await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      message: {
        token: fcmToken,
        data,
        android: { priority: "HIGH" },
        apns: {
          payload: {
            aps: { sound: "default", contentAvailable: true },
          },
        },
      },
    }),
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const secret = Deno.env.get("SOS_WEBHOOK_SECRET");
  if (secret) {
    const h = req.headers.get("x-webhook-secret");
    if (h !== secret) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return new Response(
      JSON.stringify({ error: "missing supabase env" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  let payload: WebhookPayload;
  try {
    payload = (await req.json()) as WebhookPayload;
  } catch {
    return new Response(JSON.stringify({ error: "invalid json" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (payload.table !== "sos_dispatches" || payload.type !== "INSERT") {
    return new Response(JSON.stringify({ skipped: true, reason: "not_sos_insert" }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const record = payload.record;
  const dispatchId = record?.id as string | undefined;
  if (!dispatchId) {
    return new Response(JSON.stringify({ error: "no record id" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const ticket = String(record.ticket_number ?? "");
  const lat = String(record.latitude ?? "");
  const lng = String(record.longitude ?? "");

  const supabase = createClient(supabaseUrl, serviceKey);

  const { data: offers, error: qErr } = await supabase
    .from("sos_dispatch_offers")
    .select("id, rescuer_id")
    .eq("dispatch_id", dispatchId)
    .eq("status", "pending");

  if (qErr) {
    console.error("offers query", qErr);
    return new Response(JSON.stringify({ error: qErr.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const fcmJson = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!fcmJson) {
    console.warn("FCM_SERVICE_ACCOUNT_JSON not set; skipping push");
    return new Response(
      JSON.stringify({
        ok: true,
        dispatch_id: dispatchId,
        offers: offers?.length ?? 0,
        fcm: "skipped_no_credentials",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  let serviceAccount: Record<string, unknown>;
  try {
    serviceAccount = JSON.parse(fcmJson);
  } catch {
    return new Response(JSON.stringify({ error: "invalid FCM JSON" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const projectId = serviceAccount.project_id as string;
  if (!projectId) {
    return new Response(JSON.stringify({ error: "no project_id in FCM JSON" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const auth = new GoogleAuth({
    credentials: serviceAccount,
    scopes: ["https://www.googleapis.com/auth/firebase.messaging"],
  });
  const client = await auth.getClient();
  const tokenResponse = await client.getAccessToken();
  const accessToken = tokenResponse?.token;
  if (!accessToken) {
    return new Response(JSON.stringify({ error: "no google access token" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const dataPayload: Record<string, string> = {
    type: "sos_dispatch",
    dispatch_id: dispatchId,
    ticket_number: ticket,
    latitude: lat,
    longitude: lng,
  };

  let sent = 0;
  const list = offers ?? [];

  for (const o of list) {
    const rid = o.rescuer_id as string;
    const { data: tokRows } = await supabase
      .from("device_tokens")
      .select("fcm_token")
      .eq("user_id", rid);

    for (const row of tokRows ?? []) {
      const token = row.fcm_token as string;
      if (!token) continue;
      try {
        const r = await sendFcmDataMessage(
          projectId,
          accessToken,
          token,
          dataPayload,
        );
        if (r.ok) sent++;
        else console.warn("fcm status", r.status, await r.text());
      } catch (e) {
        console.error("fcm send", e);
      }
    }
  }

  return new Response(
    JSON.stringify({
      ok: true,
      dispatch_id: dispatchId,
      offers: list.length,
      fcm_sent: sent,
    }),
    { headers: { ...corsHeaders, "Content-Type": "application/json" } },
  );
});
