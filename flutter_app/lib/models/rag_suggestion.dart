// PediaSense — RAG Suggestion model
//
// Represents a structured suggestion from the RAG Edge Function,
// grounded in WHO IMCI and IAP guidelines.

class SourceChunk {
  final String text;
  final String? url;
  final double? similarity;

  SourceChunk({required this.text, this.url, this.similarity});

  factory SourceChunk.fromJson(Map<String, dynamic> json) {
    return SourceChunk(
      text: json['text'] as String? ?? '',
      url: json['url'] as String?,
      similarity: (json['similarity'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'text': text,
        'url': url,
        'similarity': similarity,
      };
}

class RagSuggestion {
  final String title;
  final String severity; // 'normal', 'monitor', 'urgent'
  final List<String> actions;
  final List<String> hospitalCriteria;
  final List<SourceChunk> sources;
  final String? query;
  final int chunksUsed;
  final DateTime timestamp;
  final bool isFromRAG; // false = local fallback was used

  RagSuggestion({
    required this.title,
    required this.severity,
    required this.actions,
    required this.hospitalCriteria,
    required this.sources,
    this.query,
    this.chunksUsed = 0,
    DateTime? timestamp,
    this.isFromRAG = true,
  }) : timestamp = timestamp ?? DateTime.now();

  factory RagSuggestion.fromJson(Map<String, dynamic> json) {
    return RagSuggestion(
      title: json['title'] as String? ?? 'Health Alert',
      severity: json['severity'] as String? ?? 'monitor',
      actions: (json['actions'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      hospitalCriteria: (json['hospitalCriteria'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      sources: (json['sources'] as List<dynamic>?)
              ?.map((e) => SourceChunk.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      query: json['query'] as String?,
      chunksUsed: json['chunksUsed'] as int? ?? 0,
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
          : DateTime.now(),
      isFromRAG: json['error'] == null, // if error field present, it's a fallback
    );
  }

  /// Safe local fallback when the Edge Function is unavailable.
  factory RagSuggestion.localFallback(String severity) {
    return RagSuggestion(
      title: severity == 'urgent'
          ? 'Urgent: Seek Medical Attention'
          : 'Health Alert — Monitor Closely',
      severity: severity,
      actions: [
        'Continue monitoring your baby\'s vital signs.',
        'Ensure your baby is comfortable, fed, and well-hydrated.',
        'Note the time and values of any abnormal readings.',
        'Consult your pediatrician if you have any concerns.',
      ],
      hospitalCriteria: [
        'Difficulty breathing or visible chest indrawing.',
        'Baby becomes lethargic, unresponsive, or refuses to feed.',
        'Skin turns blue or grey around lips, tongue, or trunk.',
        'Temperature above 38.5°C or below 35.5°C that does not improve.',
        'No wet diaper for more than 6 hours.',
      ],
      sources: [
        SourceChunk(
          text: 'WHO IMCI — General Danger Signs',
          url: 'https://iris.who.int/handle/10665/104772',
        ),
      ],
      isFromRAG: false,
    );
  }
}
