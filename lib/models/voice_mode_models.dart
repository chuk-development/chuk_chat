// lib/models/voice_mode_models.dart
import 'package:flutter/material.dart';

/// Placeholder for custom icons or specific character details
enum VoiceId {
  ara, eve, leo, rex, sal, gork
}
enum PersonalityId {
  custom, assistant, therapist, storyteller, kidsStoryTime, kidsTriviaGame, meditation, grokDoc, unhinged, sexy, motivation, conspiracy, romantic, argumentative
}

class VoiceOption {
  final VoiceId id;
  final String name;
  final String description;

  VoiceOption({required this.id, required this.name, required this.description});
}

class PersonalityOption {
  final PersonalityId id;
  final String name;
  final IconData icon;
  final bool isAdultContent;
  final bool canReset; // For the refresh icon

  PersonalityOption({
    required this.id,
    required this.name,
    required this.icon,
    this.isAdultContent = false,
    this.canReset = false,
  });
}