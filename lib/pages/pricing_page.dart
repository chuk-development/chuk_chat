import 'dart:convert';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/pages/usage_details_page.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';
import 'package:chuk_chat/widgets/settings_kit.dart';

final SupabaseClient _supabase = Supabase.instance.client;

// API base URL — resolved from ApiConfigService (debug → local, release → production)
final String _apiBaseUrl = ApiConfigService.apiBaseUrl;

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
  final session = await SupabaseService.refreshSession() ??
      _supabase.auth.currentSession;
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
      _showError(AppLocalizations.of(context)!.agreeToTermsFirst);
      return;
    }

    setState(() => _isProcessing = true);
    try {
      // Re-check subscription status before opening checkout to prevent
      // duplicate subscriptions (server also checks, this is defense in depth)
      final freshStatus = await getUserStatus();
      if (!mounted) return;
      if (freshStatus['has_subscription'] == true) {
        setState(() {
          _userStatus = freshStatus;
          _isProcessing = false;
        });
        _showError(AppLocalizations.of(context)!.alreadySubscribed);
        return;
      }

      await startCheckout();

      // Wait a bit and refresh
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) _loadUserStatus();
      });
    } catch (error) {
      if (!mounted) return;
      final msg = error.toString();
      if (msg.contains('already have an active subscription')) {
        // Server confirmed subscription exists — refresh UI
        _loadUserStatus();
      }
      _showError(msg.replaceAll('Exception: ', ''));
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
    NiceSnackBar.show(
      context,
      message,
      duration: const Duration(seconds: 3),
      backgroundColor: Colors.red,
    );
  }

  void _openUsageDetails() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const UsageDetailsPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    final bool paymentsDisabled = !kFeaturePaymentsDirect;
    final l = AppLocalizations.of(context)!;

    if (_isLoading) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(
          title: Text(l.subscription),
          centerTitle: false,
          backgroundColor: colorScheme.surface,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final hasSubscription = _userStatus?['has_subscription'] == true;
    final currentPlan = _userStatus?['current_plan'] as String?;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: Text(l.subscription),
        centerTitle: false,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Credits ────────────────────────────────────────────
          const SettingsSectionHeader(
            'CREDITS',
            padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
          ),
          Container(
            decoration: BoxDecoration(
              color: m3.surfaceContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CreditDisplay(),
                const SizedBox(height: 12),
                Text(
                  l.openUsageDetailsInfo,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: m3.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.query_stats, size: 18),
                  label: Text(l.openUsageDetails),
                  onPressed: _openUsageDetails,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Plans ──────────────────────────────────────────────
          const SettingsSectionHeader(
            'PLANS',
            padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
          ),

          // Payments-disabled notice
          if (paymentsDisabled) ...[
            SettingsInfoCard(l.paymentsDisabledInBuild),
            const SizedBox(height: 12),
          ],

          // Active plan card (if subscribed)
          if (hasSubscription)
            _PlanCard(
              title: currentPlan ?? l.plus,
              price: l.pricePerMonth,
              features: [
                l.monthlyCredits,
                l.unusedCreditsExpire,
              ],
              badgeLabel: l.active,
              badgeTone: _BadgeTone.success,
              highlighted: false,
              child: !paymentsDisabled
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed:
                              _isProcessing ? null : _handleManageBilling,
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
                              : const Icon(Icons.credit_card, size: 18),
                          label: Text(
                            _isProcessing ? l.opening : l.manageBilling,
                          ),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l.manageBillingSubtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    )
                  : null,
            ),

          if (hasSubscription) const SizedBox(height: 16),

          // Plus plan subscribe card (if not already subscribed)
          if (!hasSubscription)
            _PlanCard(
              title: l.plus,
              price: '€20/month',
              features: [
                l.getCreditsMonthly,
                l.accessAllModels,
                l.imageGeneration,
                l.voiceMode,
                l.textChatReasoning,
              ],
              badgeLabel: 'Popular',
              badgeTone: _BadgeTone.primary,
              highlighted: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      l.creditsExplanation,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                  if (!paymentsDisabled) ...[
                    const SizedBox(height: 16),
                    // Consent checkbox — inline rich text with terms + withdrawal links.
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
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.8),
                              width: 1.5,
                            ),
                            checkColor: colorScheme.onPrimary,
                            fillColor: WidgetStateProperty.resolveWith(
                              (states) {
                                if (states.contains(WidgetState.selected)) {
                                  return Colors.white;
                                }
                                return Colors.transparent;
                              },
                            ),
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
                                  color: Colors.white.withValues(alpha: 0.9),
                                  fontSize: 12,
                                  height: 1.4,
                                ),
                                children: [
                                  TextSpan(text: l.immediateAccessAck),
                                  TextSpan(
                                    text: l.rightOfWithdrawal,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      decoration: TextDecoration.underline,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    recognizer: TapGestureRecognizer()
                                      ..onTap = () => _launchExternalUrl(
                                            'https://chuk.chat/en/cancellation/',
                                          ),
                                  ),
                                  TextSpan(text: l.onceServiceBegins),
                                  TextSpan(
                                    text: l.termsOfService,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      decoration: TextDecoration.underline,
                                      fontWeight: FontWeight.w600,
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
                      child: FilledButton(
                        onPressed: _isProcessing || !_agreedToTerms
                            ? null
                            : _handleSubscribe,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: colorScheme.primary,
                          disabledBackgroundColor:
                              Colors.white.withValues(alpha: 0.35),
                          disabledForegroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          elevation: 0,
                        ),
                        child: _isProcessing
                            ? SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    colorScheme.primary,
                                  ),
                                ),
                              )
                            : Text(
                                l.subscribeNow,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─── Reusable private pieces ─────────────────────────────────────────────

enum _BadgeTone { primary, success, warn, neutral }

class _Badge extends StatelessWidget {
  final String label;
  final _BadgeTone tone;
  const _Badge(this.label, {this.tone = _BadgeTone.neutral});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    late Color bg;
    late Color fg;
    switch (tone) {
      case _BadgeTone.primary:
        bg = m3.primaryContainer;
        fg = m3.onPrimaryContainer;
        break;
      case _BadgeTone.success:
        bg = m3.successContainer;
        fg = m3.onSuccessContainer;
        break;
      case _BadgeTone.warn:
        bg = m3.warningContainer;
        fg = m3.onWarningContainer;
        break;
      case _BadgeTone.neutral:
        bg = m3.surfaceContainerHigh;
        fg = m3.onSurfaceVariant;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.15,
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final String title;
  final String price;
  final List<String> features;
  final String? badgeLabel;
  final _BadgeTone badgeTone;
  final bool highlighted;
  final Widget? child;

  const _PlanCard({
    required this.title,
    required this.price,
    required this.features,
    required this.highlighted,
    this.badgeLabel,
    this.badgeTone = _BadgeTone.neutral,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;

    // Highlighted plans get the gradient treatment; others surfaceContainer.
    final BoxDecoration decoration = highlighted
        ? BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                m3.primaryContainer,
                m3.tertiaryContainer,
              ],
            ),
          )
        : BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: m3.surfaceContainer,
          );

    final Color titleColor =
        highlighted ? Colors.white : colorScheme.onSurface;
    final Color priceColor =
        highlighted ? Colors.white : colorScheme.onSurface;
    final Color featureColor = highlighted
        ? Colors.white.withValues(alpha: 0.9)
        : m3.onSurfaceVariant;
    final Color checkColor =
        highlighted ? Colors.white : colorScheme.primary;

    return Container(
      decoration: decoration,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: titleColor,
                  ),
                ),
              ),
              if (badgeLabel != null) _Badge(badgeLabel!, tone: badgeTone),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            price,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: priceColor,
            ),
          ),
          const SizedBox(height: 16),
          for (final feature in features)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle, size: 16, color: checkColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      feature,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: featureColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ?child,
        ],
      ),
    );
  }
}
