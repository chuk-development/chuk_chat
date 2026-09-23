/// A ROOM's face: its members' faces, overlapping inside one avatar slot.
///
/// A room is a conversation like any other, so on the front page it gets a row
/// like any other — same height, same name line, same preview line. The only
/// thing that tells it apart is the slot on the left, and that is what this
/// widget draws: two or three member faces, offset from each other, inside
/// exactly the box ONE coworker face would have taken. Rows stay aligned
/// because the footprint never changes; the reader still sees at a glance that
/// several coworkers are in there.
///
/// ## Why it stops at two
///
/// [kRoomFacesMax] is 2, and that number was measured, not guessed. A face
/// draws its monogram at 0.38 of its own size, and the layout suite refuses
/// text under 10 px, so a legible face needs about 26.5 px of its own. In the
/// 48 px inbox slot a stack of three leaves each face 26.4 px BEFORE the gap
/// between them and puts the monogram at 8.4 px — `every_screen_layout_test`
/// fails it, and by eye the slot is a texture rather than two people. Two faces
/// at [_kFaceOfSlot] of the slot leave 12.4 px of monogram and read as exactly
/// what the reference messenger shows for a group.
///
/// A room with eight members therefore shows two faces and names all eight on
/// its preview line — the rest belongs in words, not in more circles.
///
/// Nothing here draws new art: each face is an [ExpressiveFace], the same
/// silhouette, colour and stored picture a coworker carries everywhere else, so
/// a member is recognisable in the stack.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';

/// How many member faces a room slot ever shows. See the library doc.
const int kRoomFacesMax = 2;

/// How much of the slot one face of a stack takes. Anything smaller drops the
/// monogram under the app's 10 px floor in the 40 px desktop slot.
const double _kFaceOfSlot = 0.74;

/// The air between two overlapping faces, in logical pixels. Flat, not a
/// fraction of the slot: it is a hairline at every size, and scaling it would
/// eat the small slot's monogram to buy nothing on the large one.
const double _kFaceGap = 1.5;

/// The room slot in the phone inbox — [MobileAgentRow]'s coworker face.
const double kRoomFacesInbox = 48;

/// The room slot in the desktop roster. Bigger than that rail's 34 px coworker
/// face on purpose: two faces in 34 px put the monogram at 8.4 px. The row
/// still lines up, because the roster room row pairs this with a 4 px gap
/// where the coworker row has 34 + 10 — the NAME starts on the same x, which
/// is what the eye reads as an aligned list.
const double kRoomFacesRail = 40;

/// Who is in a room, by the handle they are mentioned with. This is the line
/// under a room's name — in the desktop roster and in the phone inbox alike,
/// so one room reads the same on both.
String roomMembersLabel(AgentsRoom room) =>
    room.members.map((AgentsRoomMember m) => '@${m.handle}').join(', ');

/// One geometry entry: where a face sits in the slot, and how big it is.
/// Public because [RoomFaces.placements] is what a layout test measures.
typedef RoomFacePlacement = ({double left, double top, double size});

class RoomFaces extends StatelessWidget {
  const RoomFaces({
    super.key,
    required this.members,
    this.size = kRoomFacesInbox,
    this.store,
    this.ringColor,
  });

  /// The room's members, in room order. Only the first [kRoomFacesMax] are
  /// drawn.
  final List<AgentsRoomMember> members;

  /// The slot's edge length — the size the single coworker face on a sibling
  /// row is given, so the two rows line up.
  final double size;

  final AgentProfileStore? store;

  /// The hairline that separates two overlapping faces. Defaults to the
  /// surface the row is painted on, so it reads as a gap and not as an outline.
  final Color? ringColor;

  /// The faces' boxes inside a [size] slot, back to front.
  ///
  /// One face fills the slot, so a one-member room (which the app does not
  /// build, but a stale host frame could) is indistinguishable from a coworker
  /// and nothing jumps. Two sit corner to corner on the diagonal — the offset
  /// the reference messenger uses, and the one that keeps both monograms whole.
  static List<RoomFacePlacement> placements(int count, double size) {
    final int n = count.clamp(0, kRoomFacesMax);
    if (n == 0) return const <RoomFacePlacement>[];
    if (n == 1) return <RoomFacePlacement>[(left: 0, top: 0, size: size)];
    final double face = size * _kFaceOfSlot;
    final double shift = size - face;
    return <RoomFacePlacement>[
      (left: 0, top: 0, size: face),
      (left: shift, top: shift, size: face),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final AgentProfileStore profiles = store ?? AgentProfileStore.instance;
    final List<AgentsRoomMember> shown = members
        .take(kRoomFacesMax)
        .toList(growable: false);
    final List<RoomFacePlacement> boxes = placements(shown.length, size);
    final double ring = shown.length > 1 ? _kFaceGap : 0;
    final Color gap = ringColor ?? Theme.of(context).colorScheme.surface;

    return AnimatedBuilder(
      animation: profiles,
      builder: (BuildContext context, Widget? _) => SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            for (int i = 0; i < boxes.length; i++)
              Positioned(
                left: boxes[i].left,
                top: boxes[i].top,
                child: _RingedFace(
                  id: shown[i].agentId,
                  label: shown[i].handle,
                  box: boxes[i].size,
                  ring: ring,
                  ringColor: gap,
                  store: profiles,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One member's face with the gap that lifts it off the face beneath it.
///
/// The gap is painted in the member's OWN silhouette (`agentAvatarShape`), not
/// as a circle: a scalloped blob inside a round ring would show the ring at the
/// scallops and nowhere else, which looks like a rendering fault.
class _RingedFace extends StatelessWidget {
  const _RingedFace({
    required this.id,
    required this.label,
    required this.box,
    required this.ring,
    required this.ringColor,
    required this.store,
  });

  final String id;
  final String label;
  final double box;
  final double ring;
  final Color ringColor;
  final AgentProfileStore store;

  @override
  Widget build(BuildContext context) {
    final Widget face = ExpressiveFace(
      id: id,
      label: label,
      size: box - ring * 2,
      store: store,
    );
    if (ring <= 0) return face;
    return Container(
      width: box,
      height: box,
      decoration: ShapeDecoration(
        color: ringColor,
        shape: agentAvatarShape(id, store.profileOf(id).shape, box),
      ),
      alignment: Alignment.center,
      child: face,
    );
  }
}
