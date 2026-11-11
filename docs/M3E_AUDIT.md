# Material 3 Expressive audit (2026-11-10)

Goal (owner, 2026-11-10): every screen looks and moves the way Google would
have designed it with official Material 3 Expressive. The reference is
m3.material.io, read with the skill `m3-expressive-flutter`
(`~/.claude/skills/m3-expressive-flutter/`). Where `docs/DESIGN.md` and the
official guideline disagree, the official guideline wins and DESIGN.md is
changed in the same commit.

Inventory base: commit `5ea18bb8`, 841 Dart files in `lib/`. Counts are
whole-word matches and include a few doc-comment mentions.

## Done

| # | What | Where | Commit |
|---|---|---|---|
| 1 | Springs are the official M3E tokens (`material_ui` `Springs`), not hand-tuned values (was 420/22 and 600/26) | `lib/ui/expressive/motion.dart` | 9f70d081 |
| 2 | Agent faces use the official `MaterialShapes` set, not hand-drawn blobs | `lib/ui/expressive/shapes.dart` | 9f70d081 |
| 3 | `ExpressiveLoader` is the official M3E loading indicator (7-shape morph, contained variant) | `lib/ui/expressive/loading_indicator.dart` | 9f70d081 |
| 4 | Menus expand from the anchor on the spatial default spring | `lib/widgets/anchored_menu.dart` | 9f70d081 |
| 5 | Selected menu row = vibrant `tertiaryContainer` tile, emphasized label, check | `menu_tile_group.dart`, `chat_mode_selector.dart` | 9f70d081 |
| 9a | All themed buttons morph on press (stadium → 12 px corner; icon button circle → 8 px) | `lib/constants.dart` | see git log |
| 6 | Menus are the M3E vertical menu: one container per group, gaps only between groups, no outline frame, inset selected pill, `surfaceContainerLow` on the pickers | `menu_tile_group.dart`, `anchored_menu.dart`, `chat_mode_selector.dart` | see git log |
| 8a | Progress indicators and sliders on the current M3 geometry (`year2023: false`) | `lib/constants.dart` | see git log |
| 6b | Every anchored menu on the standard menu colour `surfaceContainerLow` (nine call sites passed `surfaceContainerHigh`). Menu sheets keep `surfaceContainerHigh` groups: they sit on a `surfaceContainerLow` sheet and need the step | pickers, editable table, secrets, workspaces, agent list, sidebar, artifact panel, searchable picker | see git log |

## Open, ordered by what the user sees most

| # | Area | Official component / token | Gap today | Fix | Effort |
|---|---|---|---|---|---|
| 7 | Short waits | Loading indicator | 99 raw `CircularProgressIndicator`, 8 `RefreshIndicator` | Replace short, unknown-length waits with `ExpressiveLoader` (inline 16–24 px spinners in buttons stay a small indicator, see spec); `RefreshIndicator` → loading-indicator pull-to-refresh | M |
| 8 | Measured progress | Progress indicator (flat or wavy) | 18 raw `LinearProgressIndicator` on default M3 look | Theme `progressIndicatorTheme` (track gap, rounded caps, M3E thickness); wavy for upload/download | S |
| 9 | Buttons | M3E buttons: sizes XS–XL, round/square, shape morph on press, toggle shape swap | 171 `TextButton`, 90 `FilledButton`, 28 `OutlinedButton`, 14 `ElevatedButton` on the theme; the theme has no pressed-shape morph | Give the button themes the M3E pressed shape (`WidgetStateProperty` shape: stadium → small corner when pressed); move `ElevatedButton` to `FilledButton.tonal` | M |
| 10 | Icon buttons | M3E icon buttons (sizes, widths, shapes) | 68 bare `IconButton` | Use `ExpressiveIconButton` / `FloatingHeaderButton` per DESIGN.md §2.1, sized by the M3E table | M |
| 11 | Composer + send | Primary action emphasis | Send button is a custom widget | Check against M3E icon button M size, square shape, pressed morph | S |
| 12 | Attach menu (`+`) | FAB menu is for 2–6 actions from a FAB; from an inline `+` the official choice is a menu | Anchored menu, fine | Keep the menu; give the rows icons in the leading slot (already), M3E spacing | S |
| 13 | Dialogs | Dialog (M3E: extra-large corner, emphasized headline) | 74 `showDialog`, 59 `AlertDialog`, no wrapper | One `showExpressiveDialog` wrapper; emphasized title type | M |
| 14 | Bottom sheets | Bottom sheet | 17 raw `showModalBottomSheet`, 4 `expressiveSheet` | All through one sheet wrapper with the official drag handle and spring | M |
| 15 | Snackbars | Snackbar | 80 `showSnackBar`; theme already makes them floating pills | Route through `pillToast`; check spec corner and colours | S |
| 16 | Selection | Switch (M3E icon thumb), Slider (M3E sizes, inset icon), Checkbox, Radio | Default M3 look, no slider/checkbox theme | Theme switch thumb icons, M3E slider, checkbox theme | S |
| 17 | Segmented / toggles | Button group (connected) | 2 `SegmentedButton`, `ConnectedGroup` pill | Move both to an M3E connected button group with neighbour push | M |
| 18 | Chips | Chips | 6 `ChoiceChip`, 1 `FilterChip`, 2 `Chip` | Theme check against spec | S |
| 19 | FAB | FAB (M3E sizes, no small FAB) | 5 `FloatingActionButton.extended` in workspace/skills pages | Extended FAB M3E sizes; consider a FAB menu where a page has 2–6 create actions | S |
| 20 | Tabs | Tabs | 3 `TabBar` default look | Theme indicator (pill, M3E) | S |
| 21 | Text fields | Text fields | 79 `TextField`, 19 `TextFormField`, global input theme | Compare theme to spec | S |
| 22 | Lists and cards | M3E lists: segmented containers with gaps | 24 `ListTile`, 40 `Card(` outside the `Expressive*` rows | Move to `ExpressiveGroup`/`ExpressiveTile` | M |
| 23 | Typography | Emphasized type for the key element | Theme sets heavier weights globally | Keep base roles at M3 weights; emphasized only where it marks the key element | S |
| 24 | Colour | Expressive scheme variant | Hand-built `ColorScheme` from accent + background | Keep (user accent is a product rule); check container roles exist and are used for emphasis | S |
| 25 | Navigation | Short navigation bar / navigation rail | Custom phone top bar and desktop panes (owner's design, DESIGN.md §4, §14) | No change unless the owner asks: it is a deliberate product decision | – |

## How to continue

1. Read `~/.claude/skills/m3-expressive-flutter/SKILL.md` and the spec
   reference next to it.
2. Take the next open row from the top. Fix at the root (theme or shared
   widget) first.
3. `flutter analyze`, the tests of the touched widgets, then look at it in the
   app (emulator or desktop with hot reload).
4. Move the row to "Done" with the commit hash.
