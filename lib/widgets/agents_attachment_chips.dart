/// The files a user sent to an Agents task, on the user bubble
/// (docs/WIRE_CONTRACT.md, "Attachments to Agents", App work 4), and the
/// upload progress of a send that is still going out (App work 2).
///
/// One row per file: a thumbnail drawn from the local copy when this device
/// still has it (a picture), else a file glyph; the name with its extension;
/// the size. The rows come from the live send (local paths) or from the
/// host's replayed `user.attachments`.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_attachment_store.dart';
import 'package:chuk_chat/services/agents/agents_attachments.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

/// The localised sentence for a refused selection.
String agentsAttachmentRefusalLabel(
  AppLocalizations? l,
  AgentsAttachmentFailure? failure, {
  String? name,
}) {
  if (failure == null) {
    return l?.attachFailed ?? 'The files could not be sent.';
  }
  return switch (failure) {
    AgentsAttachmentFailure.tooLarge =>
      name == null
          ? (l?.attachTooLargeAny ??
                agentsAttachmentRefusalText(failure, name: name))
          : (l?.attachTooLarge(name) ??
                agentsAttachmentRefusalText(failure, name: name)),
    AgentsAttachmentFailure.tooMany =>
      l?.attachTooMany ?? agentsAttachmentRefusalText(failure),
    AgentsAttachmentFailure.empty =>
      l?.attachEmpty(name ?? '') ??
          agentsAttachmentRefusalText(failure, name: name),
    AgentsAttachmentFailure.missing =>
      l?.attachMissing ?? agentsAttachmentRefusalText(failure),
    _ => l?.attachFailed ?? agentsAttachmentRefusalText(failure),
  };
}

/// The attachment rows of one user bubble.
class AgentsAttachmentChips extends StatelessWidget {
  const AgentsAttachmentChips({
    super.key,
    required this.items,
    this.alignEnd = true,
  });

  final List<AgentsAttachmentInfo> items;

  /// The user's side: the rows hug the right edge.
  final bool alignEnd;

  /// The rows of a user message: the host's list when the row came from a
  /// replay, else the files of the live send ([paths]: store refs; a
  /// picture of the live send already shows in the bubble's image grid).
  static List<AgentsAttachmentInfo> forMessage({
    Object? replayed,
    List<String>? paths,
  }) {
    final List<AgentsAttachmentInfo> fromHost =
        AgentsAttachmentInfo.listFromJson(replayed);
    if (fromHost.isNotEmpty) return fromHost;
    return <AgentsAttachmentInfo>[
      for (final String p in paths ?? const <String>[])
        if (AgentsAttachmentStore.isRef(p)) _fromRef(p),
    ];
  }

  static AgentsAttachmentInfo _fromRef(String ref) {
    final AgentsAttachmentMeta? meta = AgentsAttachmentStore.peekMeta(ref);
    return AgentsAttachmentInfo(
      name: meta?.name,
      mime: meta?.mime,
      size: meta?.size,
      kind: 'file',
      localPath: ref,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey<String>('agents-attachment-chips'),
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
            child: _AttachmentRow(item: items[i]),
          ),
      ],
    );
  }
}

class _AttachmentRow extends StatefulWidget {
  const _AttachmentRow({required this.item});

  final AgentsAttachmentInfo item;

  @override
  State<_AttachmentRow> createState() => _AttachmentRowState();
}

class _AttachmentRowState extends State<_AttachmentRow> {
  AgentsAttachmentMeta? _meta;
  Future<Uint8List>? _thumb;

  @override
  void initState() {
    super.initState();
    final String? local = widget.item.localPath;
    if (local == null) return;
    if (AgentsAttachmentStore.isRef(local)) {
      if (widget.item.name == null) {
        AgentsAttachmentStore.meta(local).then((AgentsAttachmentMeta? m) {
          if (mounted && m != null) setState(() => _meta = m);
        });
      }
    } else if (widget.item.isImage) {
      _thumb = ImageStorageService.downloadAndDecryptImage(local);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final String name = widget.item.name ?? _meta?.name ?? '';
    final int? bytes = widget.item.size ?? _meta?.size;
    final String size = bytes == null ? '' : agentsAttachmentSize(bytes);
    final int dot = name.lastIndexOf('.');
    final String stem = dot > 0 ? name.substring(0, dot) : name;
    final String ext = dot > 0 ? name.substring(dot) : '';
    return Semantics(
      label: l?.attachChipLabel(name, size) ?? 'Attachment $name, $size',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Container(
            key: ValueKey<String>(
              'agents-attachment-${widget.item.blobId ?? name}',
            ),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(kRadiusLg),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                _leading(scheme),
                const SizedBox(width: 10),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text.rich(
                          TextSpan(
                            children: <InlineSpan>[
                              TextSpan(text: stem),
                              TextSpan(
                                text: ext,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (size.isNotEmpty)
                          Text(
                            size,
                            maxLines: 1,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _leading(ColorScheme scheme) {
    Widget glyph() => Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      child: HugeIcon(
        widget.item.isImage ? HugeIcons.image01 : HugeIcons.file01,
        size: 20,
        color: scheme.onSecondaryContainer,
      ),
    );
    final Future<Uint8List>? thumb = _thumb;
    if (thumb == null) return glyph();
    return FutureBuilder<Uint8List>(
      future: thumb,
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snap) {
        final Uint8List? data = snap.data;
        if (data == null) return glyph();
        return ClipRRect(
          borderRadius: BorderRadius.circular(kRadiusMd),
          child: Image.memory(
            data,
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => glyph(),
          ),
        );
      },
    );
  }
}

/// "Sending files to your computer" with one bar per file, while a send of
/// [sessionKey] uploads. Nothing when no upload runs.
class AgentsUploadStrip extends StatelessWidget {
  const AgentsUploadStrip({super.key, required this.sessionKey, this.tracker});

  final String sessionKey;
  final AgentsUploadTracker? tracker;

  @override
  Widget build(BuildContext context) {
    final AgentsUploadTracker source = tracker ?? AgentsUploadTracker.instance;
    return ListenableBuilder(
      listenable: source,
      builder: (BuildContext context, _) {
        final List<AgentsUploadProgress> files = source.of(sessionKey);
        if (files.isEmpty) return const SizedBox.shrink();
        final ThemeData theme = Theme.of(context);
        final ColorScheme scheme = theme.colorScheme;
        final AppLocalizations? l = AppLocalizations.of(context);
        return Container(
          key: const ValueKey<String>('agents-upload-strip'),
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(kRadiusLg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                l?.attachUploading ?? 'Sending files to your computer',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              for (final AgentsUploadProgress f in files) ...<Widget>[
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l?.attachProgress(f.received, f.count) ??
                          '${f.received} of ${f.count}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(kRadiusXs),
                  child: LinearProgressIndicator(
                    value: f.fraction,
                    minHeight: 4,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
