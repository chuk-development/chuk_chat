/// The cloud computer add-on's billing actions (CHAT-164): book it later,
/// change its size, cancel it.
///
/// * **Book**: a sheet with the sizes, the monthly price and the note that
///   the rest of the period is charged pro rata now. 402 (no subscription)
///   closes the sheet and opens the checkout with the add-on pre-selected.
///   After a booking the user status is read again, so the zero-click setup
///   (`cloud_box_included`) takes over.
/// * **Change size**: bigger takes effect now (pro rata, one short restart),
///   smaller at the end of the billing period. 409 `does_not_fit` says the
///   data would not fit.
/// * **Cancel**: a confirm dialog; the add-on ends at period end, the data is
///   backed up and kept 90 days.
/// * **Payment**: book and resize charge at once. 402
///   `payment_action_required` opens the Stripe invoice page (3-D Secure) and
///   the sheet says to confirm the payment there; the webhook books the
///   change once it is paid. 402 `payment_failed` shows a message and a
///   button to the billing portal.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/pricing_page.dart'
    show PricingPage, openBillingPortal, openCloudBoxPaymentPage;
import 'package:chuk_chat/services/agents/agents_cloud_box_api.dart';
import 'package:chuk_chat/services/agents_plans.dart';
import 'package:chuk_chat/services/user_status_service.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/agents_cloud_box_addon.dart';
import 'package:chuk_chat/widgets/app_notification.dart';

/// Opens the checkout with the add-on in [size] pre-selected.
typedef CloudBoxCheckoutOpener = Future<void> Function(
  BuildContext context,
  String size,
);

/// Runs after a booking, a size change or a cancellation.
typedef CloudBoxChanged = Future<void> Function();

/// Opens a payment page (the Stripe invoice for a 3-D Secure confirmation).
typedef CloudBoxUrlOpener = Future<void> Function(String url);

/// Opens the billing portal (payment details).
typedef CloudBoxPortalOpener = Future<void> Function();

/// The default checkout path: the pricing page with the add-on pre-selected.
Future<void> openCloudBoxCheckout(BuildContext context, String size) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => PricingPage(initialCloudBoxSize: size),
    ),
  );
}

/// The default after-change step: read the user status again, so the shell
/// sees `cloud_box_included` and the zero-click setup starts.
Future<void> refreshStatusAfterCloudBoxChange() async {
  try {
    await UserStatusService.refresh();
  } catch (error) {
    if (kDebugMode) {
      debugPrint('cloud box: status refresh failed (${error.runtimeType})');
    }
  }
}

AppLocalizations _l(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

/// The sizes to offer: the server's list, else the built-in defaults.
List<AgentsCloudBoxSize> _sizesOr(List<AgentsCloudBoxSize>? sizes) =>
    sizes == null || sizes.isEmpty ? kAgentsCloudBoxSizeDefaults : sizes;

// ─── Book ──────────────────────────────────────────────────────────────────

sealed class _BookOutcome {
  const _BookOutcome();
}

class _Booked extends _BookOutcome {
  const _Booked();
}

class _NeedsCheckout extends _BookOutcome {
  const _NeedsCheckout(this.size);
  final String size;
}

/// Opens the "book a cloud computer" sheet. Completes with true when the
/// add-on was booked.
Future<bool> showCloudBoxBookSheet(
  BuildContext context, {
  AgentsCloudBoxBillingApi? api,
  List<AgentsCloudBoxSize>? sizes,
  CloudBoxCheckoutOpener? openCheckout,
  CloudBoxChanged? onBooked,
  CloudBoxUrlOpener? openPaymentPage,
  CloudBoxPortalOpener? openPortal,
}) async {
  final AppLocalizations l = _l(context);
  final _BookOutcome? outcome = await expressiveSheet<_BookOutcome>(
    context,
    title: l.cloudBoxBook,
    child: CloudBoxBookSheet(
      api: api ?? HttpAgentsCloudBoxApi.instance,
      sizes: _sizesOr(sizes),
      openPaymentPage: openPaymentPage,
      openPortal: openPortal,
    ),
  );
  if (!context.mounted) return false;
  switch (outcome) {
    case _Booked():
      AppNotifications.show(context, l.cloudBoxBooked);
      await (onBooked ?? refreshStatusAfterCloudBoxChange)();
      return true;
    case _NeedsCheckout(:final String size):
      AppNotifications.show(context, l.cloudBoxNeedsPlan);
      await (openCheckout ?? openCloudBoxCheckout)(context, size);
      return false;
    case null:
      return false;
  }
}

/// The body of the book sheet. Public for tests.
class CloudBoxBookSheet extends StatefulWidget {
  const CloudBoxBookSheet({
    super.key,
    required this.api,
    required this.sizes,
    this.openPaymentPage,
    this.openPortal,
  });

  final AgentsCloudBoxBillingApi api;
  final List<AgentsCloudBoxSize> sizes;

  /// Null = the browser ([openCloudBoxPaymentPage]).
  final CloudBoxUrlOpener? openPaymentPage;

  /// Null = [openBillingPortal].
  final CloudBoxPortalOpener? openPortal;

  static const ValueKey<String> confirmKey = ValueKey<String>(
    'cloud-box-book-confirm',
  );
  static const ValueKey<String> errorKey = ValueKey<String>(
    'cloud-box-book-error',
  );

  @override
  State<CloudBoxBookSheet> createState() => _CloudBoxBookSheetState();
}

class _CloudBoxBookSheetState extends State<CloudBoxBookSheet>
    with _CloudBoxPaymentState<CloudBoxBookSheet> {
  late AgentsCloudBoxSize _selected = defaultCloudBoxSize(widget.sizes);
  bool _busy = false;
  String? _error;

  @override
  CloudBoxUrlOpener? get _openPaymentPage => widget.openPaymentPage;

  @override
  CloudBoxPortalOpener? get _openPortal => widget.openPortal;

  Future<void> _book() async {
    if (_busy) return;
    final AppLocalizations l = _l(context);
    setState(() {
      _busy = true;
      _error = null;
      _paymentFailed = false;
    });
    try {
      await widget.api.book(_selected.id);
      if (!mounted) return;
      Navigator.of(context).pop(const _Booked());
    } on AgentsCloudBoxException catch (error) {
      if (!mounted) return;
      if (error.noPlan) {
        Navigator.of(context).pop(_NeedsCheckout(_selected.id));
        return;
      }
      if (_takePaymentError(error)) {
        setState(() => _busy = false);
        return;
      }
      setState(() {
        _busy = false;
        _error = error.alreadyBooked
            ? l.cloudBoxAlreadyBooked
            : l.cloudBoxActionFailed;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l.cloudBoxActionFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = _l(context);
    final String price = formatEuroAmount(
      _selected.priceEur,
      l.locale.languageCode,
    );
    return _SheetBody(
      picker: AgentsCloudBoxSizePicker(
        sizes: widget.sizes,
        selectedId: _selected.id,
        onSelected: _busy || _invoiceUrl != null
            ? null
            : (s) => setState(() => _selected = s),
      ),
      note: _invoiceUrl != null
          ? l.cloudBoxConfirmPaymentNote
          : <String>[
              l.cloudBoxBookTerms(price),
              ?cloudBoxSetupFeeText(l, _selected),
            ].join('\n'),
      noteKey: _invoiceUrl != null ? cloudBoxPaymentNoteKey : null,
      error: _paymentFailed ? l.cloudBoxPaymentFailed : _error,
      errorKey: CloudBoxBookSheet.errorKey,
      help: _portalButton(l),
      busy: _busy,
      confirm:
          _confirmPaymentButton(l) ??
          ExpressiveButton(
            key: CloudBoxBookSheet.confirmKey,
            icon: Icons.cloud_outlined,
            label: l.cloudBoxBookConfirm(price),
            onTap: () => unawaited(_book()),
          ),
    );
  }
}

// ─── Change size ───────────────────────────────────────────────────────────

/// Whether moving from [from] to [to] is an upgrade (takes effect now).
bool cloudBoxIsUpgrade(AgentsCloudBoxSize? from, AgentsCloudBoxSize to) =>
    from == null || to.priceEur > from.priceEur;

/// Opens the "change size" sheet. Completes with true when the server took
/// the change.
Future<bool> showCloudBoxResizeSheet(
  BuildContext context, {
  required AgentsCloudBoxStatus status,
  AgentsCloudBoxBillingApi? api,
  List<AgentsCloudBoxSize>? sizes,
  CloudBoxChanged? onChanged,
  CloudBoxUrlOpener? openPaymentPage,
  CloudBoxPortalOpener? openPortal,
}) async {
  final AppLocalizations l = _l(context);
  final List<AgentsCloudBoxSize> offered = _sizesOr(
    status.sizesAvailable.isNotEmpty ? status.sizesAvailable : sizes,
  );
  final bool? upgraded = await expressiveSheet<bool>(
    context,
    title: l.cloudBoxChangeSize,
    child: CloudBoxResizeSheet(
      api: api ?? HttpAgentsCloudBoxApi.instance,
      sizes: offered,
      currentId: status.size,
      openPaymentPage: openPaymentPage,
      openPortal: openPortal,
    ),
  );
  if (!context.mounted || upgraded == null) return false;
  AppNotifications.show(
    context,
    upgraded ? l.cloudBoxResized : l.cloudBoxResizeScheduled,
  );
  await (onChanged ?? refreshStatusAfterCloudBoxChange)();
  return true;
}

/// The body of the change-size sheet. Pops true for an upgrade (now), false
/// for a downgrade (period end). Public for tests.
class CloudBoxResizeSheet extends StatefulWidget {
  const CloudBoxResizeSheet({
    super.key,
    required this.api,
    required this.sizes,
    required this.currentId,
    this.openPaymentPage,
    this.openPortal,
  });

  final AgentsCloudBoxBillingApi api;
  final List<AgentsCloudBoxSize> sizes;
  final String? currentId;

  /// Null = the browser ([openCloudBoxPaymentPage]).
  final CloudBoxUrlOpener? openPaymentPage;

  /// Null = [openBillingPortal].
  final CloudBoxPortalOpener? openPortal;

  static const ValueKey<String> confirmKey = ValueKey<String>(
    'cloud-box-resize-confirm',
  );
  static const ValueKey<String> noteKey = ValueKey<String>(
    'cloud-box-resize-note',
  );
  static const ValueKey<String> errorKey = ValueKey<String>(
    'cloud-box-resize-error',
  );

  @override
  State<CloudBoxResizeSheet> createState() => _CloudBoxResizeSheetState();
}

class _CloudBoxResizeSheetState extends State<CloudBoxResizeSheet>
    with _CloudBoxPaymentState<CloudBoxResizeSheet> {
  late String? _selectedId = widget.currentId;
  bool _busy = false;
  String? _error;

  @override
  CloudBoxUrlOpener? get _openPaymentPage => widget.openPaymentPage;

  @override
  CloudBoxPortalOpener? get _openPortal => widget.openPortal;

  AgentsCloudBoxSize? get _current =>
      cloudBoxSizeById(widget.sizes, widget.currentId) ??
      cloudBoxSizeById(kAgentsCloudBoxSizeDefaults, widget.currentId);

  AgentsCloudBoxSize? get _selected =>
      cloudBoxSizeById(widget.sizes, _selectedId);

  Future<void> _resize(AgentsCloudBoxSize target) async {
    if (_busy) return;
    final AppLocalizations l = _l(context);
    final bool upgrade = cloudBoxIsUpgrade(_current, target);
    setState(() {
      _busy = true;
      _error = null;
      _paymentFailed = false;
    });
    try {
      await widget.api.resize(target.id);
      if (!mounted) return;
      Navigator.of(context).pop(upgrade);
    } on AgentsCloudBoxException catch (error) {
      if (!mounted) return;
      if (_takePaymentError(error)) {
        setState(() => _busy = false);
        return;
      }
      setState(() {
        _busy = false;
        _error = error.doesNotFit
            ? l.cloudBoxDoesNotFit
            : error.noPlan
            ? l.cloudBoxNoSubscription
            : l.cloudBoxActionFailed;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l.cloudBoxActionFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = _l(context);
    final AgentsCloudBoxSize? target = _selected;
    final bool changed = target != null && target.id != widget.currentId;
    return _SheetBody(
      picker: AgentsCloudBoxSizePicker(
        sizes: widget.sizes,
        selectedId: _selectedId,
        currentId: widget.currentId,
        onSelected: _busy || _invoiceUrl != null
            ? null
            : (s) => setState(() => _selectedId = s.id),
      ),
      note: _invoiceUrl != null
          ? l.cloudBoxConfirmPaymentNote
          : changed
          ? (cloudBoxIsUpgrade(_current, target)
                ? l.cloudBoxUpgradeNote
                : l.cloudBoxDowngradeNote)
          : null,
      noteKey: _invoiceUrl != null
          ? cloudBoxPaymentNoteKey
          : CloudBoxResizeSheet.noteKey,
      error: _paymentFailed ? l.cloudBoxPaymentFailed : _error,
      errorKey: CloudBoxResizeSheet.errorKey,
      help: _portalButton(l),
      busy: _busy,
      confirm:
          _confirmPaymentButton(l) ??
          (changed
              ? ExpressiveButton(
                  key: CloudBoxResizeSheet.confirmKey,
                  icon: Icons.tune,
                  label: l.cloudBoxResizeConfirm(target.label),
                  onTap: () => unawaited(_resize(target)),
                )
              : null),
    );
  }
}

// ─── Cancel ────────────────────────────────────────────────────────────────

/// Asks first, then cancels the add-on at period end. Completes with true
/// when the server took the cancellation.
Future<bool> confirmCloudBoxCancel(
  BuildContext context, {
  AgentsCloudBoxBillingApi? api,
  CloudBoxChanged? onChanged,
}) async {
  final AppLocalizations l = _l(context);
  final bool? yes = await showDialog<bool>(
    context: context,
    builder: (_) => const CloudBoxCancelDialog(),
  );
  if (yes != true || !context.mounted) return false;
  try {
    await (api ?? HttpAgentsCloudBoxApi.instance).cancel();
  } on AgentsCloudBoxException catch (error) {
    if (!context.mounted) return false;
    AppNotifications.show(
      context,
      error.noPlan ? l.cloudBoxNoSubscription : l.cloudBoxActionFailed,
      kind: AppNotificationKind.error,
    );
    return false;
  } catch (_) {
    if (!context.mounted) return false;
    AppNotifications.show(
      context,
      l.cloudBoxActionFailed,
      kind: AppNotificationKind.error,
    );
    return false;
  }
  if (!context.mounted) return true;
  AppNotifications.show(context, l.cloudBoxCancelled);
  await (onChanged ?? refreshStatusAfterCloudBoxChange)();
  return true;
}

class CloudBoxCancelDialog extends StatelessWidget {
  const CloudBoxCancelDialog({super.key});

  static const ValueKey<String> keepKey = ValueKey<String>(
    'cloud-box-cancel-keep',
  );
  static const ValueKey<String> confirmKey = ValueKey<String>(
    'cloud-box-cancel-confirm',
  );

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = _l(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(l.cloudBoxCancelTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(l.cloudBoxCancelBody),
      ),
      actions: <Widget>[
        TextButton(
          key: keepKey,
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.cloudBoxKeep),
        ),
        TextButton(
          key: confirmKey,
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          child: Text(l.cloudBoxCancelConfirm),
        ),
      ],
    );
  }
}

// ─── Shared ────────────────────────────────────────────────────────────────

/// The note shown while a payment waits for the bank's confirmation.
const ValueKey<String> cloudBoxPaymentNoteKey = ValueKey<String>(
  'cloud-box-payment-note',
);

/// The button that opens the payment page again.
const ValueKey<String> cloudBoxConfirmPaymentKey = ValueKey<String>(
  'cloud-box-confirm-payment',
);

/// The button to the billing portal after a declined payment.
const ValueKey<String> cloudBoxPaymentDetailsKey = ValueKey<String>(
  'cloud-box-payment-details',
);

/// The 402 handling the book and resize sheets share.
mixin _CloudBoxPaymentState<T extends StatefulWidget> on State<T> {
  /// Set while the bank wants a confirmation: the Stripe invoice page.
  String? _invoiceUrl;

  /// The last charge was declined.
  bool _paymentFailed = false;

  CloudBoxUrlOpener? get _openPaymentPage;
  CloudBoxPortalOpener? get _openPortal;

  /// Takes a 402 payment error. True when it was one.
  bool _takePaymentError(AgentsCloudBoxException error) {
    if (error.paymentActionRequired) {
      _invoiceUrl = error.hostedInvoiceUrl;
      _paymentFailed = false;
      unawaited(_openInvoice());
      return true;
    }
    if (error.paymentFailed) {
      _paymentFailed = true;
      return true;
    }
    return false;
  }

  Future<void> _openInvoice() async {
    final String? url = _invoiceUrl;
    if (url == null) return;
    try {
      await (_openPaymentPage ?? openCloudBoxPaymentPage)(url);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('cloud box: payment page failed (${error.runtimeType})');
      }
      if (!mounted) return;
      AppNotifications.show(
        context,
        _l(context).cloudBoxActionFailed,
        kind: AppNotificationKind.error,
      );
    }
  }

  Future<void> _openPaymentDetails() async {
    try {
      await (_openPortal ?? openBillingPortal)();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('cloud box: billing portal failed (${error.runtimeType})');
      }
      if (!mounted) return;
      AppNotifications.show(
        context,
        _l(context).cloudBoxActionFailed,
        kind: AppNotificationKind.error,
      );
    }
  }

  /// "Confirm payment", while a confirmation is open. Null otherwise.
  Widget? _confirmPaymentButton(AppLocalizations l) => _invoiceUrl == null
      ? null
      : ExpressiveButton(
          key: cloudBoxConfirmPaymentKey,
          icon: Icons.open_in_new,
          label: l.cloudBoxConfirmPayment,
          onTap: () => unawaited(_openInvoice()),
        );

  /// "Payment details", after a declined payment. Null otherwise.
  Widget? _portalButton(AppLocalizations l) => !_paymentFailed
      ? null
      : ExpressiveButton(
          key: cloudBoxPaymentDetailsKey,
          icon: Icons.credit_card,
          label: l.cloudBoxPaymentDetails,
          tonal: true,
          dense: true,
          onTap: () => unawaited(_openPaymentDetails()),
        );
}

/// Picker, note, error and the one confirm button, in the sheet's order.
class _SheetBody extends StatelessWidget {
  const _SheetBody({
    required this.picker,
    required this.busy,
    this.note,
    this.noteKey,
    this.error,
    this.errorKey,
    this.help,
    this.confirm,
  });

  final Widget picker;
  final String? note;
  final Key? noteKey;
  final String? error;
  final Key? errorKey;

  /// A secondary action under the error (e.g. "Payment details").
  final Widget? help;
  final bool busy;
  final Widget? confirm;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            picker,
            if (note case final String note) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                note,
                key: noteKey,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (error case final String error) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                error,
                key: errorKey,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.error,
                ),
              ),
            ],
            if (help case final Widget help) ...<Widget>[
              const SizedBox(height: 12),
              Align(alignment: AlignmentDirectional.centerStart, child: help),
            ],
            if (busy || confirm != null) ...<Widget>[
              const SizedBox(height: 20),
              Center(child: busy ? const ExpressiveLoader(size: 40) : confirm),
            ],
          ],
        ),
      ),
    );
  }
}
