# API Configuration

This document explains how to configure the API endpoints for different environments and platforms.

## Environment Variables

The app supports the following environment variables for API configuration:

### Production Configuration

Set one of these environment variables for production deployment:

```bash
# Option 1: Complete API URL
API_BASE_URL=https://your-api-domain.com

# Option 2: Host and port separately
API_HOST=your-api-domain.com
API_PORT=443

# Option 3: Production URL (takes precedence)
PRODUCTION_API_URL=https://your-production-api.com
```

### Development Configuration

For local development, the app automatically detects the platform and uses appropriate URLs:

- **Android Emulator**: `http://10.0.2.2:8000` (10.0.2.2 is the special IP for accessing host machine from Android emulator)
- **iOS Simulator**: `http://localhost:8000`
- **Desktop (Windows/Linux/macOS)**: `http://localhost:8000`

## Platform-Specific Behavior

### Android
- **Emulator**: Uses `10.0.2.2:8000` to access the host machine's localhost
- **Physical Device**: Requires the machine's LAN IP address or production URL

### iOS
- **Simulator**: Uses `localhost:8000`
- **Physical Device**: Requires the machine's LAN IP address or production URL

### Desktop
- Uses `localhost:8000` for local development

## Configuration Priority

The API URL is determined in the following order:

1. `PRODUCTION_API_URL` environment variable (highest priority)
2. `API_BASE_URL` environment variable
3. `API_HOST` + `API_PORT` environment variables
4. Platform-specific development URLs (lowest priority)

## Usage in Code

```dart
import 'package:chuk_chat/services/api_config_service.dart';

// Get the current API base URL
String apiUrl = ApiConfigService.apiBaseUrl;

// Check if configuration is valid
bool isConfigured = ApiConfigService.isConfigured;

// Get configuration description for debugging
String description = ApiConfigService.configurationDescription;
```

## Deployment

### Local Development
No configuration needed - the app automatically uses platform-appropriate URLs.

### Production Deployment
Set the appropriate environment variables in your deployment environment:

```bash
# For Docker
docker run -e API_BASE_URL=https://api.yourdomain.com your-app

# For cloud platforms
# Set environment variables in your platform's configuration
```

### Physical Device Testing
For testing on physical devices, you'll need to:

1. Find your machine's LAN IP address
2. Set the environment variable:
   ```bash
   API_BASE_URL=http://YOUR_LAN_IP:8000
   ```
3. Ensure your development server is accessible from the device's network

## Troubleshooting

### Common Issues

1. **"Network error" on Android emulator**: Make sure you're using `10.0.2.2` instead of `localhost`
2. **"Connection refused" on physical device**: Use your machine's LAN IP instead of localhost
3. **"SSL/TLS error" in production**: Ensure your production URL uses HTTPS

### Debug Information

The app provides debug information about the current configuration:

```dart
print(ApiConfigService.configurationDescription);
// Output: Environment: development, Platform: android, URL: http://10.0.2.2:8000, Configured: true
```
