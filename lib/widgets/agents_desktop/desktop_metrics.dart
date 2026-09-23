/// The numbers of the Agents desktop layout (docs/DESIGN.md §14).
///
/// One place, so the roster, the title bar, the details pane and the tests read
/// the same values. None of these apply below the desktop breakpoint: the
/// phone layout has its own metrics and is not touched by this file.
library;

/// Left pane (roster): resizable between these, default in the middle.
const double kDeskRosterMin = 220;
const double kDeskRosterMax = 360;
const double kDeskRosterDefault = 264;

/// The roster folded to a rail of faces.
const double kDeskRailWidth = 56;

/// Right pane (details): resizable between these.
const double kDeskDetailsMin = 300;
const double kDeskDetailsMax = 420;
const double kDeskDetailsDefault = 340;

/// The thread keeps at least this much. Below it the roster folds to the rail
/// before the thread is squeezed any further.
const double kDeskThreadMin = 420;

/// Title bar of the centre pane, and the header rows of the side panes, so the
/// three hairlines under them line up across the window.
const double kDeskBarHeight = 48;

/// Icon buttons in a bar: box and glyph.
const double kDeskButton = 32;
const double kDeskGlyph = 20;

/// Space between two bar buttons.
const double kDeskButtonGap = 4;

/// Roster rows.
const double kDeskAgentRow = 36;
const double kDeskRoomRow = 32;
const double kDeskRowFace = 24;
const double kDeskRowPadH = 8;

/// The selected row's accent bar.
const double kDeskSelectedBar = 3;

/// Corner of a roster row, a bar button and the search field.
const double kDeskControlRadius = 8;

/// Desktop menus: radius and row height (§14.6).
const double kDeskMenuRadius = 12;
const double kDeskMenuRow = 32;

/// Composer (§14.5).
const double kDeskComposerRadius = 12;
const double kDeskComposerButton = 28;

/// Reading measure of the transcript and the composer (§14.4).
const double kDeskReadingMeasure = 720;

/// Dialogs on the desktop (§14.6).
const double kDeskDialogMaxWidth = 480;
