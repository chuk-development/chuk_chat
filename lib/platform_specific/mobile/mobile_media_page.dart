/// Media: everything the coworkers have handed over, without opening a chat.
///
/// Two kinds, and they are read differently, so they are shown differently: a
/// picture is looked at (a grid of thumbnails, tap for full screen), a file is
/// opened or saved (the same row the chat draws, so Open and Download behave
/// exactly as they do there).
///
/// There is no third kind. CoWork has no "artifacts" of its own: a coworker
/// writes a real file in its workspace and sends it, and that file is what
/// arrives here.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:cowork/models/content_block.dart' show SandboxArtifactPayload;
import 'package:cowork/services/cowork/media_index.dart';
import 'package:cowork/ui/expressive/top_veil.dart';
import 'package:cowork/widgets/encrypted_image_widget.dart';
import 'package:cowork/widgets/image_viewer.dart';
import 'package:cowork/widgets/sandbox_artifact_block.dart';

class MobileMediaPage extends StatefulWidget {
  const MobileMediaPage({super.key, this.index, this.threadKeys = const []});

  final MediaIndex? index;

  /// Every thread this device holds. Read once each, so what arrived before
  /// this tab existed is in the list too.
  final List<String> threadKeys;

  @override
  State<MobileMediaPage> createState() => _MobileMediaPageState();
}

class _MobileMediaPageState extends State<MobileMediaPage> {
  int _filter = 0;

  MediaIndex get _index => widget.index ?? MediaIndex.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_index.ensureFor(widget.threadKeys));
  }

  @override
  void didUpdateWidget(MobileMediaPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(_index.ensureFor(widget.threadKeys));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return AnimatedBuilder(
      animation: _index,
      builder: (BuildContext context, Widget? _) {
        final List<MediaEntry> images = _index.entries(kind: MediaKind.image);
        final List<MediaEntry> files = _index.entries(kind: MediaKind.file);
        final List<MediaEntry> shown = _filter == 0 ? images : files;
        final double topSpace = MediaQuery.paddingOf(context).top + 58 + 4 + 72;
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: shown.isEmpty
                  ? _Empty(
                      topSpace: topSpace,
                      message: _filter == 0
                          ? 'No pictures yet'
                          : 'No files yet',
                      hint: 'What a coworker sends you shows up here.',
                    )
                  : (_filter == 0
                        ? GridView.builder(
                            padding: EdgeInsets.fromLTRB(
                              12,
                              topSpace,
                              12,
                              MediaQuery.paddingOf(context).bottom + 24,
                            ),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 160,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                ),
                            itemCount: shown.length,
                            itemBuilder: (BuildContext context, int i) =>
                                _Thumbnail(entry: shown[i]),
                          )
                        : ListView.builder(
                            padding: EdgeInsets.fromLTRB(
                              12,
                              topSpace,
                              12,
                              MediaQuery.paddingOf(context).bottom + 24,
                            ),
                            itemCount: shown.length,
                            itemBuilder: (BuildContext context, int i) =>
                                SandboxArtifactBlock(
                                  payload: _payloadOf(shown[i]),
                                ),
                          )),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopVeil(
                fadeBelow: 14,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 12, 0),
                      child: SizedBox(
                        height: 58,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Media',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                      child: Row(
                        children: <Widget>[
                          _FilterChip(
                            label: 'Pictures',
                            count: images.length,
                            selected: _filter == 0,
                            onTap: () => setState(() => _filter = 0),
                            scheme: scheme,
                          ),
                          const SizedBox(width: 8),
                          _FilterChip(
                            label: 'Files',
                            count: files.length,
                            selected: _filter == 1,
                            onTap: () => setState(() => _filter = 1),
                            scheme: scheme,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// A file entry, in the shape the chat's own file row takes. Reusing that row
  /// is the point: Open and Download must not behave differently here.
  static SandboxArtifactPayload _payloadOf(MediaEntry entry) =>
      SandboxArtifactPayload(
        storagePath: entry.reference,
        filename: entry.name,
        mime: entry.mime.isEmpty ? 'application/octet-stream' : entry.mime,
        sizeBytes: entry.sizeBytes ?? 0,
      );
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.entry});

  final MediaEntry entry;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImageViewer(imageDataUrl: entry.reference),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: EncryptedImageWidget(
          storagePath: entry.reference,
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.scheme,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: selected ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              count > 0 ? '$label  $count' : label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.topSpace,
    required this.message,
    required this.hint,
  });

  final double topSpace;
  final String message;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: topSpace + 40, left: 32, right: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Text(message, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
