# Certificate Pinning Setup Guide

This guide explains how to configure SSL certificate pinning for the chuk_chat application.

## What is Certificate Pinning?

Certificate pinning is a security measure that ensures your app only trusts specific SSL certificates. This prevents man-in-the-middle (MITM) attacks where an attacker intercepts network traffic by presenting a fake certificate.

## Why is it Important?

Without certificate pinning:
- ✗ Attackers can intercept API communications using fake certificates
- ✗ Corporate proxies can decrypt your traffic
- ✗ Users on compromised networks are vulnerable

With certificate pinning:
- ✓ App only trusts your specific API certificates
- ✓ MITM attacks are prevented
- ✓ Enhanced security for sensitive data

## How It Works

1. **Production Mode**: Certificate pinning is ENABLED
   - App validates that the server's certificate matches configured pins
   - Connections fail if certificate doesn't match

2. **Debug Mode**: Certificate pinning is DISABLED
   - Allows easier development and testing
   - Uses standard SSL validation

## Setup Instructions

### Step 1: Get Your API Certificate Fingerprint

Run these commands to extract the SHA-256 fingerprint of your API server's public key:

```bash
# 1. Download the certificate
openssl s_client -connect api.yourservice.com:443 -servername api.yourservice.com < /dev/null 2>/dev/null | openssl x509 -outform PEM > cert.pem

# 2. Extract public key and calculate SHA-256 hash
openssl x509 -in cert.pem -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64

# This outputs something like:
# r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=
```

**Important**: You should pin at least 2 certificates:
1. Your current production certificate
2. A backup certificate (for rotation)

### Step 2: Configure Certificate Pins

Edit `lib/utils/certificate_pinning.dart` and add your certificate pins:

```dart
static final List<CertificatePin> _pins = [
  CertificatePin(
    domain: 'api.yourservice.com',
    sha256Hashes: [
      'r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=',  // Primary cert
      'YLh1dUR9y6Kja30RrAn7JKnbQG/uEtLMkBgFF2Fuihg=',  // Backup cert
    ],
    includeSubdomains: true,  // Also pin *.api.yourservice.com
  ),

  // Add more domains as needed
  CertificatePin(
    domain: 'cdn.yourservice.com',
    sha256Hashes: [
      'another_certificate_hash_here',
    ],
    includeSubdomains: false,
  ),
];
```

### Step 3: Update Your Services

Services using `Dio` should use the certificate pinning utility:

```dart
import 'package:chuk_chat/utils/certificate_pinning.dart';

// Option 1: Create a secure Dio instance
final dio = CertificatePinning.createSecureDio(
  baseUrl: 'https://api.yourservice.com',
  headers: {'Authorization': 'Bearer $token'},
);

// Option 2: Enable pinning on existing Dio instance
final dio = Dio();
CertificatePinning.configureDio(dio);

// Option 3: Using extension
final dio = Dio();
dio.enableCertificatePinning();
```

### Step 4: Test Certificate Pinning

1. **Test in Debug Mode** (pinning disabled):
   ```bash
   flutter run --debug
   ```
   - App should work normally
   - Certificate validation uses standard SSL

2. **Test in Production Mode** (pinning enabled):
   ```bash
   flutter run --release
   ```
   - App should work with correct certificates
   - Should fail with incorrect certificates

3. **Test MITM Protection**:
   - Use a proxy like Charles or mitmproxy
   - In production build, connections should fail
   - You should see: "Certificate pinning failed for api.yourservice.com"

## Certificate Rotation

**IMPORTANT**: Plan for certificate rotation!

### Before Your Certificate Expires:

1. Generate new certificate
2. Get SHA-256 fingerprint of new certificate
3. Add new fingerprint to `_pins` list (keep old one too)
4. Deploy app update with both certificates
5. After users update, rotate actual certificate on server
6. In next app version, remove old certificate fingerprint

### Example Rotation Process:

**Version 1.0** (Current):
```dart
sha256Hashes: [
  'old_cert_hash',  // Current certificate
]
```

**Version 1.1** (Preparation):
```dart
sha256Hashes: [
  'old_cert_hash',  // Current certificate
  'new_cert_hash',  // New certificate (not yet active)
]
```

**Server Update**: Switch to new certificate (both work)

**Version 1.2** (Cleanup):
```dart
sha256Hashes: [
  'new_cert_hash',  // New certificate (now primary)
  'backup_cert_hash',  // Next rotation certificate
]
```

## Troubleshooting

### "Certificate pinning failed" in production

1. **Check certificate hash**:
   - Re-run openssl commands
   - Verify hash matches exactly (case-sensitive, with special chars)

2. **Check domain name**:
   - Ensure domain in `_pins` matches exactly
   - Check if you need `includeSubdomains: true`

3. **Check certificate expiration**:
   ```bash
   openssl s_client -connect api.yourservice.com:443 -servername api.yourservice.com < /dev/null 2>/dev/null | openssl x509 -noout -dates
   ```

### Development Issues

If certificate pinning interferes with development:

1. Certificate pinning is automatically disabled in debug builds
2. You can temporarily clear pins for testing:
   ```dart
   if (kDebugMode) {
     CertificatePinning.clearAllPins();
   }
   ```

### Proxy/Corporate Network Issues

Some corporate networks use SSL inspection. For legitimate development:

1. Debug builds bypass certificate pinning
2. Production builds enforce pinning (security over convenience)
3. Document this requirement for corporate users

## Security Best Practices

1. **Pin Multiple Certificates**:
   - Current certificate
   - Backup certificate for rotation
   - Minimizes risk during certificate updates

2. **Monitor Certificate Expiration**:
   - Set calendar reminders
   - Plan rotation at least 2 months before expiration
   - Have emergency rotation process

3. **Test Thoroughly**:
   - Test in production build before release
   - Test on real devices, not just emulators
   - Test with VPN/proxy to verify MITM protection

4. **Document Changes**:
   - Log certificate updates in version control
   - Document rotation schedule
   - Keep backup of certificate hashes

5. **Handle Failures Gracefully**:
   - Show clear error messages to users
   - Provide support contact information
   - Log failures for monitoring

## Monitoring

### Debug Logging

In debug builds, certificate pinning logs detailed information:

```
🔒 Certificate pinning enabled for api.yourservice.com
   Expected pins: 2
✅ Certificate validated for api.yourservice.com
   Fingerprint: r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=
```

### Check Status

```dart
// Log current certificate pinning configuration
CertificatePinning.logStatus();

// Output:
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 🔒 CERTIFICATE PINNING STATUS
// Enabled: YES (production)
// Configured pins: 2
//   • api.yourservice.com
//     Hashes: 2
//     Subdomains: true
//   • cdn.yourservice.com
//     Hashes: 1
//     Subdomains: false
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## References

- [OWASP Certificate Pinning](https://owasp.org/www-community/controls/Certificate_and_Public_Key_Pinning)
- [Dio Security](https://pub.dev/packages/dio)
- [Flutter Security Best Practices](https://flutter.dev/docs/deployment/security)

## Support

For questions or issues with certificate pinning setup, check:
1. This documentation
2. `lib/utils/certificate_pinning.dart` source code
3. Flutter security documentation
