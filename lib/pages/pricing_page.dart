import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/widgets/credit_display.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;
import 'package:url_launcher/url_launcher_string.dart';

final SupabaseClient _supabase = Supabase.instance.client;

// Price IDs from your Stripe dashboard
const Map<String, Map<String, dynamic>> _plans = {
  'price_1SHRmD4RznxB1MLdyNEhp4On': {
    'name': 'Starter',
    'price': 10,
    'features': ['Image Generation', 'Voice Mode', 'Text Chat', 'Basic Support'],
  },
  'price_1SHRnc4RznxB1MLdckKKLgvg': {
    'name': 'Plus',
    'price': 20,
    'features': ['Image Generation', 'Voice Mode', 'Text Chat', 'Priority Support', 'Extended Features'],
  },
  'price_1SHRo84RznxB1MLdixi99wLf': {
    'name': 'Pro',
    'price': 40,
    'features': ['Image Generation', 'Voice Mode', 'Text Chat', 'Premium Support', 'Advanced Features', 'API Access'],
  },
};

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
  final url = data['url'] as String;
  await launchUrlString(url, mode: LaunchMode.externalApplication);
}

class PricingPage extends StatefulWidget {
  const PricingPage({super.key});

  @override
  State<PricingPage> createState() => _PricingPageState();
}

class _PricingPageState extends State<PricingPage> {
  Map<String, dynamic>? _currentSubscription;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSubscription();
  }

  Future<void> _loadSubscription() async {
    setState(() => _isLoading = true);
    
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;

      // Sync subscription from Stripe first
      try {
        await _supabase.functions.invoke('sync_subscription');
      } catch (e) {
        print('Sync error (not critical): $e');
      }

      final response = await _supabase
          .from('profiles')
          .select('is_subscribed, subscription_status, subscription_price_id, subscription_amount, current_period_end')
          .eq('id', user.id)
          .single();

      setState(() {
        _currentSubscription = response;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      print('Error loading subscription: $e');
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
    final currentPriceId = _currentSubscription?['subscription_price_id'] as String?;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color accent = theme.colorScheme.primary;
    final Color iconFg = theme.iconTheme.color!;
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
    final currentPlanName = _getCurrentPlanName();

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
                    if (_currentSubscription?['current_period_end'] != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Renews on: ${_formatDate(_currentSubscription!['current_period_end'])}',
                        style: TextStyle(
                          color: iconFg.withValues(alpha: 0.6),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 32),

            // Plans Header
            Text(
              isSubscribed ? 'Change Plan' : 'Choose a Plan',
              style: TextStyle(
                color: iconFg,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),

            // Plan Cards
            if (isMobile)
              Column(
                children: _plans.entries.map((entry) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16.0),
                    child: _PlanCard(
                      priceId: entry.key,
                      name: entry.value['name'],
                      price: entry.value['price'],
                      features: List<String>.from(entry.value['features']),
                      isCurrentPlan: _isCurrentPlan(entry.key),
                      isUpgrade: _isUpgrade(entry.key),
                      isDowngrade: _isDowngrade(entry.key),
                      accent: accent,
                      iconFg: iconFg,
                      scaffoldBg: scaffoldBg,
                      currentPlanPrice: _getCurrentPlanPrice(),
                      onChanged: _loadSubscription,
                    ),
                  );
                }).toList(),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _plans.entries.map((entry) {
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16.0),
                      child: _PlanCard(
                        priceId: entry.key,
                        name: entry.value['name'],
                        price: entry.value['price'],
                      features: List<String>.from(entry.value['features']),
                      isCurrentPlan: _isCurrentPlan(entry.key),
                      isUpgrade: _isUpgrade(entry.key),
                      isDowngrade: _isDowngrade(entry.key),
                      accent: accent,
                      iconFg: iconFg,
                      scaffoldBg: scaffoldBg,
                      currentPlanPrice: _getCurrentPlanPrice(),
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
  final bool isCurrentPlan;
  final bool isUpgrade;
  final bool isDowngrade;
  final Color accent;
  final Color iconFg;
  final Color scaffoldBg;
  final int currentPlanPrice;
  final VoidCallback onChanged;

  const _PlanCard({
    required this.priceId,
    required this.name,
    required this.price,
    required this.features,
    required this.isCurrentPlan,
    required this.isUpgrade,
    required this.isDowngrade,
    required this.accent,
    required this.iconFg,
    required this.scaffoldBg,
    required this.currentPlanPrice,
    required this.onChanged,
  });

  @override
  State<_PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<_PlanCard> {
  bool _isLoading = false;

  Future<void> _handleUpgrade() async {
    if (_isLoading) return;

    final currentPlanPrice = _getCurrentPlanPrice();

    // If user has no subscription, go to checkout
    if (!widget.isCurrentPlan && widget.price > 0 && currentPlanPrice == 0) {
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
      return;
    }

    // Existing subscription: upgrade or downgrade
    if (!widget.isCurrentPlan && currentPlanPrice > 0) {
      final confirmed = await _showConfirmDialog();
      if (!confirmed) return;

      setState(() => _isLoading = true);
      try {
        final res = await _supabase.functions.invoke(
          'change_subscription',
          body: {'newPriceId': widget.priceId},
        );

        if (res.data?['success'] == true) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Subscription updated successfully!'),
              backgroundColor: Colors.green,
            ),
          );
          widget.onChanged();
        } else {
          throw Exception(res.data?['error'] ?? 'Failed to update subscription');
        }
      } catch (error) {
        if (!mounted) return;
        _showError(error);
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  Future<bool> _showConfirmDialog() async {
    final String action = widget.isUpgrade ? 'upgrade' : 'downgrade';
    final String message = widget.isUpgrade
        ? 'You will be charged the prorated amount for the upgraded plan immediately.'
        : 'Your plan will be downgraded. The difference will be credited to your account.';

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Confirm ${action.toUpperCase()}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Are you sure you want to $action to ${widget.name}?'),
            const SizedBox(height: 12),
            Text(
              message,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  void _showError(dynamic error) {
    final String message = error is Exception
        ? error.toString().replaceFirst('Exception: ', '')
        : 'Unexpected error';

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Error: $message'),
        backgroundColor: Colors.red,
      ),
    );
  }

  int _getCurrentPlanPrice() {
    return widget.currentPlanPrice;
  }

  @override
  Widget build(BuildContext context) {
    String buttonText;
    if (widget.isCurrentPlan) {
      buttonText = 'Current Plan';
    } else if (widget.isUpgrade) {
      buttonText = 'Upgrade';
    } else if (widget.isDowngrade) {
      buttonText = 'Downgrade';
    } else {
      buttonText = 'Select Plan';
    }

    return Card(
      elevation: widget.isCurrentPlan ? 8 : 4,
      shadowColor: Colors.black.withValues(alpha: 0.1),
      color: widget.scaffoldBg.lighten(0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: widget.isCurrentPlan ? widget.accent : widget.iconFg.withValues(alpha: 0.3),
          width: widget.isCurrentPlan ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.isCurrentPlan)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
            if (widget.isCurrentPlan) const SizedBox(height: 12),
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
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: widget.isCurrentPlan ? null : (_isLoading ? null : _handleUpgrade),
                style: ElevatedButton.styleFrom(
                  backgroundColor: widget.isCurrentPlan 
                      ? widget.scaffoldBg.lighten(0.1) 
                      : widget.isUpgrade 
                          ? widget.accent 
                          : widget.scaffoldBg.lighten(0.1),
                  foregroundColor: widget.isUpgrade ? Colors.white : widget.iconFg,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  side: !widget.isUpgrade
                      ? BorderSide(color: widget.iconFg.withValues(alpha: 0.3))
                      : null,
                  elevation: widget.isUpgrade ? 4 : 2,
                ),
                child: _isLoading
                    ? SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            widget.isUpgrade ? Colors.white : widget.iconFg,
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
          ],
        ),
      ),
    );
  }
}
