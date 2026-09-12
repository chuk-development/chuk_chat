# lib/core · Signatures

## lib/core/model_selection_events.dart  (32 Z.)

- L5 `class ModelSelectionEventBus`  — Event bus for model selection changes to decouple services from UI widgets.
  - L6 `static final ModelSelectionEventBus _instance = ModelSelectionEventBus._internal()`
  - L8 `factory ModelSelectionEventBus()`
  - L9 `ModelSelectionEventBus._internal()`
  - L11 `final StreamController<void> _refreshController = StreamController<void>.broadcast()`
  - L13 `final StreamController<String> _modelSelectedController = StreamController<String>.broadcast()`
  - L17 `Stream<void> get refreshStream`  — Stream that emits when model selections should be refreshed
  - L20 `Stream<String> get modelSelectedStream`  — Stream that emits when a model is selected
  - L23 `void notifyRefresh()`  — Notify that model selections should be refreshed
  - L28 `void notifyModelSelected(String modelId)`  — Notify that a model has been selected
