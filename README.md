# chuk.chat

An encrypted, Supabase-backed chat UI with optional Stripe billing.

## Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) 3.9 or newer
- A [Supabase](https://supabase.com/) project with email OTP auth enabled
- A [Stripe](https://stripe.com/) account for subscription billing

## Configuration

1. **Create the environment file**

   ```bash
   cp .env.example .env
   ```

   Fill in the following keys:

   | Key | Description |
   | --- | --- |
   | `SUPABASE_URL` | Supabase project URL |
   | `SUPABASE_ANON_KEY` | Supabase anon/public API key |
   | `SUPABASE_CHATS_TABLE` | Table that stores encrypted chats (default `user_chats`) |
   | `SUPABASE_SUBSCRIPTIONS_TABLE` | Table tracking Stripe subscription state (default `user_subscriptions`) |
   | `SUPABASE_FUNCTION_BILLING_ENDPOINT` | Edge function used to start Stripe checkout |
   | `STRIPE_PUBLISHABLE_KEY` | Stripe publishable key used by the Flutter SDK |
   | `STRIPE_MERCHANT_IDENTIFIER` | iOS merchant identifier (Apple Pay) |
   | `STRIPE_RETURN_URL` | Deep link the Stripe checkout should return to |
   | `ENCRYPTION_SECRET` | Secret string used to derive per-user encryption keys |

2. **Database tables**

   Minimal schemas for the required tables:

   ```sql
   -- Stores encrypted chat transcripts per Supabase auth user.
   create table public.user_chats (
     id bigint generated always as identity primary key,
     user_id uuid references auth.users not null,
     chat_json text not null,
     created_at timestamp with time zone default timezone('utc', now()) not null
   );

    -- Tracks whether the user has an active Stripe subscription for the current period.
   create table public.user_subscriptions (
     user_id uuid references auth.users primary key,
     is_active boolean default false not null,
     current_period_end timestamp with time zone
   );
   ```

3. **Stripe billing function**

   The app expects a Supabase Edge function (default `billing/create-checkout-session`) that returns a JSON payload containing a `checkoutUrl`. Implement this function to create Stripe Checkout or Billing Portal sessions for the authenticated Supabase user.

## Running the app

Install dependencies and run the Flutter app as usual:

```bash
flutter pub get
flutter run
```

Users sign in with email-based one-time codes issued by Supabase. Chat transcripts are encrypted locally using a key derived from the user email and the shared `ENCRYPTION_SECRET` before being stored in Supabase. Subscription status is read from the `user_subscriptions` table, and Stripe checkout is launched via the configured Edge function.
