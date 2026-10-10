// The fixed UI texts of the OpenUI components (placeholders, button
// labels, validation messages) come from the app's own l10n. Texts the
// model writes (labels, titles) are never translated.

import 'package:flutter/widgets.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';

final AppLocalizations _english = AppLocalizations(const Locale('en'));

/// The app strings for the current locale. English when the tree has no
/// app localizations (tests, the gallery), so a component never crashes.
AppLocalizations openUiStrings(BuildContext context) =>
    AppLocalizations.of(context) ?? _english;
