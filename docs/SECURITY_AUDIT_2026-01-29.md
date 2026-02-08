# Security Audit Report

**Date:** 2026-01-29
**Scope:** chuk_chat (Flutter), api_server (FastAPI), Supabase Configuration
**Type:** Read-only analysis, no changes made

---

## Executive Summary

Overall security posture is **solid** for a privacy-focused chat app. The E2E encryption implementation is well-designed, and key security measures (RLS, webhook verification, rate limiting, constant-time comparisons) are in place. However, there are several findings that should be addressed, ranging from medium to low severity.

**Critical:** 0 | **High:** 3 | **Medium:** 7 | **Low:** 6 | **Info:** 4

---

## 1. chuk_chat (Flutter Client)

### [HIGH] H1: debugPrint Statements Without kDebugMode Guard

- **File:** 894 `debugPrint()` calls across 61 files, but only 117 `kDebugMode` checks across 22 files
- **Description:** ~87% of debugPrint calls are NOT guarded by `kDebugMode`. While `debugPrint` is theoretically stripped in release builds by tree shaking, the Flutter documentation does not guarantee this. Some calls log potentially sensitive metadata (e.g., `supabase_service.dart:76` logs auth error messages, `encryption_service.dart:350` logs encryption sync failures).
- **Risk:** Information leakage in release builds if tree shaking doesn't fully remove them.
- **Fix:** Wrap all `debugPrint()` in `if (kDebugMode)` or use the existing `pLog()` wrapper from `privacy_logger.dart`.

### [MEDIUM] M1: Encryption Key Stored Alongside Salt in Secure Storage

- **File:** `lib/services/encryption_service.dart:266`
- **Description:** The derived key bytes are stored in FlutterSecureStorage (`chat_key_<userId>`). While FlutterSecureStorage uses Keychain (iOS) and EncryptedSharedPreferences (Android), storing the actual derived key means a device compromise exposes all encrypted data without needing the password.
- **Risk:** If device is compromised (rooted/jailbroken), the encryption key can be extracted directly without brute-forcing the password.
- **Fix:** Consider only storing the salt and re-deriving the key from the password on each login. The `tryLoadKey()` method currently loads the key without requiring the password, which trades security for UX.

### [MEDIUM] M2: Encryption Salt Stored in User Metadata (Supabase)

- **File:** `lib/services/encryption_service.dart:228-229`, `_metadataSaltKey = 'chat_kdf_salt'`
- **Description:** The PBKDF2 salt is synced to Supabase user metadata. While a salt is not secret by definition, storing it in user metadata means anyone with the anon key + valid auth token can read it, reducing the attacker's workload to only brute-forcing the password.
- **Risk:** Low additional risk (salts are designed to be non-secret), but combined with M1, it enables offline brute-force attacks if the database is breached.

### [MEDIUM] M3: WebSocket Connection Without Certificate Pinning Verification

- **File:** `lib/services/websocket_chat_service.dart:14-27`
- **Description:** The WebSocket connection converts HTTP(S) to WS(S) but doesn't apply certificate pinning. There is a `certificate_pinning.dart` file, but it's unclear if it's applied to WebSocket connections.
- **Risk:** MitM attacks could intercept WebSocket streaming data.
- **Fix:** Ensure certificate pinning is applied to WebSocket connections as well.

### [LOW] L1: Network Security Config Allows User Certificates in Debug

- **File:** `android/app/src/main/res/xml/network_security_config.xml:19-24`
- **Description:** Debug builds allow user-installed certificates. This is standard practice and only affects debug builds.
- **Risk:** Minimal - debug only.

### [LOW] L2: Broad Android Permissions

- **File:** `android/app/src/main/AndroidManifest.xml`
- **Description:** BLUETOOTH_ADVERTISE permission is declared but may not be needed for a chat app. WAKE_LOCK and FOREGROUND_SERVICE are present (justified for streaming).
- **Fix:** Review if BLUETOOTH_ADVERTISE is actually needed.

### [INFO] I1: Good Practices Observed (chuk_chat)

- AES-256-GCM encryption with random nonces (no IV reuse)
- PBKDF2 with 600,000 iterations (strong KDF)
- Constant-time comparison for key validation (`_constantTimeEquals`)
- Network security config blocks cleartext traffic
- FlutterSecureStorage for key material
- `.env` files properly gitignored
- `web_env.dart` has empty values in git (safe)

---

## 2. api_server (FastAPI)

### [HIGH] H2: Supabase Service Role Key Used as Default Client

- **File:** `api_server/main.py:104` - `SUPABASE_KEY = os.getenv("SUPABASE_SERVICE_KEY")`
- **Description:** The API server uses the **service role key** for its Supabase client. This bypasses all Row Level Security (RLS) policies. All database operations from the server (usage logging, profile updates, subscription management) run with full admin privileges.
- **Risk:** Any SQL injection or logic bug in the server code could access/modify ANY user's data. RLS provides no defense-in-depth for server-side operations.
- **Fix:** Use the user's JWT token to create per-request Supabase clients for user-scoped operations. Reserve the service role key for admin-only operations (webhooks, subscription sync).

### [HIGH] H3: CORS Allows Credentials with Wildcard Methods/Headers

- **File:** `api_server/main.py:430-442`
- **Description:** CORS is configured with `allow_credentials=True` combined with `allow_methods=["*"]` and `allow_headers=["*"]`. While origins are restricted, the wildcard methods/headers is overly permissive.
- **Risk:** Allows any HTTP method and any header from allowed origins, which could be exploited if an XSS vulnerability exists on the allowed domains.
- **Fix:** Restrict `allow_methods` to `["GET", "POST", "DELETE", "OPTIONS"]` and `allow_headers` to specific required headers.

### [MEDIUM] M4: In-Memory Rate Limiting (Not Distributed)

- **File:** `api_server/main.py:186-191`, `261-267`
- **Description:** Rate limiting uses in-memory storage (`defaultdict` and slowapi without Redis). With multiple container replicas, each instance has independent counters, so effective limits are `N * limit`.
- **Risk:** Rate limits can be trivially bypassed by hitting different replicas.
- **Fix:** Use Redis-backed storage for rate limiting (the code already has comments acknowledging this).

### [MEDIUM] M5: JWT Decoded Without Signature Verification for Rate Limiting

- **File:** `api_server/main.py:250` - `jwt.decode(token, options={"verify_signature": False})`
- **Description:** The rate limiter extracts user IDs from JWTs without verifying the signature. An attacker could craft a JWT with a fake `sub` claim to bypass per-user rate limits or frame another user's rate limit bucket.
- **Risk:** Rate limit bypass or rate limit poisoning for other users.
- **Fix:** Use verified token claims for rate limiting, or accept this as a known trade-off (since actual auth happens in `verify_token`).

### [MEDIUM] M6: Webhook Idempotency Race Condition Window

- **File:** `api_server/main.py:2516-2531`
- **Description:** Webhook idempotency relies on a database INSERT with unique constraint. If the INSERT fails with a non-unique error, processing continues (`chat_logger.warning` only). This means non-unique-constraint errors could lead to webhook double-processing.
- **Risk:** Potential double credit allocation in edge cases.
- **Fix:** On non-unique errors, still skip processing rather than continuing.

### [LOW] L3: File Upload Filename Used Directly

- **File:** `api_server/main.py:778` - `suffix=os.path.splitext(audio_file.filename or ".m4a")[1]`
- **Description:** The uploaded filename's extension is used directly for temp file creation. While this is a temp file, path traversal in the extension (e.g., `../../../evil.sh`) could be an issue depending on OS.
- **Risk:** Low - `tempfile.NamedTemporaryFile` handles this safely, but the pattern should use a whitelist.
- **Fix:** Validate file extension against an allowlist.

### [LOW] L4: No Request Size Limit at Framework Level

- **File:** `api_server/main.py`
- **Description:** While individual endpoints check sizes (MAX_IMAGE_SIZE, MAX_AUDIO_SIZE), there's no global request size limit configured in uvicorn or FastAPI. The body is fully read into memory (`await request.body()`) in the logging middleware.
- **Risk:** Memory exhaustion via large POST requests to endpoints without size checks.
- **Fix:** Configure `--limit-max-header-size` in uvicorn and add a max body size middleware.

### [LOW] L5: Health Endpoint Exposes Connection Count

- **File:** `api_server/main.py:486` - `"active_connections": len(active_websocket_connections)`
- **Description:** The unauthenticated health endpoint reveals the number of active WebSocket connections.
- **Risk:** Information disclosure that could help an attacker gauge server load.
- **Fix:** Remove from public health endpoint or add an internal-only admin health endpoint.

### [INFO] I2: Good Practices Observed (api_server)

- Stripe webhook signature verification is mandatory
- Webhook idempotency with database-level uniqueness
- PII redaction in logs
- Correlation IDs for error tracking
- 5xx errors hide internal details from users
- Rate limiting present (even if in-memory)
- Proper Bearer token authentication via Supabase

---

## 3. Supabase Configuration

### [MEDIUM] M7: get_credits_remaining (api_server version) Has No auth.uid() Check

- **File:** `api_server/supabase/migrations/20260124_get_credits_remaining.sql`
- **Description:** The `get_credits_remaining` function in the api_server migrations does NOT include the `IF p_user_id != auth.uid() THEN RETURN 0` check that exists in the chuk_chat version (`20260120210546_fix_free_messages_security.sql`). If both were applied, the later one would override, but if the api_server version was applied last, any authenticated user could query any other user's credit balance.
- **Risk:** User enumeration / credit balance disclosure.
- **Fix:** Ensure the version with `auth.uid()` check is the one deployed. Consolidate migration files.

### [LOW] L6: Minimum Password Length Set to 6

- **File:** `supabase/config.toml:142` - `minimum_password_length = 6`
- **Description:** Supabase auth is configured with a minimum password of only 6 characters and no `password_requirements` set (empty string).
- **Risk:** Weak passwords allowed at the Supabase level (the Flutter client may enforce stronger requirements at the UI level, but the API doesn't).
- **Fix:** Set `minimum_password_length = 8` and `password_requirements = "lower_upper_letters_digits"`.

### [INFO] I3: CAPTCHA Disabled

- **File:** `supabase/config.toml:164-167`
- **Description:** CAPTCHA (`hcaptcha` or `turnstile`) is commented out. While sign-up rate limits exist (30 per 5 minutes), automated account creation is possible.
- **Fix:** Enable Cloudflare Turnstile for signup flow.

### [INFO] I4: MFA Disabled

- **File:** `supabase/config.toml:241-254`
- **Description:** All MFA methods (TOTP, Phone, WebAuthn) are disabled. For a privacy-focused chat app, MFA is strongly recommended.
- **Fix:** Enable at least TOTP-based MFA.

### Good Practices Observed (Supabase)

- RLS enabled on `user_sessions` with proper per-user policies
- `project_chats` INSERT policy requires ownership of both project AND chat
- `get_free_messages_remaining` has auth.uid() check
- Edge function verifies JWT before operations
- Refresh token rotation enabled
- Anonymous sign-ins disabled
- Email double-confirm for changes enabled

---

## 4. Cross-System Findings

### Edge Function CORS Wildcard

- **File:** `supabase/functions/revoke-session/index.ts:14` - `"Access-Control-Allow-Origin": "*"`
- **Description:** The revoke-session edge function allows requests from any origin. While it requires a valid JWT, a wildcard CORS policy combined with credential headers could be exploited.
- **Fix:** Restrict to `https://chat.chuk.chat` and localhost origins.

### Service Role Key Exposure Vector

- The api_server uses the service role key (`SUPABASE_SERVICE_KEY`) which bypasses ALL RLS.
- The edge function uses `SUPABASE_SERVICE_ROLE_KEY` for admin operations.
- If the api_server is compromised, an attacker has full database access.
- **Mitigation:** Keep the api_server in a private network, not directly exposed to the internet.

---

## Priority Recommendations

| Priority | Finding | Action |
|----------|---------|--------|
| 1 | H2: Service role key as default | Use per-user clients for user operations |
| 2 | H3: CORS wildcards | Restrict methods/headers |
| 3 | H1: Unguarded debugPrint | Wrap in kDebugMode |
| 4 | M7: Conflicting migrations | Consolidate and verify deployed version |
| 5 | M4: In-memory rate limiting | Add Redis backend |
| 6 | M5: Unverified JWT in rate limiter | Accept or fix |
| 7 | M1: Stored encryption key | Consider re-derive on login |
| 8 | L6: Weak password minimum | Increase to 8+ |
| 9 | I4: No MFA | Enable TOTP |
| 10 | I3: No CAPTCHA | Enable Turnstile |
