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
// The push carries NO answer content: title/body come from the row, which the
// host wrote with generic text only. The app opens the thread and replays the
// answer over the sealed channel.
//
// Secrets (set with `supabase secrets set`):
//   FCM_PROJECT_ID       the Firebase project id
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

/** Build the FCM v1 message for one device token. Generic text only. */
export function buildFcmMessage(token: string, row: Record<string, unknown>): Record<string, unknown> {
  return {
    message: {
      token,
      notification: { title: String(row.title ?? ""), body: String(row.body ?? "") },
      data: {
        run_id: String(row.run_id ?? ""),
        session_key: String(row.session_key ?? ""),
        agent_id: String(row.agent_id ?? ""),
        agent_name: String(row.agent_name ?? ""),
        notification_id: String(row.id ?? ""),
        kind: String(row.kind ?? ""),
      },
      android: {
        priority: "HIGH",
        notification: {
          channel_id: "cowork_completion",
          // One outstanding notification per thread: a newer one replaces it.
          tag: String(row.session_key ?? ""),
          click_action: "FLUTTER_NOTIFICATION_CLICK",
        },
      },
    },
  };
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
  const targets = (devices ?? []).filter((d) => d.platform === "android" || d.platform === "ios");
  if (targets.length === 0 || !FCM_PROJECT_ID || !FCM_SERVICE_ACCOUNT) {
    await supabase.from("cowork_run_notifications").update({ pushed_at: new Date().toISOString() }).eq("id", id);
    return json(200, { sent: 0, failed: 0, already_pushed: false });
  }

  let sent = 0, failed = 0;
  const google = await fcmAccessToken();
  for (const d of targets) {
    const resp = await fetch(
      `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${google}`, "Content-Type": "application/json" },
        body: JSON.stringify(buildFcmMessage(d.token, row)),
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
