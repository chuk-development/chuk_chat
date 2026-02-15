// lib/widgets/update_banner.dart

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/update_check_service.dart';

/// A compact banner shown in the sidebar when a new app version is available.
/// Tapping it downloads the platform-specific installer directly.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: UpdateCheckService.updateAvailable,
      builder: (context, info, _) {
        if (info == null) return const SizedBox.shrink();
        return _buildBanner(context, info);
      },
    );
  }

  Widget _buildBanner(BuildContext context, UpdateInfo info) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final bg = theme.brightness == Brightness.dark
        ? accent.withValues(alpha: 0.12)
        : accent.withValues(alpha: 0.08);
    final borderColor = accent.withValues(alpha: 0.3);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 4.0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: UpdateCheckService.launchDownload,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor, width: 0.5),
            ),
            child: Row(
              children: [
                Icon(Icons.system_update_outlined, size: 18, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Update available',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        'v${info.latestVersion}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    iconSize: 16,
                    onPressed: UpdateCheckService.dismiss,
                    icon: Icon(
                      Icons.close,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
