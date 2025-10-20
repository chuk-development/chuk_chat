// lib/widgets/model_selection_dropdown.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';
import 'package:chuk_chat/core/model_selection_events.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/api_status_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

const double _menuHorizontalPadding = 32.0; // 16 left + 16 right
const double _menuTrailingAllowance = 64.0; // Checkmark + internal spacing
const double _menuExtraAllowance = 12.0; // Safety margin against glyph clipping
const double _buttonHorizontalPadding = 20.0; // 10 left + 10 right
const double _buttonTrailingAllowance = 44.0; // Icon + arrow + spacing

class _WidthMetrics {
  final double menuWidth;
  final double buttonWidth;

  const _WidthMetrics({required this.menuWidth, required this.buttonWidth});
}

class _AuthRequiredException implements Exception {
  const _AuthRequiredException();
}

class ModelSelectionDropdown extends StatefulWidget {
  final String initialSelectedModelId;
  final ValueChanged<String> onModelSelected;
  final FocusNode textFieldFocusNode;
  final bool isCompactMode;
  final String? compactLabel;

  const ModelSelectionDropdown({
    super.key,
    required this.initialSelectedModelId,
    required this.onModelSelected,
    required this.textFieldFocusNode,
    this.isCompactMode = false,
    this.compactLabel,
  });

  static final ValueNotifier<String> selectedModelNotifier =
      ValueNotifier<String>('');
  static final Set<_ModelSelectionDropdownState> _activeStates =
      <_ModelSelectionDropdownState>{};
  static bool _isRefreshingAll = false;
  static StreamSubscription<void>? _refreshSubscription;
  static StreamSubscription<String>? _modelSelectedSubscription;

  static ValueListenable<String> get selectedModelListenable =>
      selectedModelNotifier;

  static void _registerState(_ModelSelectionDropdownState state) {
    _activeStates.add(state);
    _initializeEventBus();
  }

  static void _unregisterState(_ModelSelectionDropdownState state) {
    _activeStates.remove(state);
    if (_activeStates.isEmpty) {
      _disposeEventBus();
    }
  }

  static void _initializeEventBus() {
    if (_refreshSubscription != null) return; // Already initialized

    final eventBus = ModelSelectionEventBus();
    _refreshSubscription = eventBus.refreshStream.listen((_) async {
      await refreshActiveDropdowns();
    });

    _modelSelectedSubscription = eventBus.modelSelectedStream.listen((modelId) {
      selectedModelNotifier.value = modelId;
    });
  }

  static void _disposeEventBus() {
    _refreshSubscription?.cancel();
    _modelSelectedSubscription?.cancel();
    _refreshSubscription = null;
    _modelSelectedSubscription = null;
  }

  static Future<void> refreshActiveDropdowns() async {
    if (_isRefreshingAll) return;
    _isRefreshingAll = true;
    try {
      final List<_ModelSelectionDropdownState> states =
          List<_ModelSelectionDropdownState>.from(_activeStates);
      await Future.wait(states.map((state) => state.refreshModels()));
    } finally {
      _isRefreshingAll = false;
    }
  }

  static String? providerSlugForModel(String modelId) {
    for (final _ModelSelectionDropdownState state in _activeStates) {
      final String? slug = state.providerSlugFor(modelId);
      if (slug != null && slug.isNotEmpty) {
        return slug;
      }
    }
    return null;
  }

  @override
  State<ModelSelectionDropdown> createState() => _ModelSelectionDropdownState();
}

class _ModelSelectionDropdownState extends State<ModelSelectionDropdown> {
  String _selectedModelId = '';
  String _selectedModelName = 'Loading Models...';
  List<ModelItem> _allModels = [];
  final Map<String, String> _enabledModelProviders = {};
  bool _isLoadingModels = true;
  String _errorMessage = '';
  Timer? _apiAvailabilityTimer;
  Map<String, String> _lastSavedPreferences = {};

  double _menuWidth = 260.0;
  double _buttonWidth = 180.0;

  static const String _apiBaseUrl = 'https://api.chuk.chat';
  static const Duration _apiPollInterval = Duration(seconds: 8);

  @override
  void initState() {
    super.initState();
    ModelSelectionDropdown._registerState(this);
    _selectedModelId = widget.initialSelectedModelId;
    _initializeModelSelection();
  }

  @override
  void didUpdateWidget(covariant ModelSelectionDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSelectedModelId != oldWidget.initialSelectedModelId ||
        widget.isCompactMode != oldWidget.isCompactMode) {
      _selectedModelId = widget.initialSelectedModelId;
      _updateSelectedModelName();
    }
  }

  Future<void> _initializeModelSelection() async {
    setState(() {
      _isLoadingModels = true;
      _errorMessage = '';
    });

    try {
      final savedModelId = await UserPreferencesService.loadSelectedModel();
      if (savedModelId != null && savedModelId.isNotEmpty) {
        _selectedModelId = savedModelId;
      }

      await _fetchModels();
    } catch (error) {
      _errorMessage = 'Error initializing model selection: $error';
      _selectedModelName = 'Error Loading';
      debugPrint('Error initializing model selection: $error');
    } finally {
      if (mounted) {
        setState(() => _isLoadingModels = false);
      }
    }
  }

  String? providerSlugFor(String modelId) {
    return _enabledModelProviders[modelId];
  }

  Future<void> refreshModels() async {
    if (!mounted) return;
    await _initializeModelSelection();
  }

  Future<void> _fetchModels() async {
    try {
      final session =
          await SupabaseService.refreshSession() ??
          SupabaseService.auth.currentSession;
      if (session == null) {
        throw const _AuthRequiredException();
      }
      final String accessToken = session.accessToken;
      if (accessToken.isEmpty) {
        throw const _AuthRequiredException();
      }
      _lastSavedPreferences =
          await UserPreferencesService.loadAllProviderPreferences();
      final response = await http.get(
        Uri.parse('$_apiBaseUrl/models_info'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (response.statusCode == 200) {
        _stopApiAvailabilityPolling();
        final List<dynamic> jsonList = json.decode(response.body);
        final Map<String, String> savedProviders = _lastSavedPreferences;

        _enabledModelProviders.clear();
        final List<Future<void>> cleanupFutures = [];
        final List<ModelItem> filteredModels = [];

        for (final dynamic entry in jsonList) {
          final modelJson = entry as Map<String, dynamic>;
          final ModelItem modelItem = ModelItem.fromJson(modelJson);

          if (modelItem.value.isEmpty) {
            continue;
          }

          final String? savedProviderSlug = savedProviders[modelItem.value];
          if (savedProviderSlug == null || savedProviderSlug.isEmpty) {
            continue;
          }

          final List<dynamic>? providers =
              modelJson['providers'] as List<dynamic>?;
          if (providers == null || providers.isEmpty) {
            cleanupFutures.add(
              UserPreferencesService.clearSelectedProvider(modelItem.value),
            );
            continue;
          }

          final bool providerExists = providers.any((providerEntry) {
            if (providerEntry is! Map<String, dynamic>) return false;
            return providerEntry['slug'] == savedProviderSlug;
          });

          if (providerExists) {
            filteredModels.add(modelItem);
            _enabledModelProviders[modelItem.value] = savedProviderSlug;
          } else {
            cleanupFutures.add(
              UserPreferencesService.clearSelectedProvider(modelItem.value),
            );
          }
        }

        if (cleanupFutures.isNotEmpty) {
          await Future.wait(cleanupFutures);
          _lastSavedPreferences =
              await UserPreferencesService.loadAllProviderPreferences();
        }

        filteredModels.sort((a, b) => a.name.compareTo(b.name));
        _allModels = filteredModels;

        if (!_enabledModelProviders.containsKey(_selectedModelId)) {
          if (_enabledModelProviders.isEmpty) {
            if (_selectedModelId.isNotEmpty) {
              await UserPreferencesService.clearSelectedModel();
            }
            _selectedModelId = '';
            ModelSelectionDropdown.selectedModelNotifier.value = '';
          } else {
            _selectedModelId = _enabledModelProviders.keys.first;
            await UserPreferencesService.saveSelectedModel(_selectedModelId);
            ModelSelectionDropdown.selectedModelNotifier.value =
                _selectedModelId;
          }
        } else if (!_allModels.any(
          (model) => model.value == _selectedModelId,
        )) {
          if (_allModels.isNotEmpty) {
            _selectedModelId = _allModels.first.value;
            await UserPreferencesService.saveSelectedModel(_selectedModelId);
            ModelSelectionDropdown.selectedModelNotifier.value =
                _selectedModelId;
          } else {
            _selectedModelId = '';
            ModelSelectionDropdown.selectedModelNotifier.value = '';
          }
        }

        widget.onModelSelected(_selectedModelId);
        ModelSelectionDropdown.selectedModelNotifier.value = _selectedModelId;
        if (mounted) {
          setState(() {
            _isLoadingModels = false;
            _errorMessage = '';
          });
        }
        _updateSelectedModelName();
      } else if (response.statusCode == 401) {
        throw const _AuthRequiredException();
      } else {
        await _handleApiUnavailable(
          debugDetails: 'Status ${response.statusCode} - ${response.body}'
              .trim(),
        );
      }
    } on _AuthRequiredException {
      if (!mounted) return;
      setState(() {
        _isLoadingModels = false;
        _errorMessage = 'Session expired. Please sign in again.';
        _selectedModelName = 'Sign In Required';
      });
      await SupabaseService.signOut();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session expired. Please sign in again.')),
      );
    } catch (error) {
      await _handleApiUnavailable(debugDetails: '$error');
    }
  }

  Future<void> _handleApiUnavailable({required String debugDetails}) async {
    debugPrint('Model fetch unavailable: $debugDetails');
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final bool hasConnectivity =
        await NetworkStatusService.hasInternetConnection();
    final String message = hasConnectivity
        ? 'We are currently doing maintenance and will be right back.'
        : 'You appear to be offline. Please check your internet connection.';
    if (!mounted) return;
    setState(() {
      _errorMessage = message;
      _selectedModelName = message;
      _isLoadingModels = false;
    });
    scaffoldMessenger.showSnackBar(SnackBar(content: Text(message)));
    _startApiAvailabilityPolling();
  }

  void _startApiAvailabilityPolling() {
    _apiAvailabilityTimer ??= Timer.periodic(_apiPollInterval, (_) async {
      final bool reachable = await ApiStatusService.isApiReachable(
        baseUrl: _apiBaseUrl,
      );
      if (!reachable) return;
      if (!mounted) return;
      _stopApiAvailabilityPolling();
      setState(() {
        _isLoadingModels = true;
        _errorMessage = '';
      });
      await _fetchModels();
    });
  }

  void _stopApiAvailabilityPolling() {
    _apiAvailabilityTimer?.cancel();
    _apiAvailabilityTimer = null;
  }

  void _updateSelectedModelName() {
    final bool hasModels = _allModels.isNotEmpty;
    final ModelItem selectedItem = _allModels.firstWhere(
      (model) => model.value == _selectedModelId,
      orElse: () => ModelItem(
        name: hasModels ? 'Select Model' : 'No Enabled Models',
        value: '',
      ),
    );

    final metrics = _calculateWidthMetrics(selectedItem.name);

    if (mounted) {
      setState(() {
        _selectedModelName = selectedItem.name;
        _menuWidth = metrics.menuWidth;
        _buttonWidth = metrics.buttonWidth;
      });
    }
  }

  _WidthMetrics _calculateWidthMetrics(String selectedLabel) {
    if (!mounted) {
      return const _WidthMetrics(menuWidth: 260.0, buttonWidth: 180.0);
    }

    final mediaQuery = MediaQuery.of(context);
    final textStyle =
        Theme.of(context).textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
    final textDirection = Directionality.of(context);
    final textScaler = mediaQuery.textScaler;

    double measure(String text) =>
        _measureTextWidth(text, textStyle, textDirection, textScaler);

    double longestTextWidth = measure(selectedLabel);
    for (final model in _allModels.where((m) => !m.isToggle)) {
      longestTextWidth = math.max(longestTextWidth, measure(model.name));
    }

    final selectedTextWidth = measure(selectedLabel);

    final desiredMenuWidth = _menuWidthFromTextWidth(longestTextWidth);
    final desiredButtonWidth = _buttonWidthFromTextWidth(selectedTextWidth);

    final double safeMaxWidth = math.max(
      160.0,
      mediaQuery.size.width - 32.0,
    ); // padding to screen edge

    final double menuLowerBound = math.min(220.0, safeMaxWidth);
    final double menuUpperBound = safeMaxWidth;
    final double menuWidth = desiredMenuWidth
        .clamp(menuLowerBound, menuUpperBound)
        .toDouble();

    final double buttonLowerBound = math.min(140.0, menuWidth);
    final double buttonWidth = desiredButtonWidth
        .clamp(buttonLowerBound, menuWidth)
        .toDouble();

    return _WidthMetrics(menuWidth: menuWidth, buttonWidth: buttonWidth);
  }

  double _measureTextWidth(
    String text,
    TextStyle textStyle,
    TextDirection textDirection,
    TextScaler textScaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: textDirection,
      maxLines: 1,
      textScaler: textScaler,
    )..layout();
    return painter.width;
  }

  double _menuWidthFromTextWidth(double textWidth) {
    return textWidth +
        _menuHorizontalPadding +
        _menuTrailingAllowance +
        _menuExtraAllowance;
  }

  double _buttonWidthFromTextWidth(double textWidth) {
    return textWidth + _buttonHorizontalPadding + _buttonTrailingAllowance;
  }

  double _effectiveButtonWidth(double maxAvailableWidth) {
    if (widget.isCompactMode) {
      return 44.0;
    }

    double width = math.max(120.0, _buttonWidth);
    if (maxAvailableWidth.isFinite) {
      width = math.min(width, maxAvailableWidth);
    }
    return width;
  }

  Widget _buildDropdownButtonContent(double buttonWidth) {
    final ValueNotifier<bool> isHovered = ValueNotifier<bool>(false);
    final Color bgColor = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFgColor = Theme.of(context).iconTheme.color!;

    final double effectiveWidth = widget.isCompactMode ? 44.0 : buttonWidth;

    return MouseRegion(
      onEnter: (_) => isHovered.value = true,
      onExit: (_) => isHovered.value = false,
      child: ValueListenableBuilder<bool>(
        valueListenable: isHovered,
        builder: (context, hovered, child) {
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            padding: widget.isCompactMode
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 10),
            height: 36,
            width: effectiveWidth,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: hovered
                    ? iconFgColor
                    : iconFgColor.withValues(alpha: 0.3),
                width: hovered ? 1.2 : 0.8,
              ),
            ),
            alignment: widget.isCompactMode
                ? Alignment.center
                : Alignment.centerLeft,
            child: Row(
              mainAxisSize: widget.isCompactMode
                  ? MainAxisSize.max
                  : MainAxisSize.min,
              mainAxisAlignment: widget.isCompactMode
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                if (widget.isCompactMode)
                  widget.compactLabel != null
                      ? Text(
                          widget.compactLabel!,
                          style: TextStyle(
                            color: iconFgColor,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : Icon(Icons.grid_3x3, color: iconFgColor, size: 20)
                else ...[
                  Icon(Icons.grid_3x3, color: iconFgColor, size: 20),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _selectedModelName,
                      style: TextStyle(color: iconFgColor, fontSize: 14),
                      softWrap: false,
                      maxLines: 1,
                    ),
                  ),
                  Icon(
                    Icons.keyboard_arrow_down,
                    color: iconFgColor.withValues(alpha: 0.8),
                    size: 16,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double buttonWidth = _effectiveButtonWidth(constraints.maxWidth);
        final Widget buttonContent = _buildDropdownButtonContent(buttonWidth);

        if (_isLoadingModels || _errorMessage.isNotEmpty) {
          return buttonContent;
        }

        if (_allModels.isEmpty) {
          return buttonContent;
        }

        final double popupWidth = math.max(buttonWidth, _menuWidth);

        return PopupMenuButton<String>(
          color: Theme.of(context).scaffoldBackgroundColor,
          constraints: BoxConstraints.tightFor(width: popupWidth),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: Theme.of(context).iconTheme.color!.withValues(alpha: 0.3),
            ),
          ),
          onSelected: (value) async {
            final previousModelId = _selectedModelId;

            setState(() {
              _selectedModelId = value;
            });
            _updateSelectedModelName();
            widget.onModelSelected(value);
            ModelSelectionDropdown.selectedModelNotifier.value = value;

            try {
              await UserPreferencesService.saveSelectedModel(value);
            } catch (error) {
              debugPrint('Failed to save selected model: $error');

              if (!context.mounted) return;

              final messenger = ScaffoldMessenger.of(context);
              messenger.showSnackBar(
                const SnackBar(
                  content: Text(
                    'Failed to save model selection. Please try again.',
                  ),
                  backgroundColor: Colors.red,
                  duration: Duration(seconds: 3),
                ),
              );

              setState(() {
                _selectedModelId = previousModelId;
              });
              _updateSelectedModelName();
              widget.onModelSelected(previousModelId);
            }

            Future.delayed(
              Duration.zero,
              () => widget.textFieldFocusNode.requestFocus(),
            );
          },
          itemBuilder: (context) {
            final iconFgColor = Theme.of(context).iconTheme.color!;
            return _allModels.map((model) {
              final selected = _selectedModelId == model.value;
              return PopupMenuItem<String>(
                value: model.value,
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    if (model.isToggle)
                      Row(
                        children: [
                          Switch(
                            value: selected,
                            onChanged: (_) {},
                            activeThumbColor: iconFgColor,
                            activeTrackColor: iconFgColor.withValues(
                              alpha: 0.5,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('Best', style: TextStyle(color: iconFgColor)),
                        ],
                      )
                    else
                      Expanded(
                        child: Text(
                          model.name,
                          style: TextStyle(
                            color: selected
                                ? iconFgColor
                                : iconFgColor.withValues(alpha: 0.8),
                          ),
                          softWrap: false,
                        ),
                      ),
                    const SizedBox(width: 12),
                    if (!model.isToggle && selected)
                      Icon(Icons.check, color: iconFgColor, size: 18),
                    if (model.badge != null)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: model.badge == 'new'
                              ? Colors.teal
                              : Colors.orange,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          model.badge!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            }).toList();
          },
          child: buttonContent,
        );
      },
    );
  }

  @override
  void dispose() {
    ModelSelectionDropdown._unregisterState(this);
    _stopApiAvailabilityPolling();
    super.dispose();
  }
}
