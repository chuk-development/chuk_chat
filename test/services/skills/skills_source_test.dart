import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/skills/agents_skill.dart';
import 'package:chuk_chat/services/skills/skill_settings_sync.dart';
import 'package:chuk_chat/services/skills/skills_source.dart';

import '../../support/fake_relay_controller.dart';

/// The shared test double, plus the two skill frames the source sends.
class FakeSkillsController extends FakeRelayController
    implements AgentsSkillsControl {
  final List<(String, String)> controls = <(String, String)>[];
  int listRequests = 0;
  Object? sendError;

  @override
  Future<void> sendSkillControl({
    required String name,
    required String action,
  }) async {
    if (sendError != null) throw sendError!;
    controls.add((name, action));
  }

  @override
  Future<void> requestSkillsList() async {
    if (sendError != null) throw sendError!;
    listRequests++;
  }
}

/// A mirror the test can read back and seed.
class FakeMirror implements SkillSettingsMirror {
  FakeMirror({this.stored});

  /// Null = "cannot be read" (signed out). Empty = nothing stored.
  Map<String, bool>? stored;
  final List<(String, bool)> saves = <(String, bool)>[];

  @override
  Future<Map<String, bool>?> load() async =>
      stored == null ? null : Map<String, bool>.of(stored!);

  @override
  Future<void> save(String name, bool enabled) async {
    saves.add((name, enabled));
    stored?[name] = enabled;
  }
}

AgentsSkill skill(String name, {String source = 'workspace', bool enabled = true}) =>
    AgentsSkill.fromPayload(<String, dynamic>{
      'name': name,
      'description': 'Does $name.',
      'source': source,
      'enabled': enabled,
      'path': '/ws/skills/$name/SKILL.md',
    })!;

void main() {
  final source = SkillsSource.instance;
  late FakeSkillsController controller;
  late FakeMirror mirror;

  setUp(() {
    mirror = FakeMirror(stored: <String, bool>{});
    source.reset(mirror: mirror);
    AgentsRelayLink.instance.reset();
    controller = FakeSkillsController();
    AgentsRelayLink.instance.bind(controller);
    source.attach();
  });

  tearDown(() {
    source.reset(mirror: const NoopSkillSettingsMirror());
    AgentsRelayLink.instance.reset();
  });

  test('the model reads a skills_list entry; a nameless one is dropped', () {
    final list = AgentsRelaySkillsList.fromPayload(<String, dynamic>{
      'type': 'skills_list',
      'skills': [
        {'name': 'youtube-transcript', 'description': 'd', 'source': 'builtin', 'enabled': false, 'path': '/p'},
        {'name': 'deploy'},
        {'description': 'no name'},
        'garbage',
      ],
      'errors': ['x: broken', 7, ''],
    });
    expect(list.skills.map((s) => s.name), ['youtube-transcript', 'deploy']);
    expect(list.skills.first.isBuiltin, isTrue);
    expect(list.skills.first.enabled, isFalse);
    expect(list.skills.first.path, '/p');
    // Defaults: workspace, on, no path.
    expect(list.skills.last.source, AgentsSkill.kSourceWorkspace);
    expect(list.skills.last.enabled, isTrue);
    expect(list.skills.last.path, isNull);
    expect(list.errors, ['x: broken']);
  });

  test('refresh asks the host; a reply is the whole truth and notifies', () async {
    expect(source.listed, isFalse);
    expect(await source.refresh(), isTrue);
    expect(controller.listRequests, 1);

    var notified = 0;
    source.addListener(() => notified++);
    controller.emit(AgentsRelaySkillsList(
      skills: [skill('youtube-transcript', source: 'builtin'), skill('deploy')],
      errors: const ['ws/skills/broken/SKILL.md: no YAML frontmatter'],
    ));
    expect(notified, 1);
    expect(source.listed, isTrue);
    expect(source.builtin.map((s) => s.name), ['youtube-transcript']);
    expect(source.workspace.map((s) => s.name), ['deploy']);
    expect(source.errors.single, contains('no YAML frontmatter'));

    // A later reply replaces, never merges.
    controller.emit(AgentsRelaySkillsList(skills: [skill('deploy', enabled: false)]));
    expect(source.all.map((s) => s.name), ['deploy']);
    expect(source.byName('deploy')!.enabled, isFalse);
    expect(source.errors, isEmpty);
  });

  test('setEnabled flips the row at once, sends the control, the reply settles it', () async {
    controller.emit(AgentsRelaySkillsList(skills: [skill('deploy')]));
    expect(await source.setEnabled('deploy', false), isTrue);
    expect(source.byName('deploy')!.enabled, isFalse);
    expect(controller.controls, [('deploy', 'disable')]);

    // The host refused (unknown name, say): its list puts the row back.
    controller.emit(AgentsRelaySkillsList(
      skills: [skill('deploy')],
      errors: const ["no skill named 'deploy'"],
    ));
    expect(source.byName('deploy')!.enabled, isTrue);
    expect(source.errors, ["no skill named 'deploy'"]);

    expect(await source.setEnabled('deploy', true), isTrue);
    expect(controller.controls.last, ('deploy', 'enable'));
  });

  test('a failed send rolls the optimistic flip back', () async {
    controller.emit(AgentsRelaySkillsList(skills: [skill('deploy')]));
    controller.sendError = StateError('socket gone');
    expect(await source.setEnabled('deploy', false), isFalse);
    expect(source.byName('deploy')!.enabled, isTrue);
    expect(await source.refresh(), isFalse);
  });

  test('without a controller that speaks skills nothing is sent', () async {
    AgentsRelayLink.instance.reset();
    AgentsRelayLink.instance.bind(FakeRelayController());
    expect(await source.refresh(), isFalse);
    expect(await source.setEnabled('deploy', false), isFalse);
  });

  test('the first reply pushes the account\'s OFF switches to a host that has them ON', () async {
    mirror.stored = <String, bool>{'deploy': false, 'notes': true, 'gone': false};
    controller.emit(AgentsRelaySkillsList(skills: [
      skill('deploy'),
      skill('notes'),
      skill('fresh'),
    ]));
    await Future<void>.delayed(Duration.zero);
    // Only deploy: notes agrees, gone is not on the host, fresh is unknown.
    expect(controller.controls, [('deploy', 'disable')]);
    // The host's truth is written back for what the mirror did not have.
    expect(mirror.saves, contains(('fresh', true)));
    expect(mirror.saves.where((s) => s.$1 == 'notes'), isEmpty);

    // The host answers the control; the mirror learns deploy is off (it
    // already is, so nothing is written) and no second control goes out.
    controller.emit(AgentsRelaySkillsList(skills: [
      skill('deploy', enabled: false),
      skill('notes'),
      skill('fresh'),
    ]));
    await Future<void>.delayed(Duration.zero);
    expect(controller.controls.length, 1);
    expect(mirror.saves.where((s) => s.$1 == 'deploy'), isEmpty);
  });

  test('every reply writes the host\'s truth to the mirror once per change', () async {
    controller.emit(AgentsRelaySkillsList(skills: [skill('deploy')]));
    await Future<void>.delayed(Duration.zero);
    expect(mirror.saves, [('deploy', true)]);
    controller.emit(AgentsRelaySkillsList(skills: [skill('deploy')]));
    await Future<void>.delayed(Duration.zero);
    expect(mirror.saves.length, 1);
    controller.emit(AgentsRelaySkillsList(skills: [skill('deploy', enabled: false)]));
    await Future<void>.delayed(Duration.zero);
    expect(mirror.saves, [('deploy', true), ('deploy', false)]);
  });

  test('an unreadable mirror (signed out, no table) changes nothing', () async {
    mirror.stored = null;
    controller.emit(AgentsRelaySkillsList(skills: [skill('deploy')]));
    await Future<void>.delayed(Duration.zero);
    expect(controller.controls, isEmpty);
    expect(source.byName('deploy')!.enabled, isTrue);
    // Writes still go out best-effort; the fake just records them.
    expect(mirror.saves, [('deploy', true)]);
  });
}
