// lib/services/stripe_billing_service.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class StripeBillingService {
  StripeBillingService._();

  static final StripeBillingService instance = StripeBillingService._();

  final ValueNotifier<bool> subscriptionActive = ValueNotifier<bool>(false);
  final ValueNotifier<DateTime?> subscriptionValidUntil = ValueNotifier<DateTime?>(null);
  final SupabaseClient _client = Supabase.instance.client;

  String get _functionEndpoint =>
      dotenv.env['SUPABASE_FUNCTION_BILLING_ENDPOINT'] ??
      'billing/create-checkout-session';
  String get _subscriptionsTable =>
      dotenv.env['SUPABASE_SUBSCRIPTIONS_TABLE'] ?? 'user_subscriptions';

  Future<bool> refreshSubscriptionStatus() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      subscriptionActive.value = false;
      subscriptionValidUntil.value = null;
      return false;
    }

    final dynamic response = await _client
        .from(_subscriptionsTable)
        .select('is_active, current_period_end')
        .eq('user_id', user.id)
        .maybeSingle();

    final Map<String, dynamic>? data =
        response is Map<String, dynamic> ? response : null;

    final bool isActive = data != null && (data['is_active'] as bool? ?? false);
    final String? periodEnd = data?['current_period_end'] as String?;
    subscriptionValidUntil.value =
        periodEnd != null ? DateTime.tryParse(periodEnd)?.toUtc() : null;
    subscriptionActive.value = isActive;
    return isActive;
  }

  Future<void> startSubscriptionCheckout() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw StateError('User must be signed in to start checkout.');
    }

    final response = await _client.functions.invoke(
      _functionEndpoint,
      body: {
        'returnUrl': dotenv.env['STRIPE_RETURN_URL'],
      },
    );

    final dynamic data = response.data;
    if (data is! Map<String, dynamic>) {
      throw StateError('Unexpected response from billing endpoint.');
    }

    final String? checkoutUrl = data['checkoutUrl'] as String?;
    if (checkoutUrl == null) {
      throw StateError('Missing checkout URL in response.');
    }

    final uri = Uri.parse(checkoutUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open Stripe checkout.');
    }
  }

  void configureStripe() {
    final publishableKey = dotenv.env['STRIPE_PUBLISHABLE_KEY'];
    if (publishableKey == null || publishableKey.isEmpty) {
      return;
    }
    Stripe.publishableKey = publishableKey;
    final merchantId = dotenv.env['STRIPE_MERCHANT_IDENTIFIER'];
    if (merchantId != null && merchantId.isNotEmpty) {
      Stripe.merchantIdentifier = merchantId;
    }
  }
}
