// notify-run — push "your answer is ready" to the user's devices.
//
// Contract (docs/WIRE_CONTRACT.md, docs/SUPABASE_SCHEMA.md):
//   POST /functions/v1/notify-run
//   Authorization: Bearer <the caller's user access token>   (host or app)
//   apikey: <anon key>
//   { "notification_id": "<uuid>" }
//   -> 200 { sent, failed, already_pushed }  | 401 | 404
//
// The caller's JWT is the authorization: this function builds a Supabase client
// with that token, so RLS scopes every read and write to the caller's own rows.
// No service-role key is used anywhere here.
//
// The push carries NO readable answer content (docs/agents/NOTIFICATIONS.md):
// title/body come from the row, which the host wrote with generic text only.
// The answer preview is in `preview_sealed` ({channel_id: sealed}), sealed per
// pairing with a key only the host and the paired app hold. This function
// passes it on and cannot read it.
//
// Per platform:
//   android      FCM data-only message, priority HIGH. The app's background
//                handler opens the seal and shows the local notification.
//   ios          FCM `notification` block (generic text), apns
//                mutable-content 1, and the same data (for a later NSE).
//   unifiedpush  HTTP POST of the same data object as JSON to the token
//                (the distributor endpoint URL). For phones without Google
//                Play. A 404 or 410 removes the token.
//
// Secrets (set with `supabase secrets set`):
//   FCM_PROJECT_ID       the Firebase project id (no FCM: only UnifiedPush)
//   FCM_SERVICE_ACCOUNT  the JSON of a service account with firebase.messaging

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const FCM_PROJECT_ID = Deno.env.get("FCM_PROJECT_ID") ?? "";
const FCM_SERVICE_ACCOUNT = Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "";

// A Google OAuth2 access token for FCM, cached for its lifetime.
let cachedToken: { value: string; expiresAt: number } | null = null;

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

/** Mint a Google access token from the service account (RS256 JWT grant). */
async function fcmAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expiresAt - 60 > now) return cachedToken.value;
  const sa = JSON.parse(FCM_SERVICE_ACCOUNT);
  const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const claims = base64url(new TextEncoder().encode(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  })));
  const key = await crypto.subtle.importKey(
    "pkcs8", pemToDer(sa.private_key), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`),
  );
  const assertion = `${header}.${claims}.${base64url(new Uint8Array(sig))}`;
  const resp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!resp.ok) throw new Error(`google token: ${resp.status}`);
  const data = await resp.json();
  cachedToken = { value: data.access_token, expiresAt: now + Number(data.expires_in ?? 3600) };
  return cachedToken.value;
}

/** FCM allows 4 KB of data. Above this size `preview_sealed` is dropped. */
export const MAX_DATA_BYTES = 3584;

/** How long a UnifiedPush distributor keeps an undelivered message (s). */
export const UNIFIEDPUSH_TTL_SECONDS = 86400;

/** The data object of every platform: string values only (FCM rule). */
export function buildPushData(row: Record<string, unknown>): Record<string, string> {
  const data: Record<string, string> = {
    run_id: String(row.run_id ?? ""),
    session_key: String(row.session_key ?? ""),
    agent_id: String(row.agent_id ?? ""),
    agent_name: String(row.agent_name ?? ""),
    notification_id: String(row.id ?? ""),
    kind: String(row.kind ?? ""),
    // The generic fallback for a device that cannot open the seal.
    title: String(row.title ?? ""),
    body: String(row.body ?? ""),
  };
  const sealed = row.preview_sealed;
  if (sealed && typeof sealed === "object" && Object.keys(sealed).length > 0) {
    const withSeal = { ...data, preview_sealed: JSON.stringify(sealed) };
    if (new TextEncoder().encode(JSON.stringify(withSeal)).length <= MAX_DATA_BYTES) {
      return withSeal;
    }
  }
  return data;
}

/** Build the FCM v1 message for one device token. Readable text is generic;
 * the preview is only in the sealed data field. */
export function buildFcmMessage(
  token: string,
  row: Record<string, unknown>,
  platform = "android",
): Record<string, unknown> {
  const data = buildPushData(row);
  if (platform === "ios") {
    return {
      message: {
        token,
        notification: { title: data.title, body: data.body },
        data,
        apns: {
          headers: { "apns-priority": "10" },
          // A Notification Service Extension may replace the text.
          payload: { aps: { "mutable-content": 1 } },
        },
      },
    };
  }
  // Android: data only. The app shows the notification itself, with the
  // opened preview and the agent's avatar.
  return {
    message: {
      token,
      data,
      android: { priority: "HIGH" },
    },
  };
}

/** POST one push to a UnifiedPush endpoint. Returns the HTTP status. */
async function sendUnifiedPush(endpoint: string, row: Record<string, unknown>): Promise<number> {
  let url: URL;
  try {
    url = new URL(endpoint);
  } catch {
    return 410;
  }
  // Only https: the token is a URL the user stored; never a plain or a local
  // scheme.
  if (url.protocol !== "https:") return 410;
  const resp = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      TTL: String(UNIFIEDPUSH_TTL_SECONDS),
      Urgency: "high",
    },
    body: JSON.stringify(buildPushData(row)),
  });
  await resp.body?.cancel();
  return resp.status;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "method" });
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json(401, { error: "no token" });

  // The caller's identity is the authorization. RLS does the rest.
  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });

  let body: { notification_id?: string };
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "bad json" });
  }
  const id = body.notification_id;
  if (!id) return json(400, { error: "notification_id required" });

  const { data: row, error } = await supabase
    .from("cowork_run_notifications").select("*").eq("id", id).maybeSingle();
  if (error) return json(401, { error: error.message });
  if (!row) return json(404, { error: "no such notification" });
  if (row.pushed_at) return json(200, { sent: 0, failed: 0, already_pushed: true });

  const { data: devices } = await supabase
    .from("cowork_device_tokens").select("token, platform, device_id");
  const fcmReady = FCM_PROJECT_ID !== "" && FCM_SERVICE_ACCOUNT !== "";
  const fcmTargets = fcmReady
    ? (devices ?? []).filter((d) => d.platform === "android" || d.platform === "ios")
    : [];
  const upTargets = (devices ?? []).filter((d) => d.platform === "unifiedpush");
  if (fcmTargets.length === 0 && upTargets.length === 0) {
    await supabase.from("cowork_run_notifications").update({ pushed_at: new Date().toISOString() }).eq("id", id);
    return json(200, { sent: 0, failed: 0, already_pushed: false });
  }

  let sent = 0, failed = 0;
  for (const d of upTargets) {
    let status = 0;
    try {
      status = await sendUnifiedPush(String(d.token ?? ""), row);
    } catch {
      status = 0;
    }
    if (status >= 200 && status < 300) {
      sent++;
      continue;
    }
    failed++;
    // The distributor says the endpoint is gone (app removed, unregistered).
    if (status === 404 || status === 410) {
      await supabase.from("cowork_device_tokens").delete().eq("device_id", d.device_id);
    }
  }

  const google = fcmTargets.length > 0 ? await fcmAccessToken() : "";
  for (const d of fcmTargets) {
    const resp = await fetch(
      `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${google}`, "Content-Type": "application/json" },
        body: JSON.stringify(buildFcmMessage(d.token, row, d.platform)),
      },
    );
    if (resp.ok) {
      sent++;
      continue;
    }
    failed++;
    const text = await resp.text();
    // A token that no longer exists (reinstall) is removed, so the table heals.
    if (text.includes("UNREGISTERED") || text.includes("INVALID_ARGUMENT")) {
      await supabase.from("cowork_device_tokens").delete().eq("device_id", d.device_id);
    }
  }
  await supabase.from("cowork_run_notifications").update({ pushed_at: new Date().toISOString() }).eq("id", id);
  return json(200, { sent, failed, already_pushed: false });
});
