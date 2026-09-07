import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:cowork/l10n/app_localizations.dart';

// Re-exported so a test only has to import this file to build a localised app.
export 'package:cowork/l10n/app_localizations.dart' show AppLocalizations;

/// The localisation delegates the app installs in `main.dart`.
///
/// The imported chuk_chat screens read `AppLocalizations.of(context)!`, so a
/// test that pumps a bare `MaterialApp` around them crashes on the null check.
/// Every widget test that can reach the chat UI pumps through here instead.
const List<LocalizationsDelegate<Object>> kTestLocalizationsDelegates =
    <LocalizationsDelegate<Object>>[
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// A `MaterialApp` shaped like the real one: localised, with [home] as its body.
MaterialApp testApp(Widget home, {Key? key}) => MaterialApp(
      key: key,
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );
