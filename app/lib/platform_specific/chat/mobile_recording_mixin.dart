// lib/platform_specific/chat/mobile_recording_mixin.dart
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/platform_specific/chat/chat_api_service.dart';
import 'package:cowork/platform_specific/chat/chat_scroll_mixin.dart';
import 'package:cowork/platform_specific/chat/chat_ui_mobile.dart';
import 'package:cowork/platform_specific/chat/handlers/audio_recording_handler.dart';
import 'package:cowork/platform_specific/chat/handlers/streaming_message_handler.dart';
import 'package:cowork/platform_specific/chat/mobile_attach_mixin.dart';
import 'package:cowork/platform_specific/chat/mobile_message_edit_mixin.dart';
import 'package:cowork/platform_specific/chat/mobile_model_selection_mixin.dart';
import 'package:cowork/platform_specific/chat/mobile_send_mixin.dart';
import 'package:cowork/platform_specific/chat/model_provider_resolution_mixin.dart';
import 'package:cowork/platform_specific/chat/regen_variant_seed.dart';
import 'package:cowork/services/supabase_service.dart';

/// The microphone: tapping it, and what happens to what was said.
///
/// A tap starts and stops the recorder and drives the waveform; sending hands
/// the recording to transcription and puts the text in the composer. Whether
/// that text then goes out by itself is the reader's
/// `autoSendVoiceTranscription` setting, not a rule of this file.
///
/// Members are public so the host State and its build method can reach them.
mixin MobileRecordingMixin<T extends ChukChatUIMobile>
    on
        State<T>,
        ChatScrollMixin<T>,
        ModelProviderResolutionMixin<T>,
        MobileModelSelectionMixin<T>,
        MobileAttachMixin<T>,
        RegenVariantSeedMixin<T>,
        MobileSendMixin<T>,
        MobileMessageEditMixin<T> {
  // --- host-provided -------------------------------------------------------

  AudioRecordingHandler get audioHandler;
  StreamingMessageHandler get streamingHandler;
  ChatApiService get chatApiService;

  // --- state ---------------------------------------------------------------

  /// Drives the waveform while the microphone is live.
  Timer? audioVisualizerTimer;

  Future<void> handleMicTap() async {
    if (audioHandler.isMicActive) {
      await audioHandler.stopRecording();
      audioHandler.onLevelsChanged = null;
      audioVisualizerTimer?.cancel();
      audioVisualizerTimer = null;
      if (!mounted) return;
      setState(() {
        audioHandler.resetAudioLevels();
      });
    } else {
      // Use the existing session token — no need to refresh first.
      final accessToken = SupabaseService.auth.currentSession?.accessToken;

      final bool started = await audioHandler.startRecording(
        accessToken: accessToken,
      );
      if (!mounted) return;
      if (started) {
        setState(() {
          audioHandler.resetAudioLevels();
        });
        // Drive visualizer updates from recorder/PCM callbacks directly.
        // This avoids unnecessary full-screen rebuilds while attachments upload.
        audioHandler.onLevelsChanged = () {
          if (mounted && audioHandler.isMicActive) {
            setState(() {});
          }
        };
      } else {
        showChatSnackBar('Mic access failed');
      }
    }
  }

  Future<void> handleAudioSend() async {
    if (!audioHandler.isMicActive || audioHandler.isTranscribingAudio) {
      return;
    }
    final l = AppLocalizations.of(context)!;

    await audioHandler.stopRecording(keepFile: true);
    audioHandler.onLevelsChanged = null;
    audioVisualizerTimer?.cancel();
    audioVisualizerTimer = null;
    if (!mounted) return;
    setState(() {
      audioHandler.resetAudioLevels();
    });

    final session = await streamingHandler.getSessionSafely();
    if (session == null) return;

    // Mark transcribing immediately so the send button shows loading spinner
    // before the async transcription call sets it internally.
    audioHandler.setTranscribing(true);
    if (mounted) setState(() {});

    final result = await audioHandler.transcribeLastRecording(
      apiService: chatApiService,
      accessToken: session.accessToken,
    );

    if (!mounted) return;

    if (result.requiresLogout) {
      await SupabaseService.signOut();
    }

    if (!result.success) {
      showChatSnackBar(result.error ?? l.transcriptionFailed);
      setState(() {}); // Trigger UI update to hide loading icon
      return;
    }

    if (result.text != null && result.text!.isNotEmpty) {
      setState(() {
        composerController.text = result.text!;
        composerController.selection = TextSelection.fromPosition(
          TextPosition(offset: result.text!.length),
        );
      });

      // If auto-send is enabled, send the message immediately.
      // Do NOT set isSendingMessage here — sendMessage() reads that flag at
      // its top and would queue the transcription behind the send already in
      // flight instead of sending it. sendMessage() sets the flag itself.
      // Route through sendOrSubmitEdit so a transcription produced while
      // editing replaces the edited message (and truncates below) instead of
      // being appended as a brand-new message at the end.
      if (widget.autoSendVoiceTranscription) {
        await sendOrSubmitEdit();
      } else {
        // Otherwise, focus the text field so user can review before sending
        composerFocusNode.requestFocus();
      }
    }
  }

  // --- FILE HANDLERS ---

  /// Clear the chat and bind the new one to [workspaceId] (null clears it).
  /// Lives on the host, not in [MobileAttachMixin], because it drops the
  /// message list, the decode caches and any edit in progress with it.
}
