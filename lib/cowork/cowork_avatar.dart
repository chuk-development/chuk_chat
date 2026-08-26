// Round gradient avatar for a coworker or a group, derived from its name.
//
// Mirrors the round-gradient recipe used by the chat send button
// (buildTinyActionButton) so CoWork avatars match the app's visual language.

import 'package:flutter/material.dart';

import 'package:chuk_chat/cowork/cowork_models.dart';

class CoworkAvatar extends StatelessWidget {
  const CoworkAvatar({super.key, required this.agent, this.size = 40});

  final CoworkAgent agent;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (agent.isGroup && agent.members.isNotEmpty) {
      return _GroupAvatar(agent: agent, size: size);
    }
    return _Blob(color: agent.color, label: _initials(agent.name), size: size);
  }
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    return parts.first.characters.take(1).toString().toUpperCase();
  }
  return (parts.first.characters.take(1).toString() +
          parts[1].characters.take(1).toString())
      .toUpperCase();
}

class _Blob extends StatelessWidget {
  const _Blob({required this.color, required this.label, required this.size});

  final Color color;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fg = color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color, color.withValues(alpha: 0.82)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.28),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// Two overlapping mini blobs for a group.
class _GroupAvatar extends StatelessWidget {
  const _GroupAvatar({required this.agent, required this.size});

  final CoworkAgent agent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final a = coworkColorFor(agent.members[0]);
    final b = coworkColorFor(
      agent.members.length > 1 ? agent.members[1] : agent.name,
    );
    final mini = size * 0.66;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned(
            right: 0,
            bottom: 0,
            child: _Blob(color: b, label: '', size: mini),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              decoration: const BoxDecoration(shape: BoxShape.circle),
              foregroundDecoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 1.5,
                ),
              ),
              child: _Blob(color: a, label: '', size: mini),
            ),
          ),
        ],
      ),
    );
  }
}
