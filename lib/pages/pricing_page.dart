import 'dart:convert';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

final SupabaseClient _supabase = Supabase.instance.client;

// API base URL - defaults to production
const String _apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://api.chuk.chat',
);

Future<void> _launchExternalUrl(String url) async {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) {
    throw Exception('Invalid URL provided.');
  }

  final bool didLaunch = await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
  );
  if (!didLaunch) {
    throw Exception('Unable to open the requested link.');
  }
}

Future<String> _getAccessToken() async {
  final session = _supabase.auth.currentSession;
  if (session == null) {
    throw Exception('Not authenticated');
  }
  return session.accessToken;
}

Future<void> startCheckout() async {
  final token = await _getAccessToken();

  final response = await http.post(
    Uri.parse('$_apiBaseUrl/v1/stripe/create-checkout-session'),
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    },
  );

  if (response.statusCode == 409) {
    throw Exception('You already have an active subscription.');
  }
  if (response.statusCode != 200) {
    throw Exception('Failed to create checkout session: ${response.body}');
  }

  final data = jsonDecode(response.body);
  final checkoutUrl = data['checkout_url'] as String?;

  if (checkoutUrl == null) {
    throw Exception('No checkout URL returned');
  }

  await _launchExternalUrl(checkoutUrl);
}

Future<void> openBillingPortal() async {
  final token = await _getAccessToken();

  final response = await http.post(
    Uri.parse('$_apiBaseUrl/v1/stripe/create-portal-session'),
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    },
  );

  if (response.statusCode == 404) {
    throw Exception('No subscription found. Please subscribe first.');
  }

  if (response.statusCode != 200) {
    throw Exception('Failed to create portal session: ${response.body}');
  }

  final data = jsonDecode(response.body);
  final portalUrl = data['portal_url'] as String?;

  if (portalUrl == null) {
    throw Exception('No portal URL returned');
  }

  await _launchExternalUrl(portalUrl);
}

Future<void> syncSubscription() async {
  final token = await _getAccessToken();

  final response = await http.post(
    Uri.parse('$_apiBaseUrl/v1/stripe/sync-subscription'),
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    },
  );

  if (response.statusCode != 200) {
    throw Exception('Failed to sync subscription: ${response.body}');
  }
}

Future<Map<String, dynamic>> getUserStatus() async {
  final token = await _getAccessToken();

  final response = await http.get(
    Uri.parse('$_apiBaseUrl/v1/user/status'),
    headers: {'Authorization': 'Bearer $token'},
  );

  if (response.statusCode != 200) {
    throw Exception('Failed to get user status: ${response.body}');
  }

  return jsonDecode(response.body) as Map<String, dynamic>;
}

class PricingPage extends StatefulWidget {
  const PricingPage({super.key});

  @override
  State<PricingPage> createState() => _PricingPageState();
}

class _PricingPageState extends State<PricingPage> with WidgetsBindingObserver {
  Map<String, dynamic>? _userStatus;
  bool _isLoading = true;
  bool _isProcessing = false;
  bool _agreedToTerms = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadUserStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh when user returns from browser (Stripe checkout/portal)
    if (state == AppLifecycleState.resumed) {
      _loadUserStatus();
    }
  }

  Future<void> _loadUserStatus() async {
    setState(() => _isLoading = true);

    try {
      final status = await getUserStatus();
      if (!mounted) return;
      setState(() {
        _userStatus = status;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      if (kDebugMode) {
        debugPrint('Error loading user status: $error');
      }
    }
  }

  Future<void> _handleSubscribe() async {
    if (_isProcessing) return;

    if (!_agreedToTerms) {
      _showError(
        'Please agree to the terms and acknowledge loss of withdrawal rights.',
      );
      return;
    }

    setState(() => _isProcessing = true);
    try {
      await startCheckout();

      // Wait a bit and refresh
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) _loadUserStatus();
      });
    } catch (error) {
      if (!mounted) return;
      _showError(error.toString());
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _handleManageBilling() async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);
    try {
      await openBillingPortal();

      // Wait and refresh
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) _loadUserStatus();
      });
    } catch (error) {
      if (!mounted) return;
      _showError(error.toString());
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color accent = theme.colorScheme.primary;
    final Color iconFg = theme.resolvedIconColor;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;
    final bool isMobile =
        kPlatformMobile || MediaQuery.of(context).size.width < 720;

    if (_isLoading) {
      return Scaffold(
        backgroundColor: scaffoldBg,
        appBar: AppBar(
          title: Text('Subscription', style: titleTextStyle),
          backgroundColor: scaffoldBg,
          elevation: 0,
          iconTheme: IconThemeData(color: iconFg),
        ),
        body: Center(child: CircularProgressIndicator(color: accent)),
      );
    }

    final hasSubscription = _userStatus?['has_subscription'] == true;
    final currentPlan = _userStatus?['current_plan'] as String?;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Subscription', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Credit Display
            const CreditDisplay(),
            const SizedBox(height: 24),

            // Current Plan Card (if subscribed)
            if (hasSubscription) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: scaffoldBg.lighten(0.05),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: accent, width: 2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.check_circle, color: accent, size: 24),
                        const SizedBox(width: 8),
                        Text(
                          'Current Plan',
                          style: TextStyle(
                            color: accent,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      currentPlan ?? 'Plus',
                      style: TextStyle(
                        color: iconFg,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '€20/month',
                      style: TextStyle(
                        color: iconFg.withValues(alpha: 0.7),
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Monthly AI credits: €16.00',
                      style: TextStyle(
                        color: iconFg.withValues(alpha: 0.7),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      'Unused credits expire at the end of each month.',
                      style: TextStyle(
                        color: iconFg.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                    if (!isMobile) ...[
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isProcessing
                              ? null
                              : _handleManageBilling,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: accent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: _isProcessing
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                )
                              : const Icon(Icons.credit_card),
                          label: Text(
                            _isProcessing ? 'Opening...' : 'Manage Billing',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, color: accent, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Use the billing portal to cancel your subscription or update payment methods.',
                                style: TextStyle(
                                  color: iconFg.withValues(alpha: 0.8),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],

            // Plan Header
            Text(
              hasSubscription
                  ? 'Subscription Plan'
                  : 'Subscribe to Get AI Credits',
              style: TextStyle(
                color: iconFg,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),

            // Mobile notice
            if (isMobile) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scaffoldBg.lighten(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withValues(alpha: 0.4)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.desktop_windows, color: accent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Subscription management is only available on desktop.',
                        style: TextStyle(
                          color: iconFg.withValues(alpha: 0.7),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Plus Plan Card
            Card(
              elevation: hasSubscription ? 8 : 4,
              shadowColor: Colors.black.withValues(alpha: 0.1),
              color: scaffoldBg.lighten(0.05),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: hasSubscription
                      ? accent
                      : iconFg.withValues(alpha: 0.3),
                  width: hasSubscription ? 2 : 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (hasSubscription)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'ACTIVE',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      'Plus',
                      style: TextStyle(
                        color: iconFg,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          '€',
                          style: TextStyle(
                            color: accent,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '20',
                          style: TextStyle(
                            color: accent,
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '/month',
                          style: TextStyle(
                            color: iconFg.withValues(alpha: 0.7),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '§19 UStG — no VAT charged',
                      style: TextStyle(
                        color: iconFg.withValues(alpha: 0.6),
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildFeature(
                      accent,
                      iconFg,
                      'Get €16 in AI credits monthly',
                    ),
                    _buildFeature(accent, iconFg, 'Access to all AI models'),
                    _buildFeature(accent, iconFg, 'Image generation'),
                    _buildFeature(accent, iconFg, 'Voice mode'),
                    _buildFeature(accent, iconFg, 'Text chat with reasoning'),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Your €16 in AI credits are used per token based on the model you choose. Unused credits expire at the end of each month.',
                        style: TextStyle(
                          color: iconFg.withValues(alpha: 0.8),
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (!isMobile && !hasSubscription) ...[
                      const SizedBox(height: 20),
                      // Consent checkbox
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Checkbox(
                              value: _agreedToTerms,
                              onChanged: (value) {
                                setState(() => _agreedToTerms = value ?? false);
                              },
                              activeColor: accent,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                setState(
                                  () => _agreedToTerms = !_agreedToTerms,
                                );
                              },
                              child: Text.rich(
                                TextSpan(
                                  style: TextStyle(
                                    color: iconFg.withValues(alpha: 0.8),
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                  children: [
                                    const TextSpan(
                                      text:
                                          'I want immediate access to Chuk Chat and acknowledge that I lose my ',
                                    ),
                                    TextSpan(
                                      text: 'right of withdrawal',
                                      style: TextStyle(
                                        color: accent,
                                        decoration: TextDecoration.underline,
                                      ),
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () => _launchExternalUrl(
                                          'https://chuk.chat/en/cancellation/',
                                        ),
                                    ),
                                    const TextSpan(
                                      text:
                                          ' once the service begins. I agree to the ',
                                    ),
                                    TextSpan(
                                      text: 'Terms of Service',
                                      style: TextStyle(
                                        color: accent,
                                        decoration: TextDecoration.underline,
                                      ),
                                      recognizer: TapGestureRecognizer()
                                        ..onTap = () => _launchExternalUrl(
                                          'https://chuk.chat/en/terms/',
                                        ),
                                    ),
                                    const TextSpan(text: '.'),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isProcessing || !_agreedToTerms
                              ? null
                              : _handleSubscribe,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: accent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 4,
                          ),
                          child: _isProcessing
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                  ),
                                )
                              : const Text(
                                  'Subscribe Now',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 16,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeature(Color accent, Color iconFg, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: accent, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: iconFg.withValues(alpha: 0.9),
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
