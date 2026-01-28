// lib/utils/desktop_drop_stub.dart
// Web stub for package:desktop_drop
import 'package:flutter/widgets.dart';

class DropTarget extends StatelessWidget {
  final Widget child;
  final void Function(DropDoneDetails)? onDragDone;
  final void Function(DropEventDetails)? onDragEntered;
  final void Function(DropEventDetails)? onDragExited;

  const DropTarget({
    super.key,
    required this.child,
    this.onDragDone,
    this.onDragEntered,
    this.onDragExited,
  });

  @override
  Widget build(BuildContext context) => child;
}

class DropDoneDetails {
  final List<XFile> files;
  DropDoneDetails({required this.files});
}

class DropEventDetails {
  DropEventDetails();
}

class XFile {
  final String path;
  XFile(this.path);
}
