/// The app's icon table, re-exported from its one home.
///
/// The merge brought two byte-identical copies of this file: upstream's
/// `widgets/icons/icon_map.dart` and the Agents copy that used to live here.
/// Two copies mean two distinct `AppIcon` classes, so `widget is AppIcon` is
/// false across the boundary — which broke every test that looks for an icon
/// by widget type, and would have broken any `is AppIcon` check in the app.
///
/// `widgets/icons/` wins because upstream owns it and four times as many files
/// import it. This file stays so the Agents import sites keep resolving.
library;

export 'package:chuk_chat/widgets/icons/icon_map.dart';
