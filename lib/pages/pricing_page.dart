// lib/pages/pricing_page.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;
import 'package:url_launcher/url_launcher_string.dart';

final SupabaseClient _supabase = Supabase.instance.client;
const String _starterPriceId = 'price_1SHRmD4RznxB1MLdyNEhp4On';
const String _plusPriceId = 'price_1SHRnc4RznxB1MLdckKKLgvg';
const String _proPriceId = 'price_1SHRo84RznxB1MLdixi99wLf';

Future<void> startCheckout(String priceId) async {
  // Ensure the user exists
  final user = _supabase.auth.currentUser;
  if (user == null) {
    throw Exception('User not signed in');
  }

  // Create or fetch customer
  await _supabase.functions.invoke('get_or_create_customer');

  // Create checkout session
  final res = await _supabase.functions.invoke(
    'create_checkout_session',
    body: {'priceId': priceId},
  );

  final data = res.data;
  if (data is! Map || data['url'] is! String) {
    throw Exception('Checkout session could not be created');
  }
  final url = data['url'] as String;
  await launchUrlString(url, mode: LaunchMode.externalApplication);
}

class PricingPage extends StatelessWidget {
  const PricingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color accent = theme.colorScheme.primary;
    final Color iconFg = theme.iconTheme.color!;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;
    final bool isMobile = MediaQuery.of(context).size.width < 720;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Pricing Plans', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Choose Your Plan',
              style: TextStyle(
                color: iconFg,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Select the perfect plan for your needs. All plans include our core features.',
              style: TextStyle(
                color: iconFg.withValues(alpha: 0.7),
                fontSize: 16,
              ),
            ),
            if (isMobile) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scaffoldBg.lighten(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: iconFg.withValues(alpha: 0.2)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: accent, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Checkout is currently available on desktop or web only. '
                        'Please switch devices to complete your subscription.',
                        style: TextStyle(
                          color: iconFg.withValues(alpha: 0.75),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 32),

            // Pricing Cards
            if (isMobile)
              Column(
                children: [
                  _PricingCard(
                    title: 'Starter',
                    price: 10,
                    features: [
                      'Image Generation',
                      'Voice Mode',
                      'Text Chat',
                      'Basic Support',
                    ],
                    priceId: _starterPriceId,
                    accent: accent,
                    iconFg: iconFg,
                    scaffoldBg: scaffoldBg,
                    isPopular: false,
                    isMobile: true,
                  ),
                  const SizedBox(height: 16),
                  _PricingCard(
                    title: 'Plus',
                    price: 20,
                    features: [
                      'Image Generation',
                      'Voice Mode',
                      'Text Chat',
                      'Priority Support',
                      'Extended Features',
                    ],
                    priceId: _plusPriceId,
                    accent: accent,
                    iconFg: iconFg,
                    scaffoldBg: scaffoldBg,
                    isPopular: true,
                    isMobile: true,
                  ),
                  const SizedBox(height: 16),
                  _PricingCard(
                    title: 'Pro',
                    price: 40,
                    features: [
                      'Image Generation',
                      'Voice Mode',
                      'Text Chat',
                      'Premium Support',
                      'Advanced Features',
                      'API Access',
                    ],
                    priceId: _proPriceId,
                    accent: accent,
                    iconFg: iconFg,
                    scaffoldBg: scaffoldBg,
                    isPopular: false,
                    isMobile: true,
                  ),
                ],
              )
            else
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _PricingCard(
                        title: 'Starter',
                        price: 10,
                        features: [
                          'Image Generation',
                          'Voice Mode',
                          'Text Chat',
                          'Basic Support',
                        ],
                        priceId: _starterPriceId,
                        accent: accent,
                        iconFg: iconFg,
                        scaffoldBg: scaffoldBg,
                        isPopular: false,
                        isMobile: false,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _PricingCard(
                        title: 'Plus',
                        price: 20,
                        features: [
                          'Image Generation',
                          'Voice Mode',
                          'Text Chat',
                          'Priority Support',
                          'Extended Features',
                        ],
                        priceId: _plusPriceId,
                        accent: accent,
                        iconFg: iconFg,
                        scaffoldBg: scaffoldBg,
                        isPopular: true,
                        isMobile: false,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _PricingCard(
                        title: 'Pro',
                        price: 40,
                        features: [
                          'Image Generation',
                          'Voice Mode',
                          'Text Chat',
                          'Premium Support',
                          'Advanced Features',
                          'API Access',
                        ],
                        priceId: _proPriceId,
                        accent: accent,
                        iconFg: iconFg,
                        scaffoldBg: scaffoldBg,
                        isPopular: false,
                        isMobile: false,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 32),

            // Information Section - Side by side layout
            if (isMobile)
              Column(
                children: [
                  _InfoCard(
                    title: 'Payment Information',
                    content: [
                      '20% service fee applies to all plans',
                      '90% of your payment goes to AI model credits',
                      '19% tax is added on top of the listed prices',
                      'All prices are shown in €',
                      'Billing is processed monthly',
                    ],
                    accent: accent,
                    iconFg: iconFg,
                    scaffoldBg: scaffoldBg,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  _InfoCard(
                    title: 'All Plans Include',
                    content: [
                      '• High-quality image generation',
                      '• Advanced voice mode with natural conversation',
                      '• Unlimited text chat with AI models',
                      '• Regular updates and new features',
                      '• Secure and private conversations',
                    ],
                    accent: accent,
                    iconFg: iconFg,
                    scaffoldBg: scaffoldBg,
                    textAlign: TextAlign.center,
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: _InfoCard(
                      title: 'Payment Information',
                      content: [
                        '20% service fee applies to all plans',
                        '90% of your payment goes to AI model credits',
                        '19% tax is added on top of the listed prices',
                        'All prices are shown in €',
                        'Billing is processed monthly',
                      ],
                      accent: accent,
                      iconFg: iconFg,
                      scaffoldBg: scaffoldBg,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _InfoCard(
                      title: 'All Plans Include',
                      content: [
                        '• High-quality image generation',
                        '• Advanced voice mode with natural conversation',
                        '• Unlimited text chat with AI models',
                        '• Regular updates and new features',
                        '• Secure and private conversations',
                      ],
                      accent: accent,
                      iconFg: iconFg,
                      scaffoldBg: scaffoldBg,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _PricingCard extends StatelessWidget {
  final String title;
  final int price;
  final List<String> features;
  final String priceId;
  final Color accent;
  final Color iconFg;
  final Color scaffoldBg;
  final bool isPopular;
  final bool isMobile;

  static const int _maxFeatureCount = 6;
  static const double _fillerPerFeature = 28.0;

  const _PricingCard({
    required this.title,
    required this.price,
    required this.features,
    required this.priceId,
    required this.accent,
    required this.iconFg,
    required this.scaffoldBg,
    required this.isPopular,
    required this.isMobile,
  });

  @override
  Widget build(BuildContext context) {
    final String buttonLabel = isMobile
        ? 'Pay on Desktop'
        : isPopular
        ? 'Get Started'
        : 'Choose Plan';
    final int missingFeatures = features.length >= _maxFeatureCount
        ? 0
        : _maxFeatureCount - features.length;
    final double fillerHeight = missingFeatures * _fillerPerFeature;

    return Card(
      elevation: isPopular ? 8 : 4,
      shadowColor: Colors.black.withValues(alpha: 0.1),
      color: scaffoldBg.lighten(0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isPopular ? accent : iconFg.withValues(alpha: 0.3),
          width: isPopular ? 2 : 1,
        ),
      ),
      child: IntrinsicHeight(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isPopular)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'POPULAR',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              if (isPopular) const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(
                  color: iconFg,
                  fontSize: 20,
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
                    price.toString(),
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
              const SizedBox(height: 8),
              Text(
                '+ 19% tax',
                style: TextStyle(
                  color: iconFg.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              ...features.map(
                (feature) => Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: accent, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          feature,
                          style: TextStyle(
                            color: iconFg.withValues(alpha: 0.8),
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (fillerHeight > 0) SizedBox(height: fillerHeight),
              const Spacer(),
              if (isMobile)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: Text(
                    'Payments are available on desktop only.',
                    style: TextStyle(
                      color: iconFg.withValues(alpha: 0.6),
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: isMobile
                      ? null
                      : () async {
                          try {
                            await startCheckout(priceId);
                          } catch (error) {
                            final String message = error is Exception
                                ? error.toString().replaceFirst('Exception: ', '')
                                : 'Unexpected error starting checkout';
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Unable to start checkout: $message',
                                ),
                              ),
                            );
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isPopular ? accent : scaffoldBg.lighten(0.1),
                    foregroundColor: isPopular ? Colors.white : iconFg,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    side: isPopular
                        ? null
                        : BorderSide(color: iconFg.withValues(alpha: 0.3)),
                    elevation: isPopular ? 4 : 2,
                  ),
                  child: Text(
                    buttonLabel,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final List<String> content;
  final Color accent;
  final Color iconFg;
  final Color scaffoldBg;
  final TextAlign textAlign;

  const _InfoCard({
    required this.title,
    required this.content,
    required this.accent,
    required this.iconFg,
    required this.scaffoldBg,
    this.textAlign = TextAlign.left,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: scaffoldBg.lighten(0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: iconFg,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...content.map(
              (text) => Padding(
                padding: const EdgeInsets.only(bottom: 4.0),
                child: Text(
                  text,
                  textAlign: textAlign,
                  style: TextStyle(
                    color: iconFg.withValues(alpha: 0.7),
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
