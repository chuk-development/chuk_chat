# Security Policy

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Please report security issues directly to: support@chuk.dev

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

## Response Time

We aim to respond within 48 hours and provide a fix within 7 days for critical issues.

## Scope

This policy covers:
- Chuk Chat mobile app (iOS/Android)
- Chuk Chat desktop app
- Backend API
- End-to-end encryption implementation

## Bug Bounty

Currently no formal bug bounty program, but we credit researchers in our changelog (with permission).

---

# Security Implementation

## Overview

**chuk_chat** implements multiple layers of security to protect user data and prevent common attack vectors. This document outlines the security measures in place and provides guidance for maintaining them.

## Security Features

### 1. End-to-End Encryption

All chat messages are encrypted client-side before being stored or transmitted:

- **Algorithm**: AES-256-GCM (Galois/Counter Mode)
- **Key Derivation**: PBKDF2 with 600,000 iterations
- **Storage**: Encryption keys are stored securely using `flutter_secure_storage`
- **Scope**: Chat messages, chat metadata, and sensitive user data

Chat data is never stored or transmitted in plaintext. Even the server cannot decrypt your messages.

**What Data is NOT Encrypted:**

While your chat messages are fully encrypted, the following data is stored in plaintext for operational purposes:
- Your email address (for authentication)
- Theme preferences (colors, dark/light mode settings)
- Model selection preferences
- API usage statistics (anonymous, for rate limiting and abuse prevention)

This data does not contain any chat content or sensitive personal information.

### 2. Certificate Pinning

The app uses SSL certificate pinning to prevent man-in-the-middle (MITM) attacks:

- **Enabled**: Production builds only (disabled in debug mode for development)
- **Domain**: api.chuk.dev (including subdomains)
- **Algorithm**: SHA-256 public key pinning
- **Enforcement**: Connections to pinned domains are rejected if certificate doesn't match

Certificate pinning configuration is located in `lib/utils/certificate_pinning.dart`.

### 3. Input Validation

All user inputs are validated and sanitized to prevent injection attacks and denial-of-service:

- **Message Length**: Maximum 20 million characters (20M)
- **Email Validation**: RFC 5322 compliant email validation
- **File Names**: Sanitized to prevent directory traversal and command injection
- **SQL Injection**: Prevented through Supabase's parameterized queries

### 4. Password Security

Strong password requirements enforce account security:

- **Minimum Length**: 12 characters
- **Complexity Requirements**:
  - At least one uppercase letter
  - At least one lowercase letter
  - At least one number
  - At least one special character
- **Visual Feedback**: Real-time password strength meter during sign-up
- **Storage**: Passwords are hashed and salted by Supabase (never stored in plaintext)

### 5. File Upload Security

File uploads are validated to prevent malicious files and resource exhaustion:

- **Size Limit**: 10MB maximum per file
- **MIME Type Validation**: Files are validated against allowed MIME types
- **Magic Byte Verification**: File content is inspected to prevent MIME type spoofing
- **Zip Bomb Protection**: Archive files are scanned for excessive compression ratios
- **Rate Limiting**: Maximum 10 file uploads per 5-minute window per user

### 6. API Rate Limiting

Client-side rate limiting prevents API abuse and accidental DoS:

- **Per-Endpoint Limits**: Different limits for different API endpoints
  - Chat: 30 requests per minute
  - File Conversion: 10 requests per minute
  - Model Fetching: 20 requests per minute
- **Per-User Tracking**: Each user has independent rate limit tracking
- **Exponential Backoff**: Failed requests are retried with increasing delays
- **Request Queuing**: Maximum 3 concurrent API requests to prevent resource exhaustion

### 7. Session Token Security

Access tokens and session tokens are handled securely:

- **Token Masking**: Tokens are masked in logs (only first 8 and last 4 characters visible)
- **Debug Guards**: Sensitive token logging is wrapped in `kDebugMode` checks
- **Validation**: Token format and expiration are validated before use
- **Storage**: Tokens are stored in secure storage (never in SharedPreferences)

### 8. Network Security

Additional network security measures:

- **HTTPS Only**: All API communications use HTTPS
- **Network Status Monitoring**: App detects network changes and handles offline scenarios
- **Connection Timeout**: Configurable timeouts prevent hanging requests
- **Error Handling**: Network errors are caught and handled gracefully without exposing sensitive information

## Security Best Practices for Developers

### For Contributors

1. **Never Commit Secrets**: Never commit API keys, tokens, or passwords to the repository
2. **Use Environment Variables**: Sensitive configuration should use environment variables
3. **Test Security Features**: Always test security features in both debug and release modes
4. **Follow Validation Patterns**: Use existing validation utilities for new inputs
5. **Review Dependencies**: Regularly audit dependencies for security vulnerabilities
6. **Sanitize Logs**: Never log sensitive user data, even in debug mode

### For Security Researchers

If you discover a security vulnerability:

1. **Do NOT** open a public GitHub issue
2. Contact the maintainers privately via email
3. Provide detailed reproduction steps
4. Allow reasonable time for a fix before public disclosure

## Certificate Rotation

### Before Your Certificate Expires

The SSL certificate for api.chuk.dev expires on **January 7, 2026**. To rotate the certificate before expiration:

#### 1. Obtain the New Certificate Fingerprint

Use OpenSSL to extract the SHA-256 fingerprint of the new certificate:

```bash
# Download certificate and extract public key fingerprint
openssl s_client -connect api.chuk.dev:443 -servername api.chuk.dev < /dev/null 2>/dev/null | \
  openssl x509 -outform PEM > /tmp/new_cert.pem

openssl x509 -in /tmp/new_cert.pem -pubkey -noout | \
  openssl pkey -pubin -outform der | \
  openssl dgst -sha256 -binary | \
  openssl enc -base64
```

This will output a Base64-encoded SHA-256 hash like:
```
bd7NPPpXedasuFCk8HN7QGbJNpWwrcO++lerFEbCh2I=
```

#### 2. Update the Certificate Pin

Edit `lib/utils/certificate_pinning.dart` and update the `_pins` list:

```dart
static final List<CertificatePin> _pins = [
  CertificatePin(
    domain: 'api.chuk.dev',
    sha256Hashes: [
      'bd7NPPpXedasuFCk8HN7QGbJNpWwrcO++lerFEbCh2I=',  // Current certificate (expires Jan 2026)
      'NEW_CERTIFICATE_FINGERPRINT_HERE',              // New certificate (add BEFORE rotation)
    ],
    includeSubdomains: true,
  ),
];
```

**IMPORTANT**: Add the new certificate fingerprint to the list while keeping the old one. This allows both certificates to work during the transition period.

#### 3. Release Updated App

1. Increment version in `pubspec.yaml`
2. Build and release the updated app: `./build.sh all`
3. Distribute the update to users

#### 4. Rotate the Certificate on the Server

After most users have updated to the new app version:

1. Install the new certificate on the server
2. Monitor for connection failures
3. If issues occur, roll back and investigate

#### 5. Remove the Old Certificate Pin

After the old certificate has fully expired and all users have updated:

1. Remove the old certificate fingerprint from `_pins`
2. Keep only the new certificate fingerprint
3. Release a maintenance update

### Certificate Expiration Emergency

If the certificate expires before rotation (emergency scenario):

1. **Immediate**: Release a hotfix build with certificate pinning temporarily disabled
2. **Same Day**: Deploy new certificate on server
3. **Within 24h**: Release proper update with new certificate pin
4. **Post-Mortem**: Document what went wrong and update processes

## Security Updates

This document was last updated: 2025-01-12

Security features are continuously reviewed and updated. Check the git history for recent security improvements.
