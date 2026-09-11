/// Material glyph in, app icon out.
///
/// 642 icon uses across 276 distinct Material glyphs were spread over this app
/// when the icon set changed. Rewriting every call site would have been 642
/// chances to miss one and no way to tell that two screens had picked different
/// glyphs for the same idea — `close`, `close_rounded` and `cancel` all meaning
/// "shut this".
///
/// So the swap happens here instead: one table, read by [AppIcon] and by the
/// shared building blocks (rows, tiles, buttons). A glyph with no entry still
/// draws as Material, so nothing disappears while the table grows — run
/// `grep -roh "Icons\.[a-zA-Z0-9_]*" lib/` to see what is left.
///
/// The table also collapses synonyms on purpose: every "close" is one icon,
/// every "edit" is one icon. That is the point of having a set.
library;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/huge_icon.dart';

/// The app's icon for [icon], or null when the set has nothing for it.
HugeIconData? hugeIconFor(IconData icon) => _map[icon.codePoint];

/// Keyed by code point: `Icons.close` and `Icons.close_rounded` are different
/// constants but the same idea, and a map on IconData itself would need both.
final Map<int, HugeIconData> _map = <int, HugeIconData>{
  // -- navigation and chrome
  Icons.close.codePoint: HugeIcons.cancel01,
  Icons.close_rounded.codePoint: HugeIcons.cancel01,
  Icons.cancel.codePoint: HugeIcons.cancel01,
  Icons.cancel_outlined.codePoint: HugeIcons.cancel01,
  Icons.arrow_back.codePoint: HugeIcons.arrowLeft02,
  Icons.arrow_back_rounded.codePoint: HugeIcons.arrowLeft02,
  Icons.arrow_back_ios.codePoint: HugeIcons.arrowLeft02,
  Icons.arrow_back_ios_new.codePoint: HugeIcons.arrowLeft02,
  Icons.arrow_forward.codePoint: HugeIcons.arrowRight01,
  Icons.arrow_forward_rounded.codePoint: HugeIcons.arrowRight01,
  Icons.chevron_right.codePoint: HugeIcons.arrowRight01,
  Icons.chevron_right_rounded.codePoint: HugeIcons.arrowRight01,
  Icons.chevron_left.codePoint: HugeIcons.arrowLeft02,
  Icons.chevron_left_rounded.codePoint: HugeIcons.arrowLeft02,
  Icons.expand_more.codePoint: HugeIcons.arrowDown01,
  Icons.keyboard_arrow_down.codePoint: HugeIcons.arrowDown01,
  Icons.keyboard_arrow_down_rounded.codePoint: HugeIcons.arrowDown01,
  Icons.expand_less.codePoint: HugeIcons.arrowUp01,
  Icons.keyboard_arrow_up.codePoint: HugeIcons.arrowUp01,
  Icons.keyboard_arrow_up_rounded.codePoint: HugeIcons.arrowUp01,
  Icons.keyboard_arrow_right.codePoint: HugeIcons.arrowRight01,
  Icons.keyboard_arrow_left.codePoint: HugeIcons.arrowLeft02,
  Icons.menu.codePoint: HugeIcons.menu01,
  Icons.menu_rounded.codePoint: HugeIcons.menu01,
  Icons.more_horiz.codePoint: HugeIcons.moreHorizontal,
  Icons.more_horiz_rounded.codePoint: HugeIcons.moreHorizontal,
  Icons.more_vert.codePoint: HugeIcons.moreHorizontal,
  Icons.open_in_new.codePoint: HugeIcons.linkSquare02,
  Icons.open_in_new_rounded.codePoint: HugeIcons.linkSquare02,
  Icons.link.codePoint: HugeIcons.link01,
  Icons.north_rounded.codePoint: HugeIcons.sendHorizontal,
  Icons.send.codePoint: HugeIcons.sendHorizontal,
  Icons.send_rounded.codePoint: HugeIcons.sendHorizontal,
  Icons.arrow_upward_rounded.codePoint: HugeIcons.sendHorizontal,

  // -- actions
  Icons.check.codePoint: HugeIcons.tick02,
  Icons.check_rounded.codePoint: HugeIcons.tick02,
  Icons.done.codePoint: HugeIcons.tick02,
  Icons.check_circle.codePoint: HugeIcons.checkmarkCircle02,
  Icons.check_circle_outline.codePoint: HugeIcons.checkmarkCircle02,
  Icons.check_circle_rounded.codePoint: HugeIcons.checkmarkCircle02,
  Icons.add.codePoint: HugeIcons.plusSign,
  Icons.add_rounded.codePoint: HugeIcons.plusSign,
  Icons.remove.codePoint: HugeIcons.remove01,
  Icons.remove_rounded.codePoint: HugeIcons.remove01,
  Icons.edit.codePoint: HugeIcons.edit02,
  Icons.edit_rounded.codePoint: HugeIcons.edit02,
  Icons.edit_outlined.codePoint: HugeIcons.edit02,
  Icons.delete.codePoint: HugeIcons.delete02,
  Icons.delete_outline.codePoint: HugeIcons.delete02,
  Icons.delete_outline_rounded.codePoint: HugeIcons.delete02,
  Icons.copy.codePoint: HugeIcons.copy01,
  Icons.copy_rounded.codePoint: HugeIcons.copy01,
  Icons.content_copy.codePoint: HugeIcons.copy01,
  Icons.content_copy_rounded.codePoint: HugeIcons.copy01,
  Icons.refresh.codePoint: HugeIcons.refresh,
  Icons.refresh_rounded.codePoint: HugeIcons.refresh,
  Icons.replay.codePoint: HugeIcons.refresh,
  Icons.search.codePoint: HugeIcons.search01,
  Icons.search_rounded.codePoint: HugeIcons.search01,
  Icons.download.codePoint: HugeIcons.download01,
  Icons.download_rounded.codePoint: HugeIcons.download01,
  Icons.save_alt.codePoint: HugeIcons.download01,
  Icons.share.codePoint: HugeIcons.share01,
  Icons.share_rounded.codePoint: HugeIcons.share01,
  Icons.ios_share_rounded.codePoint: HugeIcons.share01,
  Icons.stop.codePoint: HugeIcons.stop,
  Icons.stop_rounded.codePoint: HugeIcons.stop,
  Icons.stop_circle_outlined.codePoint: HugeIcons.stopCircle,
  Icons.play_arrow.codePoint: HugeIcons.playCircle,
  Icons.play_arrow_rounded.codePoint: HugeIcons.playCircle,
  Icons.play_circle_outline.codePoint: HugeIcons.playCircle,
  Icons.mic.codePoint: HugeIcons.mic02,
  Icons.mic_rounded.codePoint: HugeIcons.mic02,
  Icons.mic_none_rounded.codePoint: HugeIcons.mic02,
  Icons.graphic_eq_rounded.codePoint: HugeIcons.mic02,
  Icons.attach_file.codePoint: HugeIcons.attachment01,
  Icons.attach_file_rounded.codePoint: HugeIcons.attachment01,
  Icons.visibility.codePoint: HugeIcons.view,
  Icons.visibility_rounded.codePoint: HugeIcons.view,
  Icons.visibility_outlined.codePoint: HugeIcons.view,
  Icons.visibility_off.codePoint: HugeIcons.viewOff,
  Icons.visibility_off_rounded.codePoint: HugeIcons.viewOff,
  Icons.visibility_off_outlined.codePoint: HugeIcons.viewOff,
  Icons.logout.codePoint: HugeIcons.logout01,
  Icons.logout_rounded.codePoint: HugeIcons.logout01,
  Icons.filter_list.codePoint: HugeIcons.filter,
  Icons.sort.codePoint: HugeIcons.sorting01,

  // -- things
  Icons.person.codePoint: HugeIcons.user,
  Icons.person_outline.codePoint: HugeIcons.user,
  Icons.person_rounded.codePoint: HugeIcons.user,
  Icons.account_circle.codePoint: HugeIcons.user02,
  Icons.groups_outlined.codePoint: HugeIcons.userGroup,
  Icons.group.codePoint: HugeIcons.userGroup,
  Icons.people_outline.codePoint: HugeIcons.userGroup,
  Icons.folder.codePoint: HugeIcons.folder03,
  Icons.folder_outlined.codePoint: HugeIcons.folder03,
  Icons.folder_open.codePoint: HugeIcons.folder01,
  Icons.folder_open_outlined.codePoint: HugeIcons.folder01,
  Icons.folder_open_rounded.codePoint: HugeIcons.folder01,
  Icons.folder_zip_outlined.codePoint: HugeIcons.zip01,
  Icons.description.codePoint: HugeIcons.file01,
  Icons.description_outlined.codePoint: HugeIcons.file01,
  Icons.description_rounded.codePoint: HugeIcons.file01,
  Icons.insert_drive_file_outlined.codePoint: HugeIcons.file01,
  Icons.article_outlined.codePoint: HugeIcons.text,
  Icons.article_rounded.codePoint: HugeIcons.text,
  Icons.notes_rounded.codePoint: HugeIcons.note01,
  Icons.text_snippet_outlined.codePoint: HugeIcons.text,
  Icons.table_chart_outlined.codePoint: HugeIcons.sheet,
  Icons.table_chart_rounded.codePoint: HugeIcons.sheet,
  Icons.table_rows_rounded.codePoint: HugeIcons.sheet,
  Icons.picture_as_pdf_outlined.codePoint: HugeIcons.pdf01,
  Icons.picture_as_pdf_rounded.codePoint: HugeIcons.pdf01,
  Icons.image.codePoint: HugeIcons.image01,
  Icons.image_outlined.codePoint: HugeIcons.image01,
  Icons.image_rounded.codePoint: HugeIcons.image01,
  Icons.photo_library_rounded.codePoint: HugeIcons.album02,
  Icons.broken_image.codePoint: HugeIcons.imageNotFound01,
  Icons.broken_image_outlined.codePoint: HugeIcons.imageNotFound01,
  Icons.movie_outlined.codePoint: HugeIcons.video01,
  Icons.movie_rounded.codePoint: HugeIcons.video01,
  Icons.code.codePoint: HugeIcons.sourceCode,
  Icons.code_rounded.codePoint: HugeIcons.sourceCode,
  Icons.data_object_rounded.codePoint: HugeIcons.braces,
  Icons.terminal.codePoint: HugeIcons.terminal,
  Icons.terminal_rounded.codePoint: HugeIcons.terminal,
  Icons.storage_rounded.codePoint: HugeIcons.database01,
  Icons.key.codePoint: HugeIcons.key01,
  Icons.key_outlined.codePoint: HugeIcons.key01,
  Icons.key_rounded.codePoint: HugeIcons.key01,
  Icons.palette_outlined.codePoint: HugeIcons.paintBoard,
  Icons.extension_outlined.codePoint: HugeIcons.puzzle,
  Icons.extension_rounded.codePoint: HugeIcons.puzzle,
  Icons.smart_toy_outlined.codePoint: HugeIcons.robot01,
  Icons.smart_toy_rounded.codePoint: HugeIcons.robot01,
  Icons.psychology_outlined.codePoint: HugeIcons.aiBrain01,
  Icons.auto_awesome.codePoint: HugeIcons.sparkles,
  Icons.auto_awesome_outlined.codePoint: HugeIcons.sparkles,
  Icons.auto_awesome_rounded.codePoint: HugeIcons.sparkles,
  Icons.memory_outlined.codePoint: HugeIcons.blockchain01,
  Icons.schedule.codePoint: HugeIcons.clock01,
  Icons.schedule_outlined.codePoint: HugeIcons.clock01,
  Icons.schedule_rounded.codePoint: HugeIcons.clock01,
  Icons.timer_outlined.codePoint: HugeIcons.timer01,
  Icons.calendar_today.codePoint: HugeIcons.calendar01,
  Icons.event_rounded.codePoint: HugeIcons.calendar01,
  Icons.notifications_none_rounded.codePoint: HugeIcons.notification01,
  Icons.notifications_outlined.codePoint: HugeIcons.notification01,
  Icons.place_outlined.codePoint: HugeIcons.location01,
  Icons.location_on.codePoint: HugeIcons.location01,
  Icons.location_on_outlined.codePoint: HugeIcons.location01,
  Icons.public.codePoint: HugeIcons.globe02,
  Icons.language.codePoint: HugeIcons.globe02,
  Icons.desktop_windows_rounded.codePoint: HugeIcons.computer,
  Icons.computer.codePoint: HugeIcons.computer,
  Icons.laptop_mac.codePoint: HugeIcons.laptop,
  Icons.phone_android.codePoint: HugeIcons.laptop,
  Icons.call_rounded.codePoint: HugeIcons.call02,
  Icons.chat_bubble_outline.codePoint: HugeIcons.message01,
  Icons.chat_bubble_rounded.codePoint: HugeIcons.message01,
  Icons.forum_outlined.codePoint: HugeIcons.chatting01,
  Icons.comment_outlined.codePoint: HugeIcons.comment01,
  Icons.settings.codePoint: HugeIcons.settings01,
  Icons.settings_outlined.codePoint: HugeIcons.settings01,
  Icons.settings_rounded.codePoint: HugeIcons.settings01,
  Icons.tune.codePoint: HugeIcons.settings02,
  Icons.build_outlined.codePoint: HugeIcons.wrench01,
  Icons.bug_report_outlined.codePoint: HugeIcons.bug01,
  Icons.home_rounded.codePoint: HugeIcons.home01,
  Icons.star.codePoint: HugeIcons.star,
  Icons.star_border.codePoint: HugeIcons.star,
  Icons.bookmark_border.codePoint: HugeIcons.bookmark01,
  Icons.bolt.codePoint: HugeIcons.flash,
  Icons.bolt_outlined.codePoint: HugeIcons.flash,
  Icons.flash_on.codePoint: HugeIcons.flash,
  Icons.layers_outlined.codePoint: HugeIcons.layers01,
  Icons.grid_view_rounded.codePoint: HugeIcons.gridView,
  Icons.list_rounded.codePoint: HugeIcons.listView,
  Icons.attach_money.codePoint: HugeIcons.dollar01,
  Icons.info.codePoint: HugeIcons.informationCircle,
  Icons.info_outline.codePoint: HugeIcons.informationCircle,
  Icons.info_outline_rounded.codePoint: HugeIcons.informationCircle,
  Icons.error_outline.codePoint: HugeIcons.alertCircle,
  Icons.error.codePoint: HugeIcons.alertCircle,
  Icons.warning_amber_rounded.codePoint: HugeIcons.alert02,
  Icons.warning_outlined.codePoint: HugeIcons.alert02,
  Icons.dark_mode_outlined.codePoint: HugeIcons.moon02,
  Icons.light_mode_outlined.codePoint: HugeIcons.sun01,
  Icons.photo_camera_rounded.codePoint: HugeIcons.image01,
  Icons.circle.codePoint: HugeIcons.circle,
};

/// An icon that prefers the app's set and falls back to Material.
///
/// Drop-in for [Icon] at a call site that already holds an [IconData]: the
/// swap happens in the table above, not in the call.
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });

  /// Nullable like [Icon]'s, so this is a drop-in at every call site.
  final IconData? icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final IconData? glyph = icon;
    final HugeIconData? mapped = glyph == null ? null : hugeIconFor(glyph);
    if (mapped == null) {
      return Icon(
        glyph,
        size: size,
        color: color,
        semanticLabel: semanticLabel,
      );
    }
    final Widget drawn = HugeIcon(mapped, size: size, color: color);
    return semanticLabel == null
        ? drawn
        : Semantics(label: semanticLabel, child: drawn);
  }
}
