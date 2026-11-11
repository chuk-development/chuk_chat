// lib/widgets/floating_page_scaffold.dart
//
// The one frame of every page that has a header.

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/floating_app_bar.dart';

/// The frame of every page: a [FloatingAppBar] that floats over the page.
///
/// The body runs behind the header. The header fades the body out in the
/// page colour. The page colour is always
/// `Theme.of(context).scaffoldBackgroundColor`, so the fade and the page
/// always agree. You cannot change it.
///
/// Use this widget for every page. Do not build a [Scaffold] with an app
/// bar yourself. `test/repo_checks/floating_page_scaffold_test.dart` makes
/// sure of this.
///
/// The body starts at the top edge of the screen, under the header. Put
/// [floatingHeaderInset] inside the scroll view of the body, so that the
/// first item starts below the header.
class FloatingPageScaffold extends StatelessWidget {
  const FloatingPageScaffold({
    super.key,
    required this.appBar,
    this.body,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomNavigationBar,
    this.resizeToAvoidBottomInset,
  });

  /// The header of the page.
  final FloatingAppBar appBar;

  /// The content of the page. It runs behind [appBar].
  final Widget? body;

  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? bottomNavigationBar;
  final bool? resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: appBar,
      body: body,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      bottomNavigationBar: bottomNavigationBar,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    );
  }
}
