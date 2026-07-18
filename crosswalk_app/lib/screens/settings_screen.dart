import 'dart:async';

import 'package:flutter/material.dart';
import '../localization/app_strings.dart';
import '../services/feedback_service.dart';

/// T39: language selection + TTS-rate/vibration-strength sliders + a
/// disabled "screen reader optimization" placeholder.
///
/// The screen-reader toggle is intentionally disabled: docs/Tasks.md T3
/// (accessibility standard) is still ⛔Open Q #5 (undecided by the user),
/// so there is no conformance target yet to implement against.
///
/// Values are pushed to [feedback] immediately so they take effect from
/// the next TTS utterance / vibration onward, for the remainder of the
/// current app session only. There is no persistence (e.g.
/// shared_preferences) in this task's scope — restarting the app resets
/// to the defaults in FeedbackService.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.feedback,
    required this.language,
    required this.onLanguageChanged,
    required this.torchEnabled,
    required this.onTorchChanged,
  });

  final FeedbackService feedback;
  final AppLanguage language;
  final ValueChanged<AppLanguage> onLanguageChanged;

  // T37: current torch/flashlight state (owned by CameraScreen, which owns
  // the live CameraController) and a callback to toggle it. See
  // docs/Tasks.md T37.
  final bool torchEnabled;
  final Future<void> Function(bool enabled) onTorchChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // T38's interactive-element accent color, reused here per the approved
  // mockup guidance (docs/Tasks.md T39).
  static const _colorAccent = Color(0xFF3AA0FF);

  late AppLanguage _language;
  late AppStrings _strings;
  late double _speechRate;
  late int _vibrationDurationMs;
  late bool _torchEnabled;

  @override
  void initState() {
    super.initState();
    _language = widget.language;
    _strings = AppStrings.of(_language);
    _speechRate = widget.feedback.speechRate;
    _vibrationDurationMs = widget.feedback.vibrationDurationMs;
    _torchEnabled = widget.torchEnabled;
  }

  void _selectLanguage(AppLanguage language) {
    if (language == _language) return;
    setState(() {
      _language = language;
      _strings = AppStrings.of(language);
    });
    unawaited(widget.feedback.updateLanguage(language));
    widget.onLanguageChanged(language);
  }

  void _changeSpeechRate(double rate) {
    setState(() => _speechRate = rate);
    unawaited(widget.feedback.updateSpeechRate(rate));
  }

  void _changeVibrationDuration(double milliseconds) {
    final rounded = milliseconds.round();
    setState(() => _vibrationDurationMs = rounded);
    widget.feedback.updateVibrationDuration(rounded);
  }

  // T37: optimistic update, same convention as the other settings above —
  // if the underlying `setFlashMode` call fails (e.g. unsupported device),
  // this local toggle can end up out of sync with the real hardware state
  // until the screen is reopened; acceptable for a best-effort convenience
  // feature, not a safety-critical path.
  void _toggleTorch(bool value) {
    setState(() => _torchEnabled = value);
    unawaited(widget.onTorchChanged(value));
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: _colorAccent,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_strings.settingsTitle),
      ),
      body: ListView(
        children: [
          _buildSectionHeader(_strings.settingsLanguageSectionHeader),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<AppLanguage>(
              segments: [
                ButtonSegment(
                  value: AppLanguage.ko,
                  label: Text(_strings.settingsLanguageKorean),
                ),
                ButtonSegment(
                  value: AppLanguage.en,
                  label: Text(_strings.settingsLanguageEnglish),
                ),
              ],
              selected: {_language},
              onSelectionChanged: (selection) =>
                  _selectLanguage(selection.first),
              style: SegmentedButton.styleFrom(
                backgroundColor: Colors.black,
                selectedBackgroundColor: _colorAccent,
                selectedForegroundColor: Colors.white,
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white38),
              ),
            ),
          ),

          _buildSectionHeader(_strings.settingsVoiceVibrationSectionHeader),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_strings.settingsTtsRateLabel}: '
                  '${_speechRate.toStringAsFixed(1)}',
                  style: const TextStyle(color: Colors.white),
                ),
                Slider(
                  value: _speechRate,
                  min: 0.1,
                  max: 1.0,
                  divisions: 9,
                  activeColor: _colorAccent,
                  label: _speechRate.toStringAsFixed(1),
                  onChanged: _changeSpeechRate,
                ),
                const SizedBox(height: 12),
                // The slider adjusts the vibration's actual duration in
                // milliseconds (FeedbackService's `_vibrationDurationMs`);
                // the label surfaces the raw ms value directly rather than
                // an arbitrary 약함/보통/강함 mapping, since duration is the
                // literal, user-verifiable unit being changed.
                Text(
                  '${_strings.settingsVibrationStrengthLabel}: '
                  '${_vibrationDurationMs}ms',
                  style: const TextStyle(color: Colors.white),
                ),
                Slider(
                  value: _vibrationDurationMs.toDouble(),
                  min: 200,
                  max: 1000,
                  divisions: 8,
                  activeColor: _colorAccent,
                  label: '${_vibrationDurationMs}ms',
                  onChanged: _changeVibrationDuration,
                ),
              ],
            ),
          ),

          _buildSectionHeader(_strings.settingsAccessibilitySectionHeader),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SwitchListTile(
              value: false,
              onChanged: null,
              activeColor: _colorAccent,
              contentPadding: EdgeInsets.zero,
              title: Text(
                _strings.settingsScreenReaderOptimizationLabel,
                style: const TextStyle(color: Colors.white70),
              ),
              subtitle: Text(
                _strings.settingsScreenReaderOptimizationNote,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          ),

          _buildSectionHeader(_strings.settingsLowLightSectionHeader),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SwitchListTile(
              value: _torchEnabled,
              onChanged: _toggleTorch,
              activeColor: _colorAccent,
              contentPadding: EdgeInsets.zero,
              title: Text(
                _strings.settingsTorchLabel,
                style: const TextStyle(color: Colors.white70),
              ),
              subtitle: Text(
                _strings.settingsTorchNote,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
