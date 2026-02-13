// supabase/functions/revoke-session/index.ts
// Edge function to revoke user sessions via Supabase Admin API.
//
// Endpoints:
//   POST /functions/v1/revoke-session
//   Body: { "session_id": "uuid" }           → revoke single session
//   Body: { "revoke_all_others": true }       → revoke all other sessions
//
// Requires SUPABASE_SERVICE_ROLE_KEY in environment.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = new Set([
  "https://chat.chuk.chat",
  "http://localhost:8080",
  "http://localhost:8081",
  "http://127.0.0.1:8080",
  "http://127.0.0.1:8081",
]);

function getCorsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.has(origin) ? origin : "",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Vary": "Origin",
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: getCorsHeaders(req) });
  }

  try {
    // Verify JWT
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing authorization header" }), {
        status: 401,
        headers: { ...getCorsHeaders(req), "Content-Type": "application/json" },
      });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    // User client to verify the caller
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: { user }, error: userError } = await userClient.auth.getUser();
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Invalid token" }), {
        status: 401,
        headers: { ...getCorsHeaders(req), "Content-Type": "application/json" },
      });
    }

    const body = await req.json();
    const { session_id, revoke_all_others, current_token_hash } = body;

    // Admin client for privileged operations
    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    if (revoke_all_others) {
      // Sign out all other sessions via Admin API
      // This invalidates all refresh tokens for the user
      const { error: signOutError } = await adminClient.auth.admin.signOut(
        user.id,
        "others"
      );

      if (signOutError) {
        console.error("Failed to sign out other sessions:", signOutError);
        // Still mark sessions as inactive in our tracking table
      }

      // Mark all other sessions as inactive in our tracking table
      const { error: updateError } = await adminClient
        .from("user_sessions")
        .update({ is_active: false })
        .eq("user_id", user.id)
        .eq("is_active", true)
        .neq("refresh_token_hash", current_token_hash || "");

      if (updateError) {
        console.error("Failed to update session records:", updateError);
      }

      return new Response(JSON.stringify({ success: true, action: "revoked_all_others" }), {
        status: 200,
        headers: { ...getCorsHeaders(req), "Content-Type": "application/json" },
      });
    }

    if (session_id) {
      // Verify the session belongs to the caller
      const { data: sessionRecord, error: fetchError } = await adminClient
        .from("user_sessions")
        .select("id, user_id, refresh_token_hash")
        .eq("id", session_id)
        .eq("user_id", user.id)
        .single();

      if (fetchError || !sessionRecord) {
        return new Response(JSON.stringify({ error: "Session not found" }), {
          status: 404,
          headers: { ...getCorsHeaders(req), "Content-Type": "application/json" },
        });
      }

      // Mark session as inactive
      const { error: updateError } = await adminClient
        .from("user_sessions")
        .update({ is_active: false })
        .eq("id", session_id);

      if (updateError) {
        return new Response(JSON.stringify({ error: "Failed to revoke session" }), {
          status: 500,
          headers: { ...getCorsHeaders(req), "Content-Type": "application/json" },
        });
      }

      // Sign out all other sessions to ensure the refresh token is invalidated.
      // Supabase GoTrue doesn't expose per-token revocation, so we use the
      // "others" scope which invalidates all sessions except the one making the
      // admin call. Since this runs via the admin client, it effectively
      // invalidates all user sessions. The caller's own session will be
      // refreshed automatically by the client SDK.
      const { error: signOutError } = await adminClient.auth.admin.signOut(
        user.id,
        "others"
      );

      if (signOutError) {
        console.error("Admin signOut failed (non-critical):", signOutError);
      }

      return new Response(JSON.stringify({ success: true, action: "revoked_single", session_id }), {
        status: 200,
        headers: { ...getCorsHeaders(req), "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ error: "Provide session_id or revoke_all_others" }), {
      status: 400,
      headers: { ...getCorsHeaders(req), "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("revoke-session error:", err);
    return new Response(JSON.stringify({ error: "Internal server error" }), {
      status: 500,
      headers: { ...getCorsHeaders(req), "Content-Type": "application/json" },
    });
  }
});
