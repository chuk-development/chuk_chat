// lib/services/chat_storage_service.dart
import 'package:shared_preferences/shared_preferences.dart';

class ChatStorageService {
  static List<String> _savedChats = [];
  static int _selectedChatIndex = -1;

  static List<String> get savedChats => _savedChats;
  static int get selectedChatIndex => _selectedChatIndex;
  static set selectedChatIndex(int index) => _selectedChatIndex = index;

  static Future<void> loadChats() async {
    final prefs = await SharedPreferences.getInstance();
    _savedChats = prefs.getStringList('savedChats') ?? [];
  }

  static Future<void> saveChat(String json) async {
    final prefs = await SharedPreferences.getInstance();
    _savedChats.add(json);
    await prefs.setStringList('savedChats', _savedChats);
    await loadSavedChatsForSidebar();
  }

  // This is used by sidebar to refresh its view of saved chats
  static Future<void> loadSavedChatsForSidebar() async {
    await loadChats(); // Ensure the list is up-to-date
    // If there's a listener, notify it here
    // For now, widgets will need to call setState themselves or use a listener
  }
}