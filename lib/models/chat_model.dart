// lib/models/chat_model.dart
class ModelItem {
  final String name;
  final String value;
  final bool isToggle;
  final String? badge;

  ModelItem({required this.name, required this.value, this.isToggle = false, this.badge});
}