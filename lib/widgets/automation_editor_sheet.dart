/// The create and edit sheet of an automation (docs/WIRE_CONTRACT.md, "Event
/// triggers and notify only on change"): what sets it off (a schedule, a
/// watched page, a mail filter), what the agent should do then, its name,
/// and whether every run notifies or only a run that found a change.
///
/// The sheet sends `automation_create` or `automation_update` through
/// [AutomationsSource] and waits for the host's `automation_saved`. A refusal
/// is shown in the host's own words, under the button, and the sheet stays
/// open so the user can fix the field. Nothing is saved optimistically.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_webhooks_service.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/schedule_picker.dart';

/// Opens the sheet. [existing] edits that row; otherwise a new automation is
/// created for [sessionKey], or for the agent the user picks from
/// [agents] (session key → name) when [sessionKey] is null. Completes with
/// the row the host saved, or null when the sheet was closed.
Future<AgentsAutomation?> showAutomationEditor(
  BuildContext context, {
  AgentsAutomation? existing,
  String? sessionKey,
  Map<String, String> agents = const <String, String>{},
  AutomationsSource? source,
  AgentsWebhooksService? webhooks,
}) {
  final AppLocalizations l = _l10n(context);
  return expressiveSheet<AgentsAutomation>(
    context,
    title: existing == null ? l.automationNew : l.automationEdit,
    child: AutomationEditorForm(
      existing: existing,
      sessionKey: sessionKey,
      agents: agents,
      source: source,
      webhooks: webhooks,
    ),
  );
}

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

/// The form inside the sheet. Public so a test can pump it without a sheet.
class AutomationEditorForm extends StatefulWidget {
  const AutomationEditorForm({
    super.key,
    this.existing,
    this.sessionKey,
    this.agents = const <String, String>{},
    this.source,
    this.webhooks,
    this.hostDeviceId,
  });

  final AgentsAutomation? existing;
  final String? sessionKey;
  final Map<String, String> agents;
  final AutomationsSource? source;

  /// The server half of a webhook. Defaults to
  /// [AgentsWebhooksService.instance].
  final AgentsWebhooksService? webhooks;

  /// The host's relay executor id. Defaults to the stored pairing's.
  final Future<String?> Function()? hostDeviceId;

  @override
  State<AutomationEditorForm> createState() => _AutomationEditorFormState();
}

class _AutomationEditorFormState extends State<AutomationEditorForm> {
  late final AutomationsSource _source =
      widget.source ?? AutomationsSource.instance;

  late String _kind;
  String? _agent;
  late final TextEditingController _schedule;
  late final TextEditingController _url;
  late final TextEditingController _minutes;
  late final TextEditingController _from;
  late final TextEditingController _subject;
  late final TextEditingController _alias;
  late final TextEditingController _prompt;
  late final TextEditingController _name;
  late final TextEditingController _catchUp;
  late bool _onChange;

  // ── webhooks ──
  late final TextEditingController _secret;
  late final TextEditingController _filterTarget;
  late final TextEditingController _filterValue;
  late final TextEditingController _filterJson;
  late final TextEditingController _debounce;
  late final TextEditingController _maxWait;
  String _filterPlace = 'path';
  String _filterOp = kWebhookFilterOps.first;

  /// "Remove secret" was tapped on a row that has one.
  bool _removeSecret = false;

  /// The URL of the webhook just made, shown once, and the row it belongs
  /// to. While set, the form shows only the URL.
  String? _createdUrl;
  AgentsAutomation? _createdRow;
  // ── end webhooks ──

  /// Where a fired schedule run goes (docs/WIRE_CONTRACT.md, "Schedule
  /// target").
  late String _target;

  /// Runs of this automation may set up automations ("No recursion").
  late bool _allowChaining;

  /// The field that failed the local check, and why.
  String? _fieldError;
  String? _fieldKey;

  /// The host's refusal, as it said it.
  String? _hostError;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final AgentsAutomation? a = widget.existing;
    _kind = a?.kind ?? 'schedule';
    _agent =
        widget.sessionKey ??
        (widget.agents.length == 1 ? widget.agents.keys.first : null);
    _schedule = TextEditingController(text: a?.scheduleText ?? '');
    _url = TextEditingController(text: a?.watchedUrl ?? '');
    final int seconds =
        (a != null && a.isWatchUrl ? a.everySeconds : null) ??
        kWatchUrlDefaultSeconds;
    _minutes = TextEditingController(text: '${seconds ~/ 60}');
    _from = TextEditingController(text: a?.mailFrom ?? '');
    _subject = TextEditingController(text: a?.mailSubject ?? '');
    _alias = TextEditingController(text: a?.mailAlias ?? '');
    _prompt = TextEditingController(text: a?.prompt ?? '');
    _name = TextEditingController(text: a?.name ?? '');
    _onChange = a?.notifiesOnChange ?? false;
    _target = a?.target ?? kAutomationTargetThisSession;
    _allowChaining = a?.allowChaining ?? false;
    _catchUp = TextEditingController(text: catchUpText(a?.catchUpSeconds));
    _secret = TextEditingController();
    _filterTarget = TextEditingController();
    _filterValue = TextEditingController();
    final Object? oldFilter = a != null && a.isWebhook ? a.webhookFilter : null;
    _filterJson = TextEditingController(
      text: oldFilter == null ? '' : jsonEncode(oldFilter),
    );
    _debounce = TextEditingController(
      text:
          '${a != null && a.isWebhook ? a.webhookDebounce : kWebhookDefaultDebounce}',
    );
    _maxWait = TextEditingController(
      text:
          '${a != null && a.isWebhook ? a.webhookMaxWait : kWebhookDefaultMaxWait}',
    );
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _schedule,
      _url,
      _minutes,
      _from,
      _subject,
      _alias,
      _prompt,
      _name,
      _catchUp,
      _secret,
      _filterTarget,
      _filterValue,
      _filterJson,
      _debounce,
      _maxWait,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The local checks: the ones the host would refuse anyway, said before
  /// the round trip. Returns the spec on success, null after setting the
  /// error.
  Object? _validSpec(AppLocalizations l) {
    String? fail(String key, String message) {
      setState(() {
        _fieldKey = key;
        _fieldError = message;
      });
      return null;
    }

    if (!_editing && widget.sessionKey == null && _agent == null) {
      return fail('agent', l.automationErrAgent);
    }
    switch (_kind) {
      case 'watch_url':
        final Uri? uri = Uri.tryParse(_url.text.trim());
        if (uri == null ||
            !(uri.scheme == 'http' || uri.scheme == 'https') ||
            uri.host.isEmpty) {
          return fail('url', l.automationErrUrl);
        }
        final int? minutes = int.tryParse(_minutes.text.trim());
        if (minutes == null || minutes * 60 < kWatchUrlMinSeconds) {
          return fail('minutes', l.automationErrInterval);
        }
        if (_prompt.text.trim().isEmpty) {
          return fail('prompt', l.automationErrPrompt);
        }
        return automationSpecFor(
          _kind,
          url: _url.text,
          everySeconds: minutes * 60,
        );
      case 'mail':
        final String from = _from.text.trim();
        final String subject = _subject.text.trim();
        final String? alias = normalizeMailAlias(_alias.text);
        if (alias == null) {
          return fail('alias', l.automationErrMailAlias);
        }
        if (from.isEmpty && subject.isEmpty && alias.isEmpty) {
          return fail('from', l.automationErrMail);
        }
        if (from.length > kMailFilterMaxLength) {
          return fail('from', l.automationErrTooLong);
        }
        if (subject.length > kMailFilterMaxLength) {
          return fail('subject', l.automationErrTooLong);
        }
        if (_prompt.text.trim().isEmpty) {
          return fail('prompt', l.automationErrPrompt);
        }
        return automationSpecFor(
          _kind,
          mailFrom: from,
          mailSubject: subject,
          mailAlias: alias,
        );
      case kWebhookKind:
        return _webhookFields(l, fail);
      default:
        if (_schedule.text.trim().isEmpty) {
          return fail('schedule', l.automationErrSchedule);
        }
        if (_prompt.text.trim().isEmpty) {
          return fail('prompt', l.automationErrPrompt);
        }
        return automationSpecFor(_kind, schedule: _schedule.text);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final AppLocalizations l = _l10n(context);
    setState(() {
      _fieldError = null;
      _fieldKey = null;
      _hostError = null;
    });
    final Object? spec = _validSpec(l);
    if (spec == null) return;
    final Object? catchUp;
    try {
      catchUp = parseCatchUp(_catchUp.text);
    } on FormatException {
      setState(() {
        _fieldKey = 'catch_up';
        _fieldError = l.automationErrCatchUp;
      });
      return;
    }
    if (_kind == kWebhookKind) {
      await _saveWebhook(l, spec as _WebhookFields, catchUp);
      return;
    }
    final AutomationSaveResult result;
    if (_editing) {
      final Map<String, dynamic>? frame = automationUpdateFrame(
        before: widget.existing!,
        spec: spec,
        prompt: _prompt.text,
        name: _name.text,
        notifyOnChange: _onChange,
        target: _kind == 'schedule' ? _target : null,
        allowChaining: _allowChaining,
        catchUp: catchUp,
        catchUpSet: true,
      );
      if (frame == null) {
        setState(() => _hostError = l.automationNothingChanged);
        return;
      }
      setState(() => _saving = true);
      result = await _source.update(frame);
    } else {
      setState(() => _saving = true);
      result = await _source.create(
        sessionKey: widget.sessionKey ?? _agent!,
        kind: _kind,
        spec: spec,
        prompt: _prompt.text,
        name: _name.text,
        notifyOnChange: _onChange,
        target: _kind == 'schedule' ? _target : kAutomationTargetThisSession,
        allowChaining: _allowChaining,
        catchUp: catchUp,
      );
    }
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(result.automation);
      return;
    }
    setState(() {
      _saving = false;
      _hostError = result.error;
    });
  }

  // ── webhooks ──
  /// The webhook fields, checked. Null after setting the error.
  _WebhookFields? _webhookFields(
    AppLocalizations l,
    String? Function(String key, String message) fail,
  ) {
    final String secret = _secret.text;
    if (secret.isNotEmpty && !isValidWebhookSecret(secret)) {
      fail('secret', l.webhookErrSecret);
      return null;
    }
    Object? filter;
    if (_filterJson.text.trim().isNotEmpty) {
      try {
        filter = parseWebhookFilterJson(_filterJson.text);
      } on FormatException {
        fail('filter_json', l.webhookErrFilterJson);
        return null;
      }
    } else if (_filterTarget.text.trim().isNotEmpty) {
      try {
        filter = webhookFilterLeaf(
          place: _filterPlace,
          target: _filterTarget.text,
          op: _filterOp,
          value: _filterValue.text,
        );
      } on FormatException {
        fail('filter_value', l.webhookErrFilter);
        return null;
      }
    }
    final int? debounce = parseWebhookSeconds(
      _debounce.text,
      kWebhookMaxDebounce,
    );
    if (debounce == null) {
      fail('debounce', l.webhookErrDebounce);
      return null;
    }
    final int? maxWait = parseWebhookSeconds(_maxWait.text, kWebhookMaxMaxWait);
    if (maxWait == null) {
      fail('max_wait', l.webhookErrMaxWait);
      return null;
    }
    if (_prompt.text.trim().isEmpty) {
      fail('prompt', l.automationErrPrompt);
      return null;
    }
    return _WebhookFields(
      filter: filter,
      debounce: debounce,
      maxWait: maxWait,
      secret: secret.isEmpty ? null : secret,
    );
  }

  /// Creates (server webhook, then the host row) or edits a webhook row.
  Future<void> _saveWebhook(
    AppLocalizations l,
    _WebhookFields fields,
    Object? catchUp,
  ) async {
    final AgentsAutomation? before = widget.existing;
    if (before != null) {
      Map<String, dynamic>? frame = automationUpdateFrame(
        before: before,
        spec: before.spec,
        prompt: _prompt.text,
        name: _name.text,
        notifyOnChange: _onChange,
        allowChaining: _allowChaining,
        catchUp: catchUp,
        catchUpSet: true,
      );
      final Map<String, dynamic> specChange = webhookSpecUpdate(
        before: before,
        filter: fields.filter,
        debounceSeconds: fields.debounce,
        maxWaitSeconds: fields.maxWait,
        secret: _removeSecret ? '' : fields.secret,
      );
      if (specChange.isNotEmpty) {
        frame ??= <String, dynamic>{
          'type': 'automation_update',
          'id': before.id,
        };
        frame['spec'] = specChange;
      }
      if (frame == null) {
        setState(() => _hostError = l.automationNothingChanged);
        return;
      }
      setState(() => _saving = true);
      final AutomationSaveResult result = await _source.update(frame);
      if (!mounted) return;
      final AgentsAutomation? saved = result.automation;
      if (saved != null) {
        Navigator.of(context).pop(saved);
        return;
      }
      setState(() {
        _saving = false;
        _hostError = result.error;
      });
      return;
    }
    final String? session = widget.sessionKey ?? _agent;
    if (session == null) return;
    setState(() => _saving = true);
    final WebhookCreateResult result = await createWebhookAutomation(
      sessionKey: session,
      prompt: _prompt.text,
      name: _name.text,
      notifyOnChange: _onChange,
      allowChaining: _allowChaining,
      catchUp: catchUp,
      filter: fields.filter,
      debounceSeconds: fields.debounce,
      maxWaitSeconds: fields.maxWait,
      signingSecret: fields.secret,
      service: widget.webhooks,
      deviceId: widget.hostDeviceId,
      createAutomation: webhookCreatorFor(_source),
      source: _source,
    );
    if (!mounted) return;
    // The secret has gone to the host; the form forgets it.
    _secret.clear();
    final AgentsAutomation? saved = result.automation;
    final String? url = result.url;
    if (saved != null && url != null) {
      setState(() {
        _saving = false;
        _createdRow = saved;
        _createdUrl = url;
      });
      return;
    }
    setState(() {
      _saving = false;
      _hostError = webhookErrorText(l, result);
    });
  }

  Widget _webhookFieldsView(AppLocalizations l, ThemeData theme) {
    final AgentsAutomation? a = widget.existing;
    final bool signed = a != null && a.webhookSigned && !_removeSecret;
    final TextStyle? label = theme.textTheme.labelLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (signed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                ExpressiveBadge(l.webhookSecretSet, icon: Icons.check),
                TextButton(
                  key: const ValueKey<String>('webhook-remove-secret'),
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _removeSecret = true;
                          _hostError = null;
                        }),
                  child: Text(l.webhookRemoveSecret),
                ),
              ],
            ),
          ),
        if (_removeSecret)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              l.webhookSecretRemoved,
              key: const ValueKey<String>('webhook-secret-removed'),
              style: theme.textTheme.bodySmall,
            ),
          ),
        _field(
          key: 'secret',
          controller: _secret,
          label: l.webhookSecretLabel,
          help: l.webhookSecretHelp,
          obscure: true,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
          child: Text(l.webhookFilterLabel, style: label),
        ),
        ConnectedGroup(
          key: const ValueKey<String>('webhook-filter-place'),
          margin: EdgeInsets.zero,
          labels: <String>[l.webhookFilterPath, l.webhookFilterHeader],
          selected: _filterPlace == 'path' ? 0 : 1,
          onSelected: (int i) =>
              setState(() => _filterPlace = i == 0 ? 'path' : 'header'),
        ),
        const SizedBox(height: 10),
        _field(
          key: 'filter_target',
          controller: _filterTarget,
          label: _filterPlace == 'path'
              ? l.webhookFilterTargetPath
              : l.webhookFilterTargetHeader,
          hint: _filterPlace == 'path' ? r'$.action' : 'x-github-event',
        ),
        Wrap(
          key: const ValueKey<String>('webhook-filter-op'),
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final String op in kWebhookFilterOps)
              ChoiceChip(
                key: ValueKey<String>('webhook-filter-op-$op'),
                label: Text(op),
                selected: _filterOp == op,
                onSelected: (_) => setState(() => _filterOp = op),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _field(
          key: 'filter_value',
          controller: _filterValue,
          label: l.webhookFilterValue,
          hint: _filterOp == 'in' ? 'push, pull_request' : 'opened',
          help: l.webhookFilterHelp,
        ),
        _field(
          key: 'filter_json',
          controller: _filterJson,
          label: l.webhookFilterJson,
          hint: '{"any": [...]}',
          help: l.webhookFilterJsonHelp,
          maxLines: 4,
        ),
        _field(
          key: 'debounce',
          controller: _debounce,
          label: l.webhookDebounceLabel,
          help: l.webhookDebounceHelp,
          keyboard: TextInputType.number,
        ),
        _field(
          key: 'max_wait',
          controller: _maxWait,
          label: l.webhookMaxWaitLabel,
          keyboard: TextInputType.number,
        ),
      ],
    );
  }

  /// The kind choice. Four labels do not fit one pill on a phone at a large
  /// text size, so a narrow sheet shows two pills of two.
  Widget _kindPicker(AppLocalizations l, List<String> kinds) {
    String labelOf(String kind) => switch (kind) {
      'watch_url' => l.automationKindPage,
      'mail' => l.automationKindMail,
      kWebhookKind => l.automationKindWebhook,
      _ => l.automationKindSchedule,
    };
    void pick(String kind) => setState(() {
      _kind = kind;
      _fieldError = null;
      _fieldKey = null;
      _hostError = null;
    });
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        if (box.maxWidth >= 520) {
          return ConnectedGroup(
            key: const ValueKey<String>('automation-kind'),
            margin: EdgeInsets.zero,
            labels: <String>[for (final String k in kinds) labelOf(k)],
            selected: kinds.indexOf(_kind).clamp(0, kinds.length - 1),
            onSelected: (int i) => pick(kinds[i]),
          );
        }
        final List<List<String>> rows = <List<String>>[
          for (int i = 0; i < kinds.length; i += 2)
            kinds.sublist(i, i + 2 > kinds.length ? kinds.length : i + 2),
        ];
        return Column(
          key: const ValueKey<String>('automation-kind'),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int r = 0; r < rows.length; r++) ...<Widget>[
              if (r > 0) const SizedBox(height: 4),
              ConnectedGroup(
                key: ValueKey<String>('automation-kind-row-$r'),
                margin: EdgeInsets.zero,
                labels: <String>[for (final String k in rows[r]) labelOf(k)],
                selected: rows[r].indexOf(_kind),
                onSelected: (int i) => pick(rows[r][i]),
              ),
            ],
          ],
        );
      },
    );
  }
  // ── end webhooks ──

  Widget _field({
    required String key,
    required TextEditingController controller,
    required String label,
    String? hint,
    String? help,
    TextInputType? keyboard,
    int maxLines = 1,
    bool obscure = false,
  }) {
    final ThemeData theme = Theme.of(context);
    final bool failed = _fieldKey == key;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExpressiveField(
            child: TextField(
              key: ValueKey<String>('automation-field-$key'),
              controller: controller,
              keyboardType: keyboard,
              maxLines: obscure ? 1 : maxLines,
              minLines: 1,
              obscureText: obscure,
              enableSuggestions: !obscure,
              autocorrect: key == 'prompt',
              decoration: InputDecoration(
                border: InputBorder.none,
                labelText: label,
                hintText: hint,
              ),
              onChanged: (_) {
                if (failed || _hostError != null) {
                  setState(() {
                    _fieldError = null;
                    _fieldKey = null;
                    _hostError = null;
                  });
                }
              },
            ),
          ),
          if (failed || help != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                failed ? _fieldError! : help!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: failed
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l = _l10n(context);
    final String? createdUrl = _createdUrl;
    if (createdUrl != null) {
      return Flexible(
        child: SingleChildScrollView(
          child: WebhookUrlOnceView(
            url: createdUrl,
            onDone: () => Navigator.of(context).pop(_createdRow),
          ),
        ),
      );
    }
    final List<String> kinds = kCreatableAutomationKinds;
    final List<Widget> specFields = switch (_kind) {
      kWebhookKind => <Widget>[_webhookFieldsView(l, theme)],
      'watch_url' => <Widget>[
        _field(
          key: 'url',
          controller: _url,
          label: l.automationUrlLabel,
          hint: 'https://example.com/page',
          keyboard: TextInputType.url,
        ),
        _field(
          key: 'minutes',
          controller: _minutes,
          label: l.automationIntervalLabel,
          help: l.automationIntervalHelp,
          keyboard: TextInputType.number,
        ),
      ],
      'mail' => <Widget>[
        _field(
          key: 'from',
          controller: _from,
          label: l.automationMailFromLabel,
          hint: 'shop@example.com',
          keyboard: TextInputType.emailAddress,
        ),
        _field(
          key: 'subject',
          controller: _subject,
          label: l.automationMailSubjectLabel,
        ),
        _field(
          key: 'alias',
          controller: _alias,
          label: l.automationMailAliasLabel,
          hint: 'receipts',
          help: l.automationMailHelp,
        ),
      ],
      // Picked, not typed: daily, weekdays, every N hours; the text field is
      // the picker's "custom" shape (bead chuk_chat-4p90).
      _ => <Widget>[
        SchedulePicker(
          controller: _schedule,
          errorText: _fieldKey == 'schedule' ? _fieldError : null,
          onChanged: () {
            if (_fieldKey != null || _hostError != null) {
              setState(() {
                _fieldError = null;
                _fieldKey = null;
                _hostError = null;
              });
            }
          },
          customField: _field(
            key: 'schedule',
            controller: _schedule,
            label: l.automationScheduleLabel,
            hint: 'every 1h',
            help: l.automationScheduleHelp,
          ),
        ),
      ],
    };
    final bool pickAgent = !_editing && widget.sessionKey == null;
    return Flexible(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (pickAgent) ...<Widget>[
              ExpressiveField(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: const ValueKey<String>('automation-agent'),
                    isExpanded: true,
                    value: _agent,
                    hint: Text(l.automationAgentLabel),
                    items: <DropdownMenuItem<String>>[
                      for (final MapEntry<String, String> e
                          in widget.agents.entries)
                        DropdownMenuItem<String>(
                          value: e.key,
                          child: Text(e.value, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (String? v) => setState(() {
                      _agent = v;
                      if (_fieldKey == 'agent') {
                        _fieldKey = null;
                        _fieldError = null;
                      }
                    }),
                  ),
                ),
              ),
              if (_fieldKey == 'agent')
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text(
                    _fieldError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
            ],
            // The kind is chosen once; an edit keeps it (the host keeps a
            // row's kind, and a page watch is not a schedule with a URL).
            if (!_editing) ...<Widget>[
              _kindPicker(l, kinds),
              const SizedBox(height: 14),
            ],
            ...specFields,
            _field(
              key: 'prompt',
              controller: _prompt,
              label: l.automationPromptLabel,
              keyboard: TextInputType.multiline,
              maxLines: 5,
            ),
            _field(
              key: 'name',
              controller: _name,
              label: l.automationNameLabel,
            ),
            // A schedule can run in a chat of its own.
            if (_kind == 'schedule') ...<Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
                child: Text(
                  l.automationTargetLabel,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ConnectedGroup(
                key: const ValueKey<String>('automation-target'),
                margin: EdgeInsets.zero,
                labels: <String>[
                  l.automationTargetThis,
                  l.automationTargetNewOnce,
                  l.automationTargetNew,
                ],
                selected: kAutomationTargets
                    .indexOf(_target)
                    .clamp(0, kAutomationTargets.length - 1),
                onSelected: (int i) => setState(() {
                  _target = kAutomationTargets[i];
                  _hostError = null;
                }),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: Text(
                  l.automationTargetHelp,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            _field(
              key: 'catch_up',
              controller: _catchUp,
              label: l.automationCatchUpLabel,
              help: l.automationCatchUpHelp,
            ),
            ExpressiveSwitchRow(
              key: const ValueKey<String>('automation-chaining'),
              title: l.automationChaining,
              subtitle: l.automationChainingHelp,
              value: _allowChaining,
              onChanged: _saving
                  ? null
                  : (bool v) => setState(() {
                      _allowChaining = v;
                      _hostError = null;
                    }),
            ),
            ExpressiveSwitchRow(
              key: const ValueKey<String>('automation-notify'),
              title: l.automationNotifyOnChange,
              subtitle: l.automationNotifyOnChangeHelp,
              value: _onChange,
              onChanged: _saving
                  ? null
                  : (bool v) => setState(() {
                      _onChange = v;
                      _hostError = null;
                    }),
            ),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: Opacity(
                opacity: _saving ? 0.6 : 1,
                child: ExpressiveButton(
                  key: const ValueKey<String>('automation-save'),
                  label: _editing ? l.save : l.automationCreate,
                  icon: _editing ? Icons.check : Icons.add,
                  onTap: _save,
                ),
              ),
            ),
            if (_saving)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (_hostError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _hostError!,
                  key: const ValueKey<String>('automation-host-error'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── webhooks ──
/// The checked webhook fields of the form.
class _WebhookFields {
  const _WebhookFields({
    required this.filter,
    required this.debounce,
    required this.maxWait,
    required this.secret,
  });

  final Object? filter;
  final int debounce;
  final int maxWait;
  final String? secret;
}

/// The user-facing text of a failed webhook create: a server code in the
/// app's words, a host refusal in the host's.
String webhookErrorText(AppLocalizations l, WebhookCreateResult result) {
  final String? code = result.serverCode;
  if (code == null) {
    final String text = result.error ?? l.webhookFailed;
    // The server webhook of the failed create is still there: say so.
    return result.rollbackFailed ? '$text\n${l.webhookRollbackFailed}' : text;
  }
  return switch (code) {
    'too_many_webhooks' => l.webhookErrTooMany,
    AgentsWebhookException.network => l.webhookErrNetwork,
    _ => l.webhookErrServer(code),
  };
}

/// The secret URL of a new webhook, shown this one time: the URL, a copy
/// button and the warning (docs/WIRE_CONTRACT.md, "Inbound webhooks", App
/// work 1). The app does not keep the URL.
class WebhookUrlOnceView extends StatelessWidget {
  const WebhookUrlOnceView({
    super.key,
    required this.url,
    required this.onDone,
  });

  final String url;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l = _l10n(context);
    return Column(
      key: const ValueKey<String>('webhook-url-once'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          l.webhookUrlTitle,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            url,
            key: const ValueKey<String>('webhook-url'),
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: const <String>['Courier'],
            ),
          ),
        ),
        const SizedBox(height: 10),
        ExpressiveInfoCard(
          key: const ValueKey<String>('webhook-url-note'),
          icon: Icons.warning_amber_outlined,
          text: l.webhookUrlNote,
        ),
        const SizedBox(height: 14),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            ExpressiveButton(
              key: const ValueKey<String>('webhook-copy'),
              label: l.webhookCopy,
              icon: Icons.copy,
              tonal: true,
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (context.mounted) pillToast(context, l.webhookCopied);
              },
            ),
            ExpressiveButton(
              key: const ValueKey<String>('webhook-done'),
              label: l.webhookDone,
              icon: Icons.check,
              onTap: onDone,
            ),
          ],
        ),
      ],
    );
  }
}
// ── end webhooks ──
