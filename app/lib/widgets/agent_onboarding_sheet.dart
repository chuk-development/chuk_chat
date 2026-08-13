/// Onboarding a coworker (§4): give it a standing job, optionally list the files
/// it should work from, and set when it wakes up on its own.
///
/// Two deliberate limits, both stated in the form rather than faked:
///
///  * **No video onboarding.** §4 wants "show, don't tell", but the backend
///    accepts images only on the chat route, so a video field would be a prop.
///  * **Attachments are names, not uploads.** The controller has no way to push
///    file bytes to the host yet, so the form collects the list and says plainly
///    that the files are not delivered.
library;

import 'package:flutter/material.dart';

import 'package:cowork/services/cowork/schedule_spec.dart';

/// What the form produces.
class AgentDraft {
  const AgentDraft({
    required this.name,
    this.brief,
    this.attachmentNames = const <String>[],
    this.schedule,
  });

  final String name;
  final String? brief;
  final List<String> attachmentNames;
  final ScheduleSpec? schedule;
}

class AgentOnboardingSheet extends StatefulWidget {
  const AgentOnboardingSheet({
    super.key,
    required this.suggestedName,
    required this.onSubmit,
    this.onCancel,
  });

  /// The auto-assigned name (§4). The user may change it.
  final String suggestedName;

  final void Function(AgentDraft draft) onSubmit;
  final VoidCallback? onCancel;

  @override
  State<AgentOnboardingSheet> createState() => _AgentOnboardingSheetState();
}

class _AgentOnboardingSheetState extends State<AgentOnboardingSheet> {
  late final TextEditingController _nameController =
      TextEditingController(text: widget.suggestedName);
  final TextEditingController _briefController = TextEditingController();
  final TextEditingController _scheduleController = TextEditingController();
  final TextEditingController _attachmentController = TextEditingController();

  final List<String> _attachments = <String>[];
  String? _nameError;
  String? _briefError;
  String? _scheduleError;
  ScheduleSpec? _schedule;

  @override
  void dispose() {
    _nameController.dispose();
    _briefController.dispose();
    _scheduleController.dispose();
    _attachmentController.dispose();
    super.dispose();
  }

  void _onScheduleChanged(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      setState(() {
        _schedule = null;
        _scheduleError = null;
      });
      return;
    }
    final spec = ScheduleSpec.tryParse(text);
    setState(() {
      _schedule = spec;
      _scheduleError = spec == null ? 'Not a schedule this app understands.' : null;
    });
  }

  void _addAttachment() {
    final name = _attachmentController.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _attachments.add(name);
      _attachmentController.clear();
    });
  }

  void _submit() {
    final name = _nameController.text.trim();
    final brief = _briefController.text.trim();
    setState(() {
      _nameError = name.isEmpty ? 'Give the agent a name.' : null;
      _briefError = brief.isEmpty ? 'Describe the job it should do.' : null;
    });
    if (_nameError != null || _briefError != null || _scheduleError != null) return;
    widget.onSubmit(
      AgentDraft(
        name: name,
        brief: brief,
        attachmentNames: List<String>.unmodifiable(_attachments),
        schedule: _schedule,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          shrinkWrap: true,
          children: [
            Text('New coworker', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Name',
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _briefController,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: 'Job',
                hintText: 'Every week, fetch the crypto news and summarise it.',
                border: const OutlineInputBorder(),
                errorText: _briefError,
              ),
            ),
            const SizedBox(height: 16),
            Text('Files', style: theme.textTheme.labelLarge),
            Text(
              'Listed for the brief only. The app cannot upload them to the host yet.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _attachmentController,
                    decoration: const InputDecoration(
                      labelText: 'File name',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _addAttachment(),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: _addAttachment, child: const Text('Add')),
              ],
            ),
            if (_attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final name in _attachments)
                      InputChip(
                        label: Text(name),
                        onDeleted: () => setState(() => _attachments.remove(name)),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _scheduleController,
              decoration: InputDecoration(
                labelText: 'Schedule (optional)',
                hintText: 'every 30m · 0 9 * * * · 2026-02-03T14:00',
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: _scheduleError,
              ),
              onChanged: _onScheduleChanged,
            ),
            if (_schedule != null) ...[
              const SizedBox(height: 6),
              Text(_schedule!.describe(), style: theme.textTheme.bodySmall),
              for (final run in _schedule!.nextRuns(DateTime.now(), count: 2))
                Text(
                  _stamp(run),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                ),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.onCancel != null)
                  TextButton(
                    onPressed: widget.onCancel,
                    child: const Text('Cancel'),
                  ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _submit, child: const Text('Create')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _stamp(DateTime when) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${when.year}-${two(when.month)}-${two(when.day)} '
        '${two(when.hour)}:${two(when.minute)}';
  }
}
