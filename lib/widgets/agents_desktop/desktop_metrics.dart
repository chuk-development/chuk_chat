/// The numbers of the Agents desktop layout.
///
/// One place, so the roster, the details pane, the dialogs and the tests read
/// the same values. None of these apply below the desktop breakpoint: the
/// phone layout has its own metrics and is not touched by this file. The look
/// of every pane is chuk_chat's; what is here is only what chuk has no number
/// for — how far a pane may be dragged.
library;

/// Left pane (roster): resizable between these. The default is the width of
/// chuk's desktop sidebar.
const double kDeskRosterMin = 220;
const double kDeskRosterMax = 360;
const double kDeskRosterDefault = 320;

/// The roster folded to chuk's mini rail.
const double kDeskRailWidth = 56;

/// Right pane (details): resizable between these.
const double kDeskDetailsMin = 300;
const double kDeskDetailsMax = 420;
const double kDeskDetailsDefault = 340;

/// The thread keeps at least this much. Below it the roster folds to the rail
/// before the thread is squeezed any further.
const double kDeskThreadMin = 420;

/// Dialogs on the desktop: at most this wide, with this corner.
const double kDeskDialogMaxWidth = 480;
const double kDeskDialogRadius = 20;
