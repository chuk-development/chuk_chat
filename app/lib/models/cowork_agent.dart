/// The roster model: an agent is a coworker, and a coworker has threads (§4).
///
/// Everything in here is data the app itself knows to be true — a name, a brief
/// the user typed, a thread the app opened, whether a run is in flight right
/// now. Nothing here is filled in from a guess: an agent the app created carries
/// [onHost] false until the host confirms it, because the host has no roster
/// API yet.
library;

import 'package:flutter/foundation.dart';

import 'package:cowork/services/cowork/schedule_spec.dart';

/// What a coworker is doing, as far as the app can actually tell.
enum AgentActivity {
  /// A run is in flight right now.
  working,

  /// Idle, waiting for a task.
  waiting,

  /// Idle, but it carries a schedule, so it wakes up on its own.
  scheduled,
}

/// One conversation with one agent. An agent can have many (§4).
///
/// [key] is the `session_key` that rides in the task payload, so a thread here
/// is the same thread the executor resumes on its side.
@immutable
class CoworkThreadInfo {
  const CoworkThreadInfo({
    required this.key,
    required this.title,
    this.lastActivity,
  });

  final String key;
  final String title;
  final DateTime? lastActivity;

  CoworkThreadInfo copyWith({String? title, DateTime? lastActivity}) =>
      CoworkThreadInfo(
        key: key,
        title: title ?? this.title,
        lastActivity: lastActivity ?? this.lastActivity,
      );
}

/// One coworker.
@immutable
class CoworkAgent {
  const CoworkAgent({
    required this.id,
    required this.name,
    required this.threads,
    this.role,
    this.brief,
    this.schedule,
    this.attachmentNames = const <String>[],
    this.onHost = false,
    this.running = false,
    this.lastActivity,
  });

  final String id;
  final String name;

  /// An optional short role the user gave the coworker — "researcher",
  /// "release manager" (§16.1 Bot Mode's "title"). Display only, exactly like
  /// [name]: it labels the agent in the roster, it does not change what the host
  /// runs. Null when the user left it blank.
  final String? role;

  /// The standing job the user gave it at onboarding (§4). Null when the user
  /// never wrote one.
  final String? brief;

  /// A schedule the user set in the app. It is not installed on the host yet —
  /// see [onHost].
  final ScheduleSpec? schedule;

  /// Names of files the user attached at onboarding. Only the names: the
  /// controller has no way to push files to the host yet, so the bytes are not
  /// carried anywhere and must not be claimed as delivered.
  final List<String> attachmentNames;

  /// True only for the agent that really runs on the paired host. False for an
  /// agent the user created in the app, because nothing installs it yet.
  final bool onHost;

  /// A run is in flight for this agent right now.
  final bool running;

  /// The last time anything happened in one of its threads, as observed by this
  /// app. Null when nothing has happened yet.
  final DateTime? lastActivity;

  final List<CoworkThreadInfo> threads;

  AgentActivity get activity {
    if (running) return AgentActivity.working;
    if (schedule != null) return AgentActivity.scheduled;
    return AgentActivity.waiting;
  }

  CoworkAgent copyWith({
    String? name,
    String? role,
    String? brief,
    ScheduleSpec? schedule,
    List<String>? attachmentNames,
    bool? onHost,
    bool? running,
    DateTime? lastActivity,
    List<CoworkThreadInfo>? threads,
  }) =>
      CoworkAgent(
        id: id,
        name: name ?? this.name,
        role: role ?? this.role,
        brief: brief ?? this.brief,
        schedule: schedule ?? this.schedule,
        attachmentNames: attachmentNames ?? this.attachmentNames,
        onHost: onHost ?? this.onHost,
        running: running ?? this.running,
        lastActivity: lastActivity ?? this.lastActivity,
        threads: threads ?? this.threads,
      );
}
