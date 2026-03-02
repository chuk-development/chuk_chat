#!/bin/bash
# Helper script to run Flutter with environment variables from .env

set -e

# Load .env file if it exists
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Check if credentials are set
if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_ANON_KEY" ]; then
  echo "Error: SUPABASE_URL and SUPABASE_ANON_KEY must be set."
  echo "Copy .env.example to .env and fill in your values."
  exit 1
fi

# Default to linux if no device specified
DEVICE="${1:-linux}"

# Build dart-define arguments
DART_DEFINES="--dart-define=SUPABASE_URL=$SUPABASE_URL --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY"

# Override the local API server URL (debug builds use http://localhost:8000 by default).
# Set LOCAL_API_URL in .env or export it to change:
#   LOCAL_API_URL=http://192.168.1.10:8000  ./run.sh linux
if [ -n "$LOCAL_API_URL" ]; then
  DART_DEFINES="$DART_DEFINES --dart-define=LOCAL_API_URL=$LOCAL_API_URL"
fi

# Add any additional dart-defines for features
if [ -n "$FEATURE_PROJECTS" ]; then
  DART_DEFINES="$DART_DEFINES --dart-define=FEATURE_PROJECTS=$FEATURE_PROJECTS"
fi
if [ -n "$FEATURE_IMAGE_GEN" ]; then
  DART_DEFINES="$DART_DEFINES --dart-define=FEATURE_IMAGE_GEN=$FEATURE_IMAGE_GEN"
fi
if [ -n "$FEATURE_VOICE_MODE" ]; then
  DART_DEFINES="$DART_DEFINES --dart-define=FEATURE_VOICE_MODE=$FEATURE_VOICE_MODE"
fi

# Run Flutter
echo "Running flutter with device: $DEVICE"
flutter run -d "$DEVICE" $DART_DEFINES
