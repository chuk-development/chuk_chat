import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/foundation.dart';

final SupabaseClient _supabase = Supabase.instance.client;

const double _creditMultiplier = 0.9;

// Price IDs from your Stripe dashboard
const Map<String, Map<String, dynamic>> _plans = {
  'price_1SHRmD4RznxB1MLdyNEhp4On': {
    'name': 'Starter',
    'price': 10,
    'features': ['Image Generation', 'Voice Mode', 'Text Chat'],
  },
  'price_1SHRnc4RznxB1MLdckKKLgvg': {
    'name': 'Plus',
    'price': 20,
    'features': ['Image Generation', 'Voice Mode', 'Text Chat'],
  },
  'price_1SHRo84RznxB1MLdixi99wLf': {
    'name': 'Pro',
    'price': 40,
    'features': ['Image Generation', 'Voice Mode', 'Text Chat'],
  },
};

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

Future<void> startCheckout(String priceId) async {
  final user = _supabase.auth.currentUser;
  if (user == null) {
    throw Exception('User not signed in');
  }

  final res = await _supabase.functions.invoke(
    'create_checkout_session',
    body: {'priceId': priceId},
  );

  final data = res.data;
  if (data is! Map || data['url'] is! String) {
    throw Exception('Checkout session could not be created');
  }
  await _launchExternalUrl(data['url'] as String);
}

Future<void> cancelSubscription() async {
  final user = _supabase.auth.currentUser;
  if (user == null) {
    throw Exception('User not signed in');
  }

  final res = await _supabase.functions.invoke('cancel_subscription');

  final data = res.data;
  if (data is! Map) {
    throw Exception('Failed to cancel subscription');
  }

  if (data['error'] != null) {
    throw Exception(data['error']);
  }
}

class PricingPage extends StatefulWidget {
  const PricingPage({super.key});

  @override
  State<PricingPage> createState() => _PricingPageState();
}

class _PricingPageState extends State<PricingPage> {
  Map<String, dynamic>? _currentSubscription;
  bool _isLoading = true;
  bool _isManagingBilling = false;
  bool _isCancelling = false;
  int _loadRequestToken = 0;

  @override
  void initState() {
    super.initState();
    _loadSubscription();
  }

  Future<void> _loadSubscription() async {
    final int requestToken = ++_loadRequestToken;
    if (!mounted) return;

    setState(() => _isLoading = true);

    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        if (!mounted || requestToken != _loadRequestToken) return;
        setState(() {
          _currentSubscription = null;
          _isLoading = false;
        });
        return;
      }

      // Sync subscription from Stripe first
      try {
        await _supabase.functions.invoke('sync_subscription');
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Sync error (not critical): $e');
        }
      }

      final response = await _supabase
          .from('profiles')
          .select(
            'is_subscribed, subscription_status, subscription_price_id, subscription_amount, current_period_end, cancel_at_period_end',
          )
          .eq('id', user.id)
          .single();

      if (!mounted || requestToken != _loadRequestToken) return;
      setState(() {
        _currentSubscription = response;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || requestToken != _loadRequestToken) return;
      setState(() => _isLoading = false);
      if (kDebugMode) {
        debugPrint('Error loading subscription: $e');
      }
    }
  }

  Future<void> _manageBilling() async {
    final user = _supabase.auth.currentUser;
    if (user == null || _isManagingBilling) return;

    setState(() => _isManagingBilling = true);
    try {
      final res = await _supabase.functions.invoke('manage_billing');
      final data = res.data;
      if (data is! Map || data['url'] is! String) {
        throw Exception('Billing portal could not be created');
      }
      await _launchExternalUrl(data['url'] as String);

      // Wait a bit and then refresh to get updated subscription status
      Future.delayed(Duration(seconds: 3), () {
        if (mounted) _loadSubscription();
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Error opening billing portal: $error',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isManagingBilling = false);
      }
    }
  }

  Future<void> _handleCancelSubscription() async {
    if (_isCancelling) return;

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Subscription'),
        content: const Text(
          'Are you sure you want to cancel your subscription? '
          'You will retain access until the end of your current billing period.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep Subscription'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Cancel Subscription'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isCancelling = true);
    try {
      await cancelSubscription();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Subscription will be cancelled at the end of the billing period',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );

      await _loadSubscription();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Error cancelling subscription: $error',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          duration: const Duration(seconds: 2),
          dismissDirection: DismissDirection.horizontal,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isCancelling = false);
      }
    }
  }

  String _getCurrentPlanName() {
    final priceId = _currentSubscription?['subscription_price_id'] as String?;
    if (priceId == null) return 'Free';
    return _plans[priceId]?['name'] ?? 'Unknown';
  }

  int _getCurrentPlanPrice() {
    final priceId = _currentSubscription?['subscription_price_id'] as String?;
    if (priceId == null) return 0;
    return _plans[priceId]?['price'] ?? 0;
  }

  bool _isCurrentPlan(String priceId) {
    final currentPriceId =
        _currentSubscription?['subscription_price_id'] as String?;
    return currentPriceId == priceId;
  }

  bool _isUpgrade(String priceId) {
    final currentPrice = _getCurrentPlanPrice();
    final newPrice = _plans[priceId]?['price'] ?? 0;
    return newPrice > currentPrice;
  }

  bool _isDowngrade(String priceId) {
    final currentPrice = _getCurrentPlanPrice();
    final newPrice = _plans[priceId]?['price'] ?? 0;
    return newPrice < currentPrice && currentPrice > 0;
  }

  double _getPlanCredits(String priceId) {
    final price = _plans[priceId]?['price'] ?? 0;
    return price * _creditMultiplier;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color accent = theme.colorScheme.primary;
    final Color iconFg = theme.resolvedIconColor;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;
    final bool isMobile = MediaQuery.of(context).size.width < 720;

    if (_isLoading) {
      return Scaffold(
        backgroundColor: scaffoldBg,
        appBar: AppBar(
          title: Text('Subscription', style: titleTextStyle),
          backgroundColor: scaffoldBg,
          elevation: 0,
          iconTheme: IconThemeData(color: iconFg),
        ),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final isSubscribed = _currentSubscription?['is_subscribed'] == true;
    final willCancel = _currentSubscription?['cancel_at_period_end'] == true;
    final currentPlanName = _getCurrentPlanName();
    final double currentPlanCredits =
        _currentSubscription?['subscription_price_id'] is String
        ? _getPlanCredits(
            _currentSubscription!['subscription_price_id'] as String,
          )
        : 0.0;
    final List<MapEntry<String, Map<String, dynamic>>> planEntries = _plans
        .entries
        .toList();

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
            const CreditDisplay(),
            const SizedBox(height: 24),
            // Current Plan Card
            if (isSubscribed)
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
                      currentPlanName,
                      style: TextStyle(
                        color: iconFg,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '€${_getCurrentPlanPrice()}/month',
                      style: TextStyle(
                        color: iconFg.withValues(alpha: 0.7),
                        fontSize: 18,
                      ),
                    ),
                    if (_currentSubscription?['current_period_end'] !=
                        null) ...[
                      const SizedBox(height: 12),
                      if (willCancel)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.orange),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.warning_amber,
                                color: Colors.orange,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Subscription Ending',
                                      style: TextStyle(
                                        color: Colors.orange,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Cancels on: ${_formatDate(_currentSubscription!['current_period_end'])}',
                                      style: TextStyle(
                                        color: iconFg.withValues(alpha: 0.8),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        Text(
                          'Renews on: ${_formatDate(_currentSubscription!['current_period_end'])}',
                          style: TextStyle(
                            color: iconFg.withValues(alpha: 0.6),
                            fontSize: 14,
                          ),
                        ),
                    ],
                    if (currentPlanCredits > 0) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Monthly AI credits: €${currentPlanCredits.toStringAsFixed(2)} (90% of your plan)',
                        style: TextStyle(
                          color: iconFg.withValues(alpha: 0.7),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    if (!isMobile) ...[
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _isManagingBilling
                                  ? null
                                  : _manageBilling,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: accent,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: _isManagingBilling
                                  ? SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                              Colors.white,
                                            ),
                                      ),
                                    )
                                  : const Icon(Icons.credit_card),
                              label: Text(
                                _isManagingBilling
                                    ? 'Opening...'
                                    : 'Manage Billing',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          if (!willCancel) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _isCancelling
                                    ? null
                                    : _handleCancelSubscription,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.red,
                                  side: BorderSide(color: Colors.red),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                icon: _isCancelling
                                    ? SizedBox(
                                        height: 18,
                                        width: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                Colors.red,
                                              ),
                                        ),
                                      )
                                    : const Icon(Icons.cancel_outlined),
                                label: Text(
                                  _isCancelling
                                      ? 'Cancelling...'
                                      : 'Cancel Plan',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: accent.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, color: accent, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                willCancel
                                    ? 'Your subscription is set to cancel. You can renew it in the billing portal.'
                                    : 'Use the billing portal to change your plan or manage payment methods.',
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

            // Plans Header
            Text(
              isSubscribed ? 'Available Plans' : 'Choose a Plan',
              style: TextStyle(
                color: iconFg,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (isSubscribed && !isMobile) ...[
              Text(
                'Click on a plan card to upgrade or downgrade your subscription.',
                style: TextStyle(color: iconFg.withValues(alpha: 0.7), fontSize: 14),
              ),
            ],
            const SizedBox(height: 16),
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
                        'Subscription management is only available on desktop. '
                        'Plan details and credits are shown below.',
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

            // Plan Cards
            if (isMobile)
              Column(
                children: planEntries.map((entry) {
                  final priceId = entry.key;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16.0),
                    child: _PlanCard(
                      priceId: priceId,
                      name: entry.value['name'],
                      price: entry.value['price'],
                      features: List<String>.from(entry.value['features']),
                      creditValue: _getPlanCredits(priceId),
                      isCurrentPlan: _isCurrentPlan(priceId),
                      isUpgrade: _isUpgrade(priceId),
                      isDowngrade: _isDowngrade(priceId),
                      isSubscribed: isSubscribed,
                      actionsEnabled: !isMobile,
                      accent: accent,
                      iconFg: iconFg,
                      scaffoldBg: scaffoldBg,
                      onChanged: _loadSubscription,
                    ),
                  );
                }).toList(),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: List.generate(planEntries.length, (index) {
                  final entry = planEntries[index];
                  final priceId = entry.key;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: index == planEntries.length - 1 ? 0 : 16.0,
                      ),
                      child: _PlanCard(
                        priceId: priceId,
                        name: entry.value['name'],
                        price: entry.value['price'],
                        features: List<String>.from(entry.value['features']),
                        creditValue: _getPlanCredits(priceId),
                        isCurrentPlan: _isCurrentPlan(priceId),
                        isUpgrade: _isUpgrade(priceId),
                        isDowngrade: _isDowngrade(priceId),
                        isSubscribed: isSubscribed,
                        actionsEnabled: !isMobile,
                        accent: accent,
                        iconFg: iconFg,
                        scaffoldBg: scaffoldBg,
                        onChanged: _loadSubscription,
                      ),
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDate(String dateString) {
    try {
      final date = DateTime.parse(dateString);
      return '${date.day}.${date.month}.${date.year}';
    } catch (e) {
      return dateString;
    }
  }
}

class _PlanCard extends StatefulWidget {
  final String priceId;
  final String name;
  final int price;
  final List<String> features;
  final double creditValue;
  final bool isCurrentPlan;
  final bool isUpgrade;
  final bool isDowngrade;
  final bool isSubscribed;
  final bool actionsEnabled;
  final Color accent;
  final Color iconFg;
  final Color scaffoldBg;
  final VoidCallback onChanged;

  const _PlanCard({
    required this.priceId,
    required this.name,
    required this.price,
    required this.features,
    required this.creditValue,
    required this.isCurrentPlan,
    required this.isUpgrade,
    required this.isDowngrade,
    required this.isSubscribed,
    required this.actionsEnabled,
    required this.accent,
    required this.iconFg,
    required this.scaffoldBg,
    required this.onChanged,
  });

  @override
  State<_PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<_PlanCard> {
  bool _isLoading = false;

  Future<void> _handleAction() async {
    if (_isLoading || !widget.actionsEnabled) return;

    // If user already has a subscription, open billing portal for upgrades/downgrades
    if (widget.isSubscribed) {
      setState(() => _isLoading = true);
      try {
        final res = await _supabase.functions.invoke('manage_billing');
        final data = res.data;
        if (data is! Map || data['url'] is! String) {
          throw Exception('Billing portal could not be created');
        }
        await _launchExternalUrl(data['url'] as String);

        // Wait and refresh
        Future.delayed(Duration(seconds: 3), () {
          if (mounted) widget.onChanged();
        });
      } catch (error) {
        if (!mounted) return;
        _showError(error);
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
      return;
    }

    // New user - go to checkout
    setState(() => _isLoading = true);
    try {
      await startCheckout(widget.priceId);
      Future.delayed(Duration(seconds: 2), () {
        if (mounted) widget.onChanged();
      });
    } catch (error) {
      if (!mounted) return;
      _showError(error);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(dynamic error) {
    final String message = error is Exception
        ? error.toString().replaceFirst('Exception: ', '')
        : 'Unexpected error';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Error: $message',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        duration: const Duration(seconds: 2),
        dismissDirection: DismissDirection.horizontal,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool showActions = widget.actionsEnabled;
    final bool isCurrentPlan = widget.isCurrentPlan;
    final bool isSubscribed = widget.isSubscribed;
    final bool isCurrentPlanAndSubscribed = isCurrentPlan && isSubscribed;

    String buttonText = 'Subscribe';

    if (isCurrentPlanAndSubscribed) {
      buttonText = 'Manage Billing';
    } else if (isCurrentPlan) {
      buttonText = 'Current Plan';
    } else if (isSubscribed) {
      if (widget.isUpgrade) {
        buttonText = 'Upgrade';
      } else if (widget.isDowngrade) {
        buttonText = 'Downgrade';
      }
    }

    final bool canPressButton =
        showActions && (!isCurrentPlan || isSubscribed) && !_isLoading;
    final Color neutralButtonBg = widget.scaffoldBg.lighten(0.1);
    final Color buttonBackground = isCurrentPlanAndSubscribed
        ? widget.accent
        : (isCurrentPlan ? neutralButtonBg : widget.accent);
    final Color buttonForeground = isCurrentPlanAndSubscribed
        ? Colors.white
        : (isCurrentPlan ? widget.iconFg : Colors.white);
    final BorderSide? buttonBorder =
        isCurrentPlan && !isCurrentPlanAndSubscribed
        ? BorderSide(color: widget.iconFg.withValues(alpha: 0.3))
        : null;

    return Card(
      elevation: widget.isCurrentPlan ? 8 : 4,
      shadowColor: Colors.black.withValues(alpha: 0.1),
      color: widget.scaffoldBg.lighten(0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: widget.isCurrentPlan
              ? widget.accent
              : widget.iconFg.withValues(alpha: 0.3),
          width: widget.isCurrentPlan ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 28,
              child: widget.isCurrentPlan
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: widget.accent,
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
                    )
                  : widget.isUpgrade && widget.isSubscribed
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.2),
                          border: Border.all(color: Colors.green),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          'UPGRADE',
                          style: TextStyle(
                            color: Colors.green,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 12),
            Text(
              widget.name,
              style: TextStyle(
                color: widget.iconFg,
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
                    color: widget.accent,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  widget.price.toString(),
                  style: TextStyle(
                    color: widget.accent,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '/month',
                  style: TextStyle(
                    color: widget.iconFg.withValues(alpha: 0.7),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...widget.features.map(
              (feature) => Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: widget.accent, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        feature,
                        style: TextStyle(
                          color: widget.iconFg.withValues(alpha: 0.8),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Monthly AI credits: €${widget.creditValue.toStringAsFixed(2)}',
              style: TextStyle(
                color: widget.iconFg,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '90% of your subscription is converted to spendable credits.',
              style: TextStyle(
                color: widget.iconFg.withValues(alpha: 0.7),
                fontSize: 12,
              ),
            ),
            if (showActions) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: canPressButton ? _handleAction : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: buttonBackground,
                    foregroundColor: buttonForeground,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    side: buttonBorder,
                    elevation: widget.isCurrentPlan ? 2 : 4,
                  ),
                  child: _isLoading
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              buttonForeground,
                            ),
                          ),
                        )
                      : Text(
                          buttonText,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                ),
              ),
            ] else ...[
              const SizedBox(height: 16),
              Text(
                'Manage your subscription from a desktop device.',
                style: TextStyle(
                  color: widget.iconFg.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
