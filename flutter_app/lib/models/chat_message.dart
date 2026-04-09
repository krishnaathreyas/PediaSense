// PediaSense — Chat Message model for the RAG chat interface

import 'rag_suggestion.dart';

enum MessageType { user, assistant, system }

class ChatMessage {
  final String id;
  final MessageType type;
  final String content;
  final RagSuggestion? ragData; // structured data for assistant messages
  final DateTime timestamp;
  final bool isLoading; // true while waiting for RAG response

  ChatMessage({
    String? id,
    required this.type,
    required this.content,
    this.ragData,
    DateTime? timestamp,
    this.isLoading = false,
  })  : id = id ?? '${DateTime.now().millisecondsSinceEpoch}_${type.name}',
        timestamp = timestamp ?? DateTime.now();

  ChatMessage copyWith({
    String? content,
    RagSuggestion? ragData,
    bool? isLoading,
  }) {
    return ChatMessage(
      id: id,
      type: type,
      content: content ?? this.content,
      ragData: ragData ?? this.ragData,
      timestamp: timestamp,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}
