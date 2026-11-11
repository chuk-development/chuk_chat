import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/widgets/attachment_preview_bar.dart';

import '../support/icon_finder.dart';

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  for (final bool isImage in <bool>[true, false]) {
    testWidgets(
      'a file still uploading can be removed (cancels it), image: $isImage',
      (tester) async {
        final List<String> removed = <String>[];
        await tester.pumpWidget(
          _wrap(
            AttachmentPreviewBar(
              files: <AttachedFile>[
                AttachedFile(
                  id: 'f1',
                  fileName: isImage ? 'photo.jpg' : 'notes.pdf',
                  isUploading: true,
                  isImage: isImage,
                  fileSizeBytes: 4000000,
                ),
              ],
              onRemove: removed.add,
            ),
          ),
        );
        await tester.pump();
        await tester.tap(findIcon(Icons.close_rounded));
        expect(removed, <String>['f1']);
      },
    );
  }
}
