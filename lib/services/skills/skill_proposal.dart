// lib/services/skills/skill_proposal.dart
//
// Skill proposals, the app side (docs/WIRE_CONTRACT.md, "Skill proposals";
// bead chuk_chat-al2u). After a task that worked, the agent offers to save the
// procedure as a skill. The host only stores a draft. Nothing is written to
// the coworker's `skills/` until the user accepts the card in the thread.
//
// This file holds what the relay client, the source and the card share: the
// host's answer to a decision, the control the relay client implements, and
// the form validation (the same rules as `tool/gen_skills.dart` and the
// host's `validate_draft`).

/// The host's terminal answer to a `skill_proposal_decision`
/// (`skill_proposal_result`).
class AgentsSkillProposalResult {
  const AgentsSkillProposalResult({
    required this.proposalId,
    required this.status,
    this.name,
    this.errors = const <String>[],
    this.path,
    this.scrubbed = false,
    this.alreadyDecided = false,
  });

  /// The file is on disk.
  static const String statusSaved = 'saved';

  /// The draft is gone; nothing was written.
  static const String statusDismissed = 'dismissed';

  /// Nothing was written and the draft stays pending. [errors] says why.
  static const String statusInvalid = 'invalid';

  /// The host knows no proposal with this id.
  static const String statusNotFound = 'not_found';

  /// App side only: the decision did not reach the host, or no answer came
  /// back in time. The draft is still pending on the host.
  static const String statusFailed = 'failed';

  final String proposalId;

  /// One of the `status*` constants.
  final String status;

  /// The skill's name as the host saw it (the edited one, on an edit).
  final String? name;

  /// Every reason the host gave, worded by the host. Shown as they are.
  final List<String> errors;

  /// The host path of the SKILL.md, only on [statusSaved].
  final String? path;

  /// Secrets or personal data were removed from the edits.
  final bool scrubbed;

  /// Another device (or an earlier tap) decided first; [status] is that
  /// decision.
  final bool alreadyDecided;

  bool get isSaved => status == statusSaved;
  bool get isDismissed => status == statusDismissed;
  bool get isInvalid => status == statusInvalid;
  bool get isDecided => isSaved || isDismissed;

  /// A result built on the app side when the host could not be asked.
  factory AgentsSkillProposalResult.failed(String proposalId, String reason) =>
      AgentsSkillProposalResult(
        proposalId: proposalId,
        status: statusFailed,
        errors: <String>[reason],
      );

  /// Reads a decoded `skill_proposal_result` payload, or null when it names
  /// no proposal (nothing to correlate it to).
  static AgentsSkillProposalResult? fromPayload(Map<String, dynamic> payload) {
    final Object? id = payload['proposal_id'];
    if (id is! String || id.isEmpty) return null;
    final Object? status = payload['status'];
    final Object? rawErrors = payload['errors'];
    final Object? name = payload['name'];
    final Object? path = payload['path'];
    return AgentsSkillProposalResult(
      proposalId: id,
      // A word the app does not know is not a save: treat it as a refusal
      // with nothing to show, so the card stays answerable.
      status: status is String && status.isNotEmpty ? status : statusInvalid,
      name: name is String && name.isNotEmpty ? name : null,
      errors: <String>[
        if (rawErrors is List)
          for (final Object? e in rawErrors)
            if (e is String && e.trim().isNotEmpty) e.trim(),
      ],
      path: path is String && path.isNotEmpty ? path : null,
      scrubbed: payload['scrubbed'] == true,
      alreadyDecided: payload['already_decided'] == true,
    );
  }
}

/// Sends the user's answer to a skill proposal. The real relay client
/// implements it; a test double may not, so callers check with `is`.
abstract interface class AgentsSkillProposalControl {
  /// Seals `skill_proposal_decision {proposal_id, accept, name?, description?,
  /// body?}` and completes with the host's `skill_proposal_result`. An absent
  /// edit keeps the draft's value. Never throws: a send that fails or an
  /// answer that never comes completes with [AgentsSkillProposalResult.failed].
  Future<AgentsSkillProposalResult> sendSkillProposalDecision({
    required String proposalId,
    required bool accept,
    String? name,
    String? description,
    String? body,
  });
}

/// What is wrong with one field of the edit form, before anything is sent.
enum SkillDraftFieldError {
  nameEmpty,
  nameTooLong,
  nameInvalid,
  descriptionEmpty,
  descriptionTooLong,
  descriptionMultiline,
  bodyEmpty,
  bodyTooLong,
}

/// The limits of a saved skill, as the host enforces them.
abstract final class SkillDraftRules {
  static const int maxNameChars = 64;
  static const int maxDescriptionChars = 300;
  static const int maxBodyLines = 500;
  static const int maxBodyChars = 40000;

  /// Lower-case letters and digits joined by single hyphens.
  static final RegExp namePattern = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

  static SkillDraftFieldError? validateName(String name) {
    if (name.isEmpty) return SkillDraftFieldError.nameEmpty;
    if (name.length > maxNameChars) return SkillDraftFieldError.nameTooLong;
    if (!namePattern.hasMatch(name)) return SkillDraftFieldError.nameInvalid;
    return null;
  }

  static SkillDraftFieldError? validateDescription(String description) {
    if (description.isEmpty) return SkillDraftFieldError.descriptionEmpty;
    if (description.contains('\n') || description.contains('\r')) {
      return SkillDraftFieldError.descriptionMultiline;
    }
    if (description.length > maxDescriptionChars) {
      return SkillDraftFieldError.descriptionTooLong;
    }
    return null;
  }

  static SkillDraftFieldError? validateBody(String body) {
    if (body.trim().isEmpty) return SkillDraftFieldError.bodyEmpty;
    if (body.length > maxBodyChars ||
        '\n'.allMatches(body).length + 1 > maxBodyLines) {
      return SkillDraftFieldError.bodyTooLong;
    }
    return null;
  }
}

/// Which form field one of the host's error strings belongs to, so it can be
/// shown under that field. The host words them (`invalid name 'X': …`,
/// `description is 301 characters, …`, `a skill named 'x' already exists; …`,
/// `body is empty`). Null: a reason about the whole draft.
enum SkillDraftField { name, description, body }

SkillDraftField? skillDraftFieldForHostError(String error) {
  final String e = error.trimLeft().toLowerCase();
  if (e.startsWith('name') ||
      e.startsWith('invalid name') ||
      e.startsWith('a skill named')) {
    return SkillDraftField.name;
  }
  if (e.startsWith('description')) return SkillDraftField.description;
  if (e.startsWith('body')) return SkillDraftField.body;
  return null;
}
