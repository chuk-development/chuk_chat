#!/bin/bash

# Manual subscription sync script
# This calls the API to sync your Stripe subscription to Supabase

echo "=== Manual Subscription Sync ==="
echo ""
echo "Please get your JWT token from the Flutter app:"
echo "1. Open Developer Tools in your app"
echo "2. Find the Authorization header from any API request"
echo "3. Copy the token (everything after 'Bearer ')"
echo ""
read -p "Paste your JWT token here: " JWT_TOKEN

echo ""
echo "Syncing subscription from Stripe..."
echo ""

RESPONSE=$(curl -s -X POST "https://api.chuk.chat/stripe/sync-subscription" \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json")

echo "Response:"
echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"

echo ""
echo "Done! Now check your Flutter app - credits should be updated."
