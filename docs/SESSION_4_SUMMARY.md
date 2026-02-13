# Session 4 — Summary (2026-02-13)

## Overview

This session completed **all remaining API server bugs** (8) and **3 of 5 Supabase/Infra bugs**, bringing the audit from 16 open findings down to **4 remaining**. All changes are committed and pushed.

---

## 1. Service Role Key — Bug H1 (HOCH)

**Problem:** The API server used the admin Supabase client (`SUPABASE_SERVICE_KEY`) for all database operations, bypassing Row Level Security (RLS) policies. A previous session had already added `user_client` parameters to PaymentService methods and updated most callers, but two callers in `main.py` were still missing.

**Fix:** Passed `user_client=user.client` to the two remaining callers:
- `create_portal_session` call (~line 2714) — Stripe customer portal
- `get_credits_remaining` call (~line 3075) — user status endpoint

**Intentionally kept on admin client:**
- `log_usage()` — Server-only write; users shouldn't control their own usage records
- `sync_single_subscription()` / `sync_all_subscriptions_from_stripe()` — Webhook/startup context, no user JWT available
- `delete_user_account()` — Admin-level operation

**Files:** `api_server/main.py`

---

## 2. Webhook Idempotency Race — Bug M6 (MITTEL)

**Problem:** TOCTOU race condition in the Stripe webhook handler. When two instances received the same webhook event simultaneously:
1. Instance A: INSERT succeeds → starts processing
2. Instance B: INSERT fails (duplicate key) → SELECT status → sees "processing" → **also starts processing**

This could cause double credit allocation.

**Fix:** Replaced the INSERT → SELECT → process pattern with an atomic approach:
1. INSERT — if succeeds, we claimed it
2. If INSERT fails with duplicate key: `UPDATE webhook_events SET status = 'processing' WHERE event_id = ? AND status = 'failed'`
   - This UPDATE is atomic — only ONE instance can flip "failed" → "processing"
   - If status is "processing" (another instance working) or "completed" (already done) → 0 rows updated → skip
3. Added "failed" marking in the exception handler — previously, failed webhooks stayed as "processing" forever and could never be retried

**Files:** `api_server/main.py` (lines ~2796-2850, ~2891-2902)

---

## 3. JWT parse_jwt_scopes Safety — Bug M5 (MITTEL)

**Problem:** `parse_jwt_scopes()` decodes the JWT without signature verification (`verify_signature: False`). The audit flagged this as a risk.

**Assessment:** Already mitigated — the function is only called AFTER `supabase.auth.get_user()` has validated the token server-side. Both call sites (the `verify_token` dependency and the WebSocket auth loop) enforce this.

**Fix:** Added a detailed safety invariant docstring explaining when and why it's safe:
```python
"""Parse JWT token to extract scopes without verification.

SAFETY INVARIANT: This function decodes the JWT without verifying the
signature. It MUST only be called AFTER supabase.auth.get_user() has
already validated the token server-side. The two call sites (verify_token
dependency and the WebSocket auth loop) both enforce this — do NOT call
this function on unverified tokens.
"""
```

**Files:** `api_server/main.py` (line ~313)

---

## 4. File Upload Filename Sanitization — Bug L3 (NIEDRIG)

**Problem:** `file.filename` from multipart uploads was returned directly in the `/v1/ai/convert-file` JSON response and used in log messages. A malicious filename like `../../etc/passwd` or `<script>alert(1)</script>` could cause path traversal or XSS in downstream consumers.

**Fix:** Added `sanitize_filename()` function in `convert_files.py`:
- Strips path components via `Path(name).name` (prevents `../../` traversal)
- Removes control characters (U+0000-U+001F, U+007F-U+009F)
- Replaces HTML-significant characters (`<>&"'\r\n`) with `_`
- Truncates to 255 characters
- Returns "unnamed" for empty/None inputs

Applied to the endpoint response (`"filename": safe_name`) and error log message.

**Files:** `api_server/convert_files.py`, `api_server/main.py`

---

## 5. Streaming Body Size Enforcement — Bug L4 (NIEDRIG)

**Problem:** The existing `limit_request_body_size` middleware only checked the `Content-Length` header. Requests using `Transfer-Encoding: chunked` have no Content-Length, so they could send arbitrarily large bodies and fill server memory.

**Fix:** Extended the middleware to wrap the ASGI `receive` channel:
```python
async def size_limited_receive():
    nonlocal received
    message = await original_receive()
    if message.get("type") == "http.request":
        body = message.get("body", b"")
        received += len(body)
        if received > MAX_REQUEST_BODY_SIZE:
            raise HTTPException(status_code=413, detail="Request body too large")
    return message
request._receive = size_limited_receive
```
This counts bytes as they stream in and rejects at 100 MB, regardless of whether Content-Length is present.

**Files:** `api_server/main.py` (lines ~630-660)

---

## 6. CORS Already Fixed — Bug H3 (HOCH)

**No code change needed.** Already fixed in commit `259d923` (2026-02-11): explicit `allow_methods` (GET/POST/DELETE/OPTIONS), explicit `allow_headers`, explicit `allow_origins`. Marked as done in checklist.

---

## 7. Rate Limiting Already Fixed — Bug M4 (MITTEL)

**No code change needed.** Already fixed in commits `259d923`/`a277a89`: distributed rate limiting via Supabase RPC `check_rate_limit()`. `slowapi` kept as IP-based fallback. Marked as done in checklist.

---

## 8. Health Endpoint Already Fixed — Bug L5 (NIEDRIG)

**No code change needed.** Already fixed in commit `259d923`: returns only `{"status": "ok"}`. Marked as done in checklist.

---

## 9. Conflicting Migrations — Bug M7 (MITTEL)

**Problem:** Two versions of `get_credits_remaining` existed:
- `chuk_chat` (Jan 20): Has `auth.uid()` check, reads stale `credits_remaining` column from `profiles`
- `api_server` (Jan 24): Better calculation (`total_credits_allocated - SUM(usage_logs)`), 16 EUR cap, but **no `auth.uid()` check** — any authenticated user could query another user's credits

**Fix:** Updated the api_server version (canonical) to add the auth check conditionally:
```sql
IF auth.uid() IS NOT NULL AND p_user_id != auth.uid() THEN
    RETURN 0;
END IF;
```
- **Authenticated users** (user client): Can only query their own credits
- **Service role** (`auth.uid()` is NULL): Allowed for any user — needed by webhooks and subscription sync

Also added `SECURITY DEFINER` and marked the chuk_chat version as a stub pointing to the canonical api_server version.

**Files:** `api_server/supabase/migrations/20260124_get_credits_remaining.sql`, `chuk_chat/supabase/migrations/20260120210546_fix_free_messages_security.sql`

---

## 10. Password Minimum Raised to 8 — Bug L6 (NIEDRIG)

**Problem:** Supabase accepted passwords as short as 6 characters with no complexity requirements. The client enforced 6 + uppercase + lowercase + digit + symbol, but the server had no complexity enforcement.

**Fix (3 files):**
- `supabase/config.toml`: `minimum_password_length = 8`, `password_requirements = "lower_upper_letters_digits"`
- `lib/utils/input_validator.dart`: `minPasswordLength` changed from 6 to 8
- `test/utils/input_validator_test.dart`: Updated tests — `'Ab1!cd'` (6 chars) changed to `'Ab1!cdef'` (8 chars), added new test for 7-char rejection

**Note:** Production Supabase needs to be updated separately via Dashboard.

---

## 11. Edge Function CORS Wildcard (NIEDRIG)

**Problem:** `supabase/functions/revoke-session/index.ts` had `Access-Control-Allow-Origin: *`, allowing any website to call the session revocation endpoint.

**Fix:** Replaced the static wildcard with a dynamic origin check:
```typescript
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
```
Requests from unlisted origins get an empty CORS header (browser blocks the response).

**Files:** `supabase/functions/revoke-session/index.ts`

---

## 12. CAPTCHA Marked Not Applicable

Moved to "Kein echtes Problem" — Flutter native apps (Android/Linux) cannot render web-based CAPTCHA widgets (hCaptcha/Turnstile). Rate limits (30 signups/5min per IP) remain as mitigation.

---

## 13. Hardcoded Fallback Model Removed (Bonus)

Uncommitted changes from a previous session were included: removed the hardcoded `deepseek/deepseek-chat-v3.1` fallback from `chat_ui_mobile.dart` and `user_preferences_service.dart`. Instead, when no cached model exists, the app now fetches the default from Supabase (which is set by a database trigger).

**Files:** `lib/platform_specific/chat/chat_ui_mobile.dart`, `lib/services/user_preferences_service.dart`

---

## Final Statistics

| Kategorie | Anzahl |
|-----------|--------|
| Behoben | 45 |
| Kein echtes Problem | 6 |
| Offen — Flutter Client | 3 (God Classes, Root Detection, Encryption Key — all deliberate) |
| Offen — API Server | 0 |
| Offen — Supabase/Infra | 1 (MFA — requires client-side implementation first) |
| **Gesamt offen** | **4** |

## Commits

**chuk_chat** (3 commits):
1. `1188c13` — Remove hardcoded fallback model, update audit checklist (8 API server bugs done)
2. `756e410` — Fix 3 Supabase/infra findings + raise password minimum to 8
3. `cc1fe3e` — Move CAPTCHA to not-applicable

**api_server** (2 commits):
1. `73abe64` — Fix 8 API server audit findings (H1, H3, M4, M5, M6, L3, L4, L5)
2. `72de2fc` — Add auth.uid() check to get_credits_remaining (M7)

## Tests

457 Flutter tests passing (up from 456 — added 7-char password rejection test). `flutter analyze`: 4 pre-existing info-level lints only. All API server files pass `py_compile` syntax check.
