/// Paints an agent's face as a Direct Share icon for the Android share sheet.
///
/// The PNG is laid out as an adaptive icon: the launcher shows only the middle
/// 72 of 108 units, cut by its own mask (mostly a circle). So the background
/// fills the whole square, a light tint of the agent's colour, and the face
/// (the same silhouette and monogram as [AgentFace]) sits in the visible
/// middle. An agent with a picture shows the picture edge to edge.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/ui/expressive/face_image.dart';
import 'package:chuk_chat/ui/expressive/shapes.dart';
import 'package:chuk_chat/widgets/agent_avatar.dart';

const double _kCanvas = 432;

/// The share of the canvas the launcher mask leaves visible (72 / 108 dp).
const double _kVisible = 72 / 108;

/// The face's size inside that visible circle.
const double _kFaceInVisible = 0.78;

Future<Uint8List?> paintShareTargetIcon({
  required String agentId,
  required String name,
  AgentProfileStore? store,
}) async {
  final AgentProfileStore profiles = store ?? AgentProfileStore.instance;
  final AgentProfile profile = profiles.profileOf(agentId);
  final ui.Image? photo = await _loadPhoto(profile.photoPath);

  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  const Rect full = Rect.fromLTWH(0, 0, _kCanvas, _kCanvas);

  if (photo != null) {
    paintImage(
      canvas: canvas,
      rect: full,
      image: photo,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.high,
    );
    photo.dispose();
  } else {
    final Color accent = agentAccentFor(agentId, dark: false, store: profiles);
    canvas.drawRect(
      full,
      Paint()
        ..color = Color.alphaBlend(
          accent.withValues(alpha: 0.18),
          const Color(0xFFFFFFFF),
        ),
    );
    const double face = _kCanvas * _kVisible * _kFaceInVisible;
    final Rect faceRect = Rect.fromCenter(
      center: full.center,
      width: face,
      height: face,
    );
    final ShapeBorder shape = agentAvatarShape(agentId, profile.shape, face);
    canvas.drawPath(shape.getOuterPath(faceRect), Paint()..color = accent);
    final TextPainter monogram = TextPainter(
      text: TextSpan(
        text: AgentAvatar.monogramOf(name),
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontWeight: FontWeight.w800,
          fontSize: face * 0.38,
          letterSpacing: -0.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    monogram.paint(
      canvas,
      faceRect.center -
          Offset(monogram.width / 2, monogram.height / 2) +
          Offset(0, face * monogramDrop(shape)),
    );
    monogram.dispose();
  }

  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(
    _kCanvas.toInt(),
    _kCanvas.toInt(),
  );
  picture.dispose();
  try {
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<ui.Image?> _loadPhoto(String? path) async {
  final ImageProvider<Object>? provider = faceImageProvider(path);
  if (provider == null) return null;
  final Completer<ui.Image?> done = Completer<ui.Image?>();
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool _) {
      if (!done.isCompleted) done.complete(info.image.clone());
      info.dispose();
      stream.removeListener(listener);
    },
    onError: (Object _, StackTrace? _) {
      if (!done.isCompleted) done.complete(null);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return done.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () {
      stream.removeListener(listener);
      return null;
    },
  );
}
