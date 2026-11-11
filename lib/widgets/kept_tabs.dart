/// An [IndexedStack] that keeps its tabs quiet: the Chats and Agents halves
/// of the messenger shell.
library;

import 'package:flutter/widgets.dart';

/// Shows the child at [index] and keeps every other child mounted, with no
/// transition: a change of [index] shows the other child on the very next
/// frame (owner, CHAT-18: "there is no animation, you switch instantly").
///
/// All children stay in the tree, as with [IndexedStack], so the roster is
/// not rebuilt and chuk's chat keeps its draft and scroll. A child that is
/// not in front takes no focus, gets no pointer and runs no tickers: a hidden
/// composer must not open the keyboard, and a hidden list has nothing to
/// animate.
class KeptTabs extends StatelessWidget {
  const KeptTabs({super.key, required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        // Every tab keeps its slot and its wrapper chain, in the same order,
        // for the life of the widget: change the shape of a slot and Flutter
        // throws the subtree away and builds a new one. Only the values move.
        for (int i = 0; i < children.length; i++)
          Positioned.fill(
            child: Offstage(
              // Laid out either way (see [RenderOffstage]), so a tab that is
              // waiting keeps its scroll position and its controllers.
              offstage: i != index,
              child: TickerMode(
                enabled: i == index,
                child: ExcludeFocus(excluding: i != index, child: children[i]),
              ),
            ),
          ),
      ],
    );
  }
}
