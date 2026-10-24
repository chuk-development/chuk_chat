/// The app's component library: the one place to import chrome from.
///
/// Every screen draws its header, close and overlay targets from these
/// widgets, so a button looks the same on every page (docs/DESIGN.md, §6).
///
/// - [FloatingHeaderButton]: the round chip. 42 px opaque circle in the
///   chrome fill, 22 px glyph, 48 px press. Back, close, header actions,
///   targets over an image, a map, a video or a canvas. Variants `accent`,
///   `parked`, `busy`, disabled (`onPressed: null`).
/// - [FloatingAppBar]: the settings-style header (back chip + title pill).
/// - [ExpressiveScreen]: the frame of a full-screen viewer; same chips, same
///   pill.
/// - [FloatingChromeSurface]: the opaque fill behind the chips, the title pill
///   and any floating label (a model name over an image).
/// - [AccentIconButton]: the accent-filled round "new chat" button.
/// - [ExpressiveIconButton]: the squircle target for content inside a page
///   body (a card action, a row action). Not for headers or overlays.
library;

export 'package:chuk_chat/ui/expressive/expressive_screen.dart';
export 'package:chuk_chat/ui/expressive/motion.dart' show ExpressiveIconButton;
export 'package:chuk_chat/widgets/accent_icon_button.dart';
export 'package:chuk_chat/widgets/floating_app_bar.dart';
export 'package:chuk_chat/widgets/floating_chrome_surface.dart';
