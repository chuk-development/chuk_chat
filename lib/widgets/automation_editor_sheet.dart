/// The create and edit sheet of an automation (docs/WIRE_CONTRACT.md, "Event
/// triggers and notify only on change"): what sets it off (a schedule, a
/// watched page, a mail filter), what the coworker should do then, its name,
/// and whether every run notifies or only a run that found a change.
///
/// The sheet sends `automation_create` or `automation_update` through
/// [AutomationsSource] and waits for the host's `automation_saved`. A refusal
/// is shown in the host's own words, under the button, and the sheet stays
/// open so the user can fix the field. Nothing is saved optimistically.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

/// Opens the sheet. [existing] edits that row; otherwise a new automation is
/// created for [sessionKey], or for the coworker the user picks from
/// [coworkers] (session key → name) when [sessionKey] is null. Completes with
/// the row the host saved, or null when the sheet was closed.
Future<AgentsAutomation?> showAutomationEditor(
  BuildContext context, {
  AgentsAutomation? existing,
  String? sessionKey,
  Map<String, String> coworkers = const <String, String>{},
  AutomationsSource? source,
}) {
  final AppLocalizations l = _l10n(context);
  return expressiveSheet<AgentsAutomation>(
    context,
    title: existing == null ? l.automationNew : l.automationEdit,
    child: AutomationEditorForm(
      existing: existing,
      sessionKey: sessionKey,
      coworkers: coworkers,
      source: source,
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
    this.coworkers = const <String, String>{},
    this.source,
  });

  final AgentsAutomation? existing;
  final String? sessionKey;
  final Map<String, String> coworkers;
  final AutomationsSource? source;

  @override
  State<AutomationEditorForm> createState() => _AutomationEditorFormState();
}

class _AutomationEditorFormState extends State<AutomationEditorForm> {
  late final AutomationsSource _source =
      widget.source ?? AutomationsSource.instance;

  late String _kind;
  String? _coworker;
  late final TextEditingController _schedule;
  late final TextEditingController _url;
  late final TextEditingController _minutes;
  late final TextEditingController _from;
  late final TextEditingController _subject;
  late final TextEditingController _prompt;
  late final TextEditingController _name;
  late bool _onChange;

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
    _coworker =
        widget.sessionKey ??
        (widget.coworkers.length == 1 ? widget.coworkers.keys.first : null);
    _schedule = TextEditingController(text: a?.scheduleText ?? '');
    _url = TextEditingController(text: a?.watchedUrl ?? '');
    final int seconds =
        (a != null && a.isWatchUrl ? a.everySeconds : null) ??
        kWatchUrlDefaultSeconds;
    _minutes = TextEditingController(text: '${seconds ~/ 60}');
    _from = TextEditingController(text: a?.mailFrom ?? '');
    _subject = TextEditingController(text: a?.mailSubject ?? '');
    _prompt = TextEditingController(text: a?.prompt ?? '');
    _name = TextEditingController(text: a?.name ?? '');
    _onChange = a?.notifiesOnChange ?? false;
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _schedule,
      _url,
      _minutes,
      _from,
      _subject,
      _prompt,
      _name,
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

    if (!_editing && widget.sessionKey == null && _coworker == null) {
      return fail('coworker', l.automationErrCoworker);
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
        if (from.isEmpty && subject.isEmpty) {
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
        return automationSpecFor(_kind, mailFrom: from, mailSubject: subject);
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
    final AutomationSaveResult result;
    if (_editing) {
      final Map<String, dynamic>? frame = automationUpdateFrame(
        before: widget.existing!,
        spec: spec,
        prompt: _prompt.text,
        name: _name.text,
        notifyOnChange: _onChange,
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
        sessionKey: widget.sessionKey ?? _coworker!,
        kind: _kind,
        spec: spec,
        prompt: _prompt.text,
        name: _name.text,
        notifyOnChange: _onChange,
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

  Widget _field({
    required String key,
    required TextEditingController controller,
    required String label,
    String? hint,
    String? help,
    TextInputType? keyboard,
    int maxLines = 1,
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
              maxLines: maxLines,
              minLines: 1,
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
    final List<String> kinds = kCreatableAutomationKinds;
    final List<Widget> specFields = switch (_kind) {
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
          help: l.automationMailHelp,
        ),
      ],
      _ => <Widget>[
        _field(
          key: 'schedule',
          controller: _schedule,
          label: l.automationScheduleLabel,
          hint: 'every 1h',
          help: l.automationScheduleHelp,
        ),
      ],
    };
    final bool pickCoworker = !_editing && widget.sessionKey == null;
    return Flexible(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (pickCoworker) ...<Widget>[
              ExpressiveField(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: const ValueKey<String>('automation-coworker'),
                    isExpanded: true,
                    value: _coworker,
                    hint: Text(l.automationCoworkerLabel),
                    items: <DropdownMenuItem<String>>[
                      for (final MapEntry<String, String> e
                          in widget.coworkers.entries)
                        DropdownMenuItem<String>(
                          value: e.key,
                          child: Text(e.value, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (String? v) => setState(() {
                      _coworker = v;
                      if (_fieldKey == 'coworker') {
                        _fieldKey = null;
                        _fieldError = null;
                      }
                    }),
                  ),
                ),
              ),
              if (_fieldKey == 'coworker')
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
              ConnectedGroup(
                key: const ValueKey<String>('automation-kind'),
                margin: EdgeInsets.zero,
                labels: <String>[
                  l.automationKindSchedule,
                  l.automationKindPage,
                  l.automationKindMail,
                ],
                selected: kinds.indexOf(_kind).clamp(0, kinds.length - 1),
                onSelected: (int i) => setState(() {
                  _kind = kinds[i];
                  _fieldError = null;
                  _fieldKey = null;
                  _hostError = null;
                }),
              ),
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
