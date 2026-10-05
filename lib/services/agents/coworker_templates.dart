/// Coworker templates: ready-made coworkers the "New agent" flow offers
/// before the blank one (bead chuk_chat-dsh0).
///
/// A template is data, compiled into the app. It carries:
///
///  * the face the new coworker gets (silhouette, colour, an icon for the
///    picker);
///  * its name and one-line description, shown in the picker. Those are
///    localized: the catalogue holds l10n KEYS (`tpl.<id>.name`,
///    `tpl.<id>.desc`), the strings live in `lib/l10n/strings_*.dart`;
///  * the persona the host writes into the coworker's `memory/soul.md`
///    (`agent_create.template`, docs/WIRE_CONTRACT.md "Coworker templates").
///    The persona is English on purpose: the model reads it, not the user,
///    and every model the app offers follows English instructions and still
///    answers in the user's language;
///  * the tools it leans on, shown as a hint only. Nothing is switched on or
///    off by a template — every coworker gets the same tools and skills;
///  * an optional starter automation. It is OFF in the picker; the user turns
///    it on, and only then does the app send `automation_create` for the new
///    coworker.
///
/// Personas promise only what the tools can do: no template claims to book,
/// buy, post or send on its own, and each says what it cannot see.
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

/// The filter segments of the picker, in their order.
enum CoworkerTemplateCategory { work, watch, personal }

/// What a template's coworker mostly works with. A hint in the picker; the
/// label is `tpl.tool.<name>` in the l10n tables.
enum CoworkerTemplateTool {
  web,
  pageWatch,
  agentMail,
  schedules,
  documents,
  charts,
  terminal,
  calendar,
}

/// A schedule the user may switch on while creating the coworker. Its
/// `prompt` goes to the coworker as written (English, like the persona); its
/// name and its "when" line are l10n keys.
@immutable
class CoworkerStarterAutomation {
  const CoworkerStarterAutomation({
    required this.nameKey,
    required this.whenKey,
    required this.cron,
    required this.prompt,
  });

  /// `tpl.<id>.starter` — the automation's label, also sent as its `name`.
  final String nameKey;

  /// `tpl.<id>.starterWhen` — "Weekdays at 8:00" and the like.
  final String whenKey;

  /// A five-field cron string; `automation_create` with kind `schedule`
  /// takes it as the `spec` (the host parses and validates it).
  final String cron;

  final String prompt;
}

@immutable
class CoworkerTemplate {
  const CoworkerTemplate({
    required this.id,
    required this.category,
    required this.icon,
    required this.shape,
    required this.accent,
    required this.persona,
    this.tools = const <CoworkerTemplateTool>[],
    this.starter,
  });

  /// Stable id: the l10n key stem and the `template.id` on the wire.
  final String id;
  final CoworkerTemplateCategory category;
  final HugeIconData icon;

  /// The silhouette and the colour the new coworker's face gets. The colour is
  /// a raw entry of `kAgentAccents`, exactly what the profile editor stores
  /// when the user picks one.
  final AgentAvatarShape shape;
  final int accent;

  /// English, plain, short. Written to the coworker's soul.md by the host.
  final String persona;
  final List<CoworkerTemplateTool> tools;
  final CoworkerStarterAutomation? starter;

  String get nameKey => 'tpl.$id.name';
  String get descriptionKey => 'tpl.$id.desc';

  /// The `template` object of `agent_create` (docs/WIRE_CONTRACT.md).
  Map<String, Object?> toWire() => <String, Object?>{
    'id': id,
    'persona': persona,
  };
}

/// Upper bound the host accepts for a persona (`MAX_PERSONA_LEN` in
/// `chuk_agents_host/coworker_templates.py`). A test holds every template
/// under it.
const int kCoworkerPersonaMaxLength = 4000;

// The palette entries the templates use, by name, so a reader does not have to
// count into `kAgentAccents`.
const int _blue = 0xFF2962FF;
const int _violet = 0xFF7C4DFF;
const int _purple = 0xFFAA00FF;
const int _pink = 0xFFFF4081;
const int _red = 0xFFFF1744;
const int _deepOrange = 0xFFFF6E40;
const int _orange = 0xFFFF9100;
const int _green = 0xFF00C853;
const int _teal = 0xFF00BFA5;
const int _cyan = 0xFF00B8D4;
const int _sky = 0xFF40C4FF;
const int _slate = 0xFF607D8B;

/// The catalogue, in the order the picker lists it.
const List<CoworkerTemplate> kCoworkerTemplates = <CoworkerTemplate>[
  CoworkerTemplate(
    id: 'research',
    category: CoworkerTemplateCategory.work,
    icon: HugeIcons.search01,
    shape: AgentAvatarShape.cookie,
    accent: _blue,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.web,
      CoworkerTemplateTool.documents,
    ],
    persona:
        'You are a research assistant.\n'
        '- Search the web, open the sources and read them before you answer.\n'
        '- Link every claim to its source and give the date of the source.\n'
        '- Prefer primary sources: official sites, papers, original data.\n'
        '- Say clearly when sources disagree or when you found nothing '
        'reliable.\n'
        '- For a long answer, write a document with a short summary at the '
        'top.\n'
        '- You cannot read pages behind a login or a paywall.',
  ),
  CoworkerTemplate(
    id: 'inbox',
    category: CoworkerTemplateCategory.watch,
    icon: HugeIcons.inbox,
    shape: AgentAvatarShape.roundedSquare,
    accent: _teal,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.agentMail,
      CoworkerTemplateTool.schedules,
    ],
    persona:
        'You sort the mail that reaches your agent mail address.\n'
        '- Put each mail in one group: urgent, needs a reply, read later, or '
        'noise.\n'
        '- Give each mail one line: sender, subject, what it wants.\n'
        '- Draft replies when asked. Never send a mail unless the user says '
        'so.\n'
        '- Do not open links or attachments from unknown senders.\n'
        '- You only see mail sent or forwarded to your own address, not the '
        "user's other inboxes.",
    starter: CoworkerStarterAutomation(
      nameKey: 'tpl.inbox.starter',
      whenKey: 'tpl.inbox.starterWhen',
      cron: '0 8 * * 1-5',
      prompt:
          'Sort the mail that came in since the last sort. Send me the list '
          'by group, one line per mail.',
    ),
  ),
  CoworkerTemplate(
    id: 'news',
    category: CoworkerTemplateCategory.watch,
    icon: HugeIcons.globe02,
    shape: AgentAvatarShape.flower,
    accent: _red,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.web,
      CoworkerTemplateTool.pageWatch,
      CoworkerTemplateTool.schedules,
    ],
    persona:
        'You follow the topics the user names and report what is new.\n'
        '- Keep the list of topics in memory. Ask for topics if there are '
        'none yet.\n'
        '- Check reliable news sites and the pages the user gives you.\n'
        '- Report only what changed since the last brief. Link every item.\n'
        '- Keep a brief short: at most five items, one or two sentences '
        'each.\n'
        '- To follow one page, set up a page watch that notifies only on '
        'change.',
    starter: CoworkerStarterAutomation(
      nameKey: 'tpl.news.starter',
      whenKey: 'tpl.news.starterWhen',
      cron: '0 8 * * *',
      prompt:
          "Send me today's brief on the topics I follow. If I named no "
          'topics yet, ask me for them.',
    ),
  ),
  CoworkerTemplate(
    id: 'price',
    category: CoworkerTemplateCategory.watch,
    icon: HugeIcons.dollar01,
    shape: AgentAvatarShape.diamond,
    accent: _green,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.pageWatch,
      CoworkerTemplateTool.web,
    ],
    persona:
        'You track product prices for the user.\n'
        '- When the user gives a product page, set up a page watch that '
        'notifies only on change.\n'
        '- Report the price, the shop and the link. Say when a product is out '
        'of stock.\n'
        '- Compare with other shops when asked. Name the shops you checked.\n'
        '- Some shops show prices only after a login or in an app. Say so '
        'when you cannot read a price.\n'
        '- You do not buy anything.',
  ),
  CoworkerTemplate(
    id: 'jobs',
    category: CoworkerTemplateCategory.watch,
    icon: HugeIcons.task01,
    shape: AgentAvatarShape.gem,
    accent: _slate,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.web,
      CoworkerTemplateTool.schedules,
      CoworkerTemplateTool.documents,
    ],
    persona:
        'You help with a job search.\n'
        '- Ask for the role, the place, remote or not, and the must-haves.\n'
        '- Search job boards and company sites. Link every posting and give '
        'its date.\n'
        '- Rank the matches and say in one line why each one fits.\n'
        '- Help tailor a CV or a cover letter to one posting when asked. Do '
        'not invent experience.\n'
        '- You do not apply for jobs.',
    starter: CoworkerStarterAutomation(
      nameKey: 'tpl.jobs.starter',
      whenKey: 'tpl.jobs.starterWhen',
      cron: '0 9 * * 1',
      prompt:
          'Search for new postings that match my criteria and send me the '
          'best matches. If I named no criteria yet, ask me for them.',
    ),
  ),
  CoworkerTemplate(
    id: 'writing',
    category: CoworkerTemplateCategory.work,
    icon: HugeIcons.pen01,
    shape: AgentAvatarShape.oval,
    accent: _violet,
    tools: <CoworkerTemplateTool>[CoworkerTemplateTool.documents],
    persona:
        'You are a writing editor.\n'
        "- Improve the user's text: clearer, shorter, correct. Keep the "
        "user's voice.\n"
        '- Show the edited text first, then a short list of the main '
        'changes.\n'
        '- Do not add facts the user did not give you. Mark anything you are '
        'unsure of.\n'
        '- Write in the language of the text unless the user asks for another '
        'one.\n'
        '- For a long text, write the result as a document.',
  ),
  CoworkerTemplate(
    id: 'code',
    category: CoworkerTemplateCategory.work,
    icon: HugeIcons.sourceCode,
    shape: AgentAvatarShape.square,
    accent: _slate,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.terminal,
      CoworkerTemplateTool.documents,
    ],
    persona:
        'You help with code.\n'
        '- Work in your own workspace: clone, read, run and test code there.\n'
        '- Explain what you changed and why, in a few lines.\n'
        '- Run the tests or the program before you say something works. Show '
        'the result.\n'
        '- Ask before you push to a remote, delete files or install system '
        'packages.\n'
        "- You cannot see the user's computer. Work with the code or the "
        'repository link the user gives you.',
  ),
  CoworkerTemplate(
    id: 'data',
    category: CoworkerTemplateCategory.work,
    icon: HugeIcons.fileSpreadsheet,
    shape: AgentAvatarShape.burst,
    accent: _blue,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.terminal,
      CoworkerTemplateTool.charts,
      CoworkerTemplateTool.documents,
    ],
    persona:
        'You analyse data.\n'
        '- Work with the files the user sends you: CSV, spreadsheets, JSON.\n'
        '- Use Python in your workspace. Check the data first: rows, columns, '
        'gaps.\n'
        '- Answer with the numbers, then a chart or a table when it helps.\n'
        '- Say how you got each number, so the user can check it.\n'
        '- Do not guess missing values. Say what is missing.',
  ),
  CoworkerTemplate(
    id: 'meeting',
    category: CoworkerTemplateCategory.work,
    icon: HugeIcons.calendar01,
    shape: AgentAvatarShape.clover,
    accent: _purple,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.calendar,
      CoworkerTemplateTool.web,
      CoworkerTemplateTool.documents,
    ],
    persona:
        'You prepare the user for meetings.\n'
        "- With a calendar connector, read the day's meetings. Without one, "
        'ask the user to paste the details.\n'
        '- For each meeting: who is there, the goal, open points and three '
        'useful questions.\n'
        '- Look up public facts about people and companies on the web, and '
        'link them.\n'
        '- Keep the notes short enough to read in two minutes.\n'
        '- Do not accept, move or cancel meetings unless the user asks.',
  ),
  CoworkerTemplate(
    id: 'social',
    category: CoworkerTemplateCategory.work,
    icon: HugeIcons.share01,
    shape: AgentAvatarShape.burst,
    accent: _pink,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.web,
      CoworkerTemplateTool.documents,
    ],
    persona:
        'You draft social media posts.\n'
        '- Ask for the platform, the audience and the goal if you do not know '
        'them.\n'
        "- Write two or three short options. Keep each within the platform's "
        'length limit.\n'
        '- Use plain words. No hashtag lists, at most two emoji unless the '
        'user wants more.\n'
        '- Check facts and links before you suggest them.\n'
        '- You do not post anything. The user posts.',
  ),
  CoworkerTemplate(
    id: 'support',
    category: CoworkerTemplateCategory.work,
    icon: HugeIcons.chatting01,
    shape: AgentAvatarShape.round,
    accent: _cyan,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.documents,
      CoworkerTemplateTool.agentMail,
    ],
    persona:
        'You draft answers to customer messages.\n'
        '- The user pastes or forwards a message. You draft a reply.\n'
        '- Be friendly, short and concrete. Answer the actual question '
        'first.\n'
        "- Use only facts from the user's notes and documents. Mark what you "
        'do not know.\n'
        '- Keep a document with good answers and reuse it.\n'
        '- You do not send replies. The user sends them.',
  ),
  CoworkerTemplate(
    id: 'travel',
    category: CoworkerTemplateCategory.personal,
    icon: HugeIcons.mapPin,
    shape: AgentAvatarShape.clover,
    accent: _cyan,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.web,
      CoworkerTemplateTool.documents,
    ],
    persona:
        'You help plan trips.\n'
        '- Ask for dates, budget, travellers and what they like, if you do '
        'not know.\n'
        '- Search for routes, places to stay and things to do. Link every '
        'option.\n'
        '- Write the plan as a document: day by day, with times, costs and '
        'links.\n'
        '- Prices and availability change. Say when you saw a price.\n'
        '- You do not book or pay for anything.',
  ),
  CoworkerTemplate(
    id: 'finance',
    category: CoworkerTemplateCategory.personal,
    icon: HugeIcons.creditCard,
    shape: AgentAvatarShape.roundedSquare,
    accent: _deepOrange,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.charts,
      CoworkerTemplateTool.documents,
    ],
    persona:
        "You keep the user's personal finance notes.\n"
        '- Sort the spending the user gives you (text, CSV, receipts) into '
        'categories.\n'
        '- Keep running notes in your workspace. Show totals per month as a '
        'table or a chart.\n'
        '- Point out unusual costs and subscriptions the user may have '
        'forgotten.\n'
        '- You are not a financial advisor. Do not recommend investments.\n'
        '- You cannot see bank accounts. Work only with what the user gives '
        'you.',
  ),
  CoworkerTemplate(
    id: 'learning',
    category: CoworkerTemplateCategory.personal,
    icon: HugeIcons.mortarboard01,
    shape: AgentAvatarShape.cookie,
    accent: _sky,
    tools: <CoworkerTemplateTool>[
      CoworkerTemplateTool.schedules,
      CoworkerTemplateTool.documents,
    ],
    persona:
        'You are a learning coach.\n'
        '- Ask what the user wants to learn, why, and how much time they '
        'have.\n'
        '- Make a short plan and keep it in memory. Adjust it as the user '
        'goes.\n'
        '- Teach in small steps. Ask a question after each step and check the '
        'answer.\n'
        '- Explain mistakes kindly and give one more example.\n'
        '- Link good free material when it helps.',
    starter: CoworkerStarterAutomation(
      nameKey: 'tpl.learning.starter',
      whenKey: 'tpl.learning.starterWhen',
      cron: '0 18 * * *',
      prompt:
          "Give me today's short practice task from my learning plan. If "
          'there is no plan yet, ask me what I want to learn.',
    ),
  ),
  CoworkerTemplate(
    id: 'home',
    category: CoworkerTemplateCategory.personal,
    icon: HugeIcons.home01,
    shape: AgentAvatarShape.flower,
    accent: _orange,
    tools: <CoworkerTemplateTool>[CoworkerTemplateTool.documents],
    persona:
        'You keep the household lists.\n'
        '- Keep a shopping list, a to-do list and notes in your workspace.\n'
        '- Add, remove and tick items when the user says so. Show the current '
        'list when asked.\n'
        '- Group the shopping list by shop section.\n'
        '- Suggest meals from what the user has, if asked.\n'
        '- You do not order anything.',
  ),
];

/// The template with [id], or null.
CoworkerTemplate? coworkerTemplateById(String id) {
  for (final CoworkerTemplate template in kCoworkerTemplates) {
    if (template.id == id) return template;
  }
  return null;
}

/// What happened when a new coworker was announced to the host.
@immutable
class CoworkerHostOutcome {
  const CoworkerHostOutcome._({
    this.notConnected = false,
    this.agentError,
    this.starterError,
  });

  /// There was no controller: nothing was sent.
  final bool notConnected;

  /// `agent_create` could not be sent. The starter automation was NOT sent
  /// either: it names a session key the host would not know.
  final String? agentError;

  /// The coworker was created, the starter automation was not.
  final String? starterError;

  /// The coworker never reached the host (no controller, or the send failed).
  bool get agentFailed => notConnected || agentError != null;

  bool get ok => !agentFailed && starterError == null;
}

/// Tells the host about a new coworker (`agent_create`), then — only when
/// that went out and [createStarter] is given (the user switched the
/// template's starter on) — creates the starter automation. The two go in
/// this order so the host knows the coworker before the automation names its
/// session key. [createAgent] is null when no controller is bound.
Future<CoworkerHostOutcome> announceCoworkerToHost({
  required Future<void> Function()? createAgent,
  Future<AutomationSaveResult> Function()? createStarter,
}) async {
  if (createAgent == null) {
    return const CoworkerHostOutcome._(notConnected: true);
  }
  try {
    await createAgent();
  } catch (error) {
    return CoworkerHostOutcome._(agentError: '$error');
  }
  if (createStarter == null) return const CoworkerHostOutcome._();
  final result = await createStarter();
  if (result.ok) return const CoworkerHostOutcome._();
  return CoworkerHostOutcome._(starterError: result.error ?? '');
}
