import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/input_validator.dart';

/// A widget that displays password strength with visual indicators.
///
/// Shows a colored bar indicating strength level and lists requirements
/// with checkmarks for met criteria.
class PasswordStrengthMeter extends StatelessWidget {
  final String password;
  final bool showRequirements;

  const PasswordStrengthMeter({
    super.key,
    required this.password,
    this.showRequirements = true,
  });

  @override
  Widget build(BuildContext context) {
    final result = InputValidator.validatePasswordStrength(password);

    // Don't show anything for empty password
    if (password.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Strength bar
        _buildStrengthBar(result),
        const SizedBox(height: 8),

        // Strength label
        _buildStrengthLabel(result),

        // Requirements checklist
        if (showRequirements && !result.isValid) ...[
          const SizedBox(height: 12),
          _buildRequirementsList(result),
        ],
      ],
    );
  }

  Widget _buildStrengthBar(PasswordValidationResult result) {
    final (color, segments) = _getStrengthVisuals(result.strength);

    return Row(
      children: List.generate(4, (index) {
        final isActive = index < segments;
        return Expanded(
          child: Container(
            height: 4,
            margin: EdgeInsets.only(right: index < 3 ? 4 : 0),
            decoration: BoxDecoration(
              color: isActive ? color : Colors.grey.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildStrengthLabel(PasswordValidationResult result) {
    final (color, _) = _getStrengthVisuals(result.strength);
    final label = _getStrengthLabel(result.strength);

    return Text(
      label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: color,
      ),
    );
  }

  Widget _buildRequirementsList(PasswordValidationResult result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildRequirement(
          'At least ${InputValidator.minPasswordLength} characters',
          result.hasMinLength,
        ),
        _buildRequirement('Uppercase letter (A-Z)', result.hasUppercase),
        _buildRequirement('Lowercase letter (a-z)', result.hasLowercase),
        _buildRequirement('Number (0-9)', result.hasDigit),
        _buildRequirement('Special character (!@#\$%^&*)', result.hasSpecialChar),
      ],
    );
  }

  Widget _buildRequirement(String text, bool isMet) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            isMet ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: isMet ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: isMet ? Colors.green : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  (Color, int) _getStrengthVisuals(PasswordStrength strength) {
    switch (strength) {
      case PasswordStrength.weak:
        return (Colors.red, 1);
      case PasswordStrength.fair:
        return (Colors.orange, 2);
      case PasswordStrength.good:
        return (Colors.yellow, 3);
      case PasswordStrength.strong:
        return (Colors.green, 4);
    }
  }

  String _getStrengthLabel(PasswordStrength strength) {
    switch (strength) {
      case PasswordStrength.weak:
        return 'Weak password';
      case PasswordStrength.fair:
        return 'Fair password';
      case PasswordStrength.good:
        return 'Good password';
      case PasswordStrength.strong:
        return 'Strong password';
    }
  }
}
