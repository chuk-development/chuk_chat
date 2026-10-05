/// The one-line answer to "what does this coworker run on?", as a settings
/// row: the lab's logo, the model, the provider and the reasoning level, and
/// whether that is the coworker's own choice or the app default.
///
/// It sits on the coworker profile (phone and desktop) and in the desktop
/// details pane. A tap opens the coworker's model page, the one place where
/// the choice is changed ([CoworkerModelPage]).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/pages/coworker_model_page.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/coworker_model.dart';
import 'package:chuk_chat/services/chat_mode_service.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/icons/model_logo.dart';

class CoworkerModelTile extends StatefulWidget {
  const CoworkerModelTile({
    super.key,
    required this.chatId,
    this.coworkerName,
    this.controlSource,
    this.onTap,
  });

  /// The coworker's thread key, which its model is stored under.
  final String chatId;
  final String? coworkerName;

  /// Handed to the model page, so it can show what the last run used.
  final AgentControlSource? controlSource;

  /// Replaces the default tap (opening [CoworkerModelPage]).
  final VoidCallback? onTap;

  @override
  State<CoworkerModelTile> createState() => _CoworkerModelTileState();
}

class _CoworkerModelTileState extends State<CoworkerModelTile> {
  CoworkerModelState? _state;
  List<CoworkerCatalogueModel> _models = const <CoworkerCatalogueModel>[];

  @override
  void initState() {
    super.initState();
    ChatModelSelectionService.instance.addListener(_reload);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(CoworkerModelTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatId != widget.chatId) unawaited(_load());
  }

  @override
  void dispose() {
    ChatModelSelectionService.instance.removeListener(_reload);
    super.dispose();
  }

  void _reload() => unawaited(_load());

  Future<void> _load() async {
    final String chatId = widget.chatId;
    try {
      final state = await CoworkerModel.resolve(chatId);
      final models = await CoworkerModel.catalogue();
      if (!mounted || widget.chatId != chatId) return;
      setState(() {
        _state = state;
        _models = models;
      });
    } catch (_) {
      // The row keeps its last answer; the page it opens loads again.
    }
  }

  void _open() {
    if (widget.onTap != null) {
      widget.onTap!();
      return;
    }
    unawaited(
      CoworkerModelPage.open(
        context,
        chatId: widget.chatId,
        coworkerName: widget.coworkerName,
        controlSource: widget.controlSource,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (state == null) {
      return ExpressiveRow(
        icon: Icons.auto_awesome_outlined,
        title: 'Model',
        subtitle: 'Loading…',
        onTap: _open,
      );
    }
    return ExpressiveRow(
      leading: CoworkerModelLogoTile(modelId: state.modelId),
      title: modelLabel(state.modelId, models: _models),
      subtitle: coworkerModelSummary(state, models: _models),
      trailing: AppIcon(
        Icons.chevron_right,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onTap: _open,
    );
  }
}

/// `Fireworks · Reasoning low`, prefixed with `App default (Fast) · ` while the
/// coworker has no model of its own.
String coworkerModelSummary(
  CoworkerModelState state, {
  List<CoworkerCatalogueModel> models = const <CoworkerCatalogueModel>[],
}) {
  final String provider = providerLabel(
    state.providerSlug,
    modelId: state.modelId,
    models: models,
  );
  final String effort = ChatModeService.reasoningLabel(state.reasoningEffort);
  final String detail = '$provider · Reasoning ${effort.toLowerCase()}';
  return state.followsDefault
      ? 'App default (${state.defaultLabel}) · $detail'
      : detail;
}

/// The lab's logo in the settings icon tile; the sparkle when the lab has no
/// logo, so the row never shows an empty tile.
class CoworkerModelLogoTile extends StatelessWidget {
  const CoworkerModelLogoTile({
    super.key,
    required this.modelId,
    this.size = 42,
  });

  final String modelId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool hasLogo = modelLogoAsset(modelId) != null;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(size * 0.38),
      ),
      alignment: Alignment.center,
      child: hasLogo
          ? ModelLogo(
              modelId: modelId,
              color: scheme.onPrimaryContainer,
              size: size * 0.5,
              logoSize: size * 0.46,
            )
          : AppIcon(
              Icons.auto_awesome_outlined,
              size: size * 0.5,
              color: scheme.onPrimaryContainer,
            ),
    );
  }
}
