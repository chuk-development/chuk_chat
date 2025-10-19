import 'dart:async';

/// Event bus for model selection changes to decouple services from UI widgets.
/// This allows services to notify about changes without directly referencing widgets.
class ModelSelectionEventBus {
  static final ModelSelectionEventBus _instance =
      ModelSelectionEventBus._internal();
  factory ModelSelectionEventBus() => _instance;
  ModelSelectionEventBus._internal();

  final StreamController<void> _refreshController =
      StreamController<void>.broadcast();
  final StreamController<String> _modelSelectedController =
      StreamController<String>.broadcast();

  /// Stream that emits when model selections should be refreshed
  Stream<void> get refreshStream => _refreshController.stream;

  /// Stream that emits when a model is selected
  Stream<String> get modelSelectedStream => _modelSelectedController.stream;

  /// Notify that model selections should be refreshed
  void notifyRefresh() {
    _refreshController.add(null);
  }

  /// Notify that a model has been selected
  void notifyModelSelected(String modelId) {
    _modelSelectedController.add(modelId);
  }

  /// Dispose the event bus
  void dispose() {
    _refreshController.close();
    _modelSelectedController.close();
  }
}
