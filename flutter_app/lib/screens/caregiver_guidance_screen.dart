import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';
import '../models/chat_message.dart';
import '../models/rag_suggestion.dart';
import '../services/rag_service.dart';

/// Chat-based caregiver guidance screen powered by RAG.
///
/// Behaviour:
/// - Starts with a welcome message and disabled input
/// - When AMBER/RED vitals are detected, the system auto-posts a RAG
///   suggestion as a bot message and enables the chat input
/// - User can ask follow-up questions grounded in WHO/IAP guidelines
/// - When vitals return to NORMAL, chat stays but input disables again
class CaregiverGuidanceScreen extends StatefulWidget {
  const CaregiverGuidanceScreen({super.key});

  @override
  State<CaregiverGuidanceScreen> createState() =>
      _CaregiverGuidanceScreenState();
}

class _CaregiverGuidanceScreenState extends State<CaregiverGuidanceScreen>
    with TickerProviderStateMixin {
  final List<ChatMessage> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  StreamSubscription<RagSuggestion>? _ragSub;
  bool _chatEnabled = false;
  bool _isSending = false;
  bool _hasReceivedAutoSuggestion = false;

  // Quick-action suggestions
  static const List<String> _quickActions = [
    'What danger signs should I watch for?',
    'When should I go to the hospital?',
    'Home care tips for my baby',
    'Is this breathing rate normal?',
    'How to check for dehydration?',
  ];

  @override
  void initState() {
    super.initState();

    // Add welcome message
    _messages.add(
      ChatMessage(
        type: MessageType.system,
        content:
            'Welcome to PediaSense Guidance. I provide evidence-based advice from WHO IMCI & IAP guidelines.\n\nChat will activate when vitals need attention.',
      ),
    );

    // Listen for RAG suggestions (auto-triggered from dashboard vitals)
    _ragSub = RagService.instance.suggestionStream.listen(_onAutoSuggestion);

    // Check for cached suggestion
    final cached = RagService.instance.lastSuggestion;
    if (cached != null) {
      _onAutoSuggestion(cached);
    }
  }

  void _onAutoSuggestion(RagSuggestion suggestion) {
    if (!mounted) return;

    // Only add ONE auto-triggered message to the chat.
    // Subsequent vitals-triggered suggestions are ignored to prevent spam.
    if (_hasReceivedAutoSuggestion) return;

    setState(() {
      // Add system alert about vitals
      _messages.add(
        ChatMessage(
          type: MessageType.system,
          content:
              '⚠️ Vitals alert detected — ${suggestion.severity.toUpperCase()} level. Analyzing against WHO & IAP guidelines...',
        ),
      );

      // Remove any existing loading message
      _messages.removeWhere((m) => m.isLoading);

      // Add the RAG response as an assistant message
      _messages.add(
        ChatMessage(
          type: MessageType.assistant,
          content: _formatSuggestionAsChat(suggestion),
          ragData: suggestion,
        ),
      );

      _chatEnabled = true;
      _hasReceivedAutoSuggestion = true;
    });

    _scrollToBottom();
  }

  String _formatSuggestionAsChat(RagSuggestion s) {
    final buf = StringBuffer();
    buf.writeln('**${s.title}**\n');

    if (s.actions.isNotEmpty) {
      buf.writeln('**What you should do:**');
      for (final a in s.actions) {
        buf.writeln('• $a');
      }
      buf.writeln();
    }

    if (s.hospitalCriteria.isNotEmpty) {
      buf.writeln('**⚠️ Go to hospital if:**');
      for (final h in s.hospitalCriteria) {
        buf.writeln('• $h');
      }
    }

    return buf.toString().trim();
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty || _isSending) return;

    final userMsg = ChatMessage(type: MessageType.user, content: text.trim());

    final loadingMsg = ChatMessage(
      type: MessageType.assistant,
      content: '',
      isLoading: true,
    );

    setState(() {
      _messages.add(userMsg);
      _messages.add(loadingMsg);
      _isSending = true;
      _textController.clear();
    });

    _scrollToBottom();

    try {
      final suggestion = await RagService.instance.askQuestion(text.trim());

      if (!mounted) return;

      setState(() {
        // Replace loading with actual response
        final idx = _messages.indexWhere((m) => m.id == loadingMsg.id);
        if (idx >= 0) {
          _messages[idx] = ChatMessage(
            type: MessageType.assistant,
            content: _formatSuggestionAsChat(suggestion),
            ragData: suggestion,
          );
        }
        _isSending = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == loadingMsg.id);
        if (idx >= 0) {
          _messages[idx] = ChatMessage(
            type: MessageType.assistant,
            content:
                'I\'m having trouble connecting right now. Please try again in a moment, or consult your pediatrician directly.',
          );
        }
        _isSending = false;
      });
    }

    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  void dispose() {
    _ragSub?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
        _buildHeader(),

        // Messages
        Expanded(
          child: _messages.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) =>
                      _buildMessage(_messages[index]),
                ),
        ),

        // Quick actions (show when chat is enabled and not sending)
        if (_chatEnabled && !_isSending && _messages.length < 5)
          _buildQuickActions(),

        // Input bar
        _buildInputBar(),
      ],
    );
  }

  // ─── Header ───────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundPaper,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppTheme.primaryMain, AppTheme.primaryLight],
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PediaSense Guide',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  _chatEnabled
                      ? '● Online — WHO & IAP Guidelines'
                      : '○ Waiting for vitals alert...',
                  style: TextStyle(
                    fontSize: 12,
                    color: _chatEnabled
                        ? AppTheme.successMain
                        : AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // Emergency button
          IconButton(
            icon: const Icon(
              Icons.local_hospital,
              color: AppTheme.errorMain,
              size: 24,
            ),
            tooltip: 'Emergency: 112',
            onPressed: () => _launchUrl('tel:112'),
          ),
        ],
      ),
    );
  }

  // ─── Empty State ──────────────────────────────────────────────────────────

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 64,
              color: Colors.grey.shade300,
            ),
            const SizedBox(height: 16),
            Text(
              'No messages yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Message Bubble ───────────────────────────────────────────────────────

  Widget _buildMessage(ChatMessage msg) {
    switch (msg.type) {
      case MessageType.system:
        return _buildSystemMessage(msg);
      case MessageType.user:
        return _buildUserMessage(msg);
      case MessageType.assistant:
        return msg.isLoading
            ? _buildTypingIndicator()
            : _buildAssistantMessage(msg);
    }
  }

  Widget _buildSystemMessage(ChatMessage msg) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.infoMain.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.infoMain.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: AppTheme.infoMain.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg.content,
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserMessage(ChatMessage msg) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(top: 4, bottom: 4, left: 60),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppTheme.primaryMain, AppTheme.primaryDark],
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(4),
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.primaryMain.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          msg.content,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildAssistantMessage(ChatMessage msg) {
    final suggestion = msg.ragData;
    final severityColor = suggestion != null
        ? _getSeverityColor(suggestion.severity)
        : AppTheme.primaryMain;

    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8, right: 40),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar
          Container(
            width: 32,
            height: 32,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [severityColor, severityColor.withValues(alpha: 0.7)],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Colors.white,
              size: 16,
            ),
          ),
          const SizedBox(width: 8),

          // Message content
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.backgroundPaper,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                ),
                border: Border.all(color: severityColor.withValues(alpha: 0.2)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Severity badge
                  if (suggestion != null) ...[
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: severityColor,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            suggestion.severity.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (suggestion.isFromRAG)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.verified,
                                size: 12,
                                color: AppTheme.primaryMain,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '${suggestion.chunksUsed} sources',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppTheme.primaryMain,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],

                  // Message content
                  _buildRichText(msg.content),

                  // Source chips
                  if (suggestion != null && suggestion.sources.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    Text(
                      'Sources',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: suggestion.sources.map((source) {
                        return InkWell(
                          onTap: source.url != null && source.url!.isNotEmpty
                              ? () => _launchUrl(source.url!)
                              : null,
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryMain.withValues(
                                alpha: 0.06,
                              ),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: AppTheme.primaryMain.withValues(
                                  alpha: 0.15,
                                ),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.menu_book,
                                  size: 11,
                                  color: AppTheme.primaryMain,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    source.text,
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: AppTheme.primaryMain,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],

                  // Timestamp
                  const SizedBox(height: 8),
                  Text(
                    _formatTime(msg.timestamp),
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRichText(String text) {
    // Parse simple markdown bold (**text**)
    final spans = <InlineSpan>[];
    final regex = RegExp(r'\*\*(.+?)\*\*');
    int lastEnd = 0;

    for (final match in regex.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(
            text: text.substring(lastEnd, match.start),
            style: const TextStyle(
              fontSize: 13,
              color: AppTheme.textPrimary,
              height: 1.5,
            ),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: match.group(1),
          style: const TextStyle(
            fontSize: 13,
            color: AppTheme.textPrimary,
            fontWeight: FontWeight.w600,
            height: 1.5,
          ),
        ),
      );
      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(lastEnd),
          style: const TextStyle(
            fontSize: 13,
            color: AppTheme.textPrimary,
            height: 1.5,
          ),
        ),
      );
    }

    return RichText(text: TextSpan(children: spans));
  }

  Widget _buildTypingIndicator() {
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8, right: 40),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppTheme.primaryMain, AppTheme.primaryLight],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Colors.white,
              size: 16,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: AppTheme.backgroundPaper,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(18),
              ),
              border: Border.all(
                color: AppTheme.primaryMain.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.primaryMain,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Searching guidelines...',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Quick Actions ────────────────────────────────────────────────────────

  Widget _buildQuickActions() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _quickActions.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            return ActionChip(
              label: Text(
                _quickActions[index],
                style: const TextStyle(fontSize: 12),
              ),
              onPressed: () => _sendMessage(_quickActions[index]),
              backgroundColor: AppTheme.primaryMain.withValues(alpha: 0.06),
              side: BorderSide(
                color: AppTheme.primaryMain.withValues(alpha: 0.2),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            );
          },
        ),
      ),
    );
  }

  // ─── Input Bar ────────────────────────────────────────────────────────────

  Widget _buildInputBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: AppTheme.backgroundPaper,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Text field
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: _chatEnabled
                    ? AppTheme.backgroundDefault
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _chatEnabled
                      ? AppTheme.primaryMain.withValues(alpha: 0.3)
                      : Colors.grey.shade300,
                ),
              ),
              child: TextField(
                controller: _textController,
                focusNode: _focusNode,
                enabled: _chatEnabled && !_isSending,
                maxLines: null,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: _chatEnabled
                      ? 'Ask about your baby\'s health...'
                      : 'Chat activates on vitals alert',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade400,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  isDense: true,
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: _chatEnabled ? _sendMessage : null,
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Send button
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: _chatEnabled && !_isSending
                  ? const LinearGradient(
                      colors: [AppTheme.primaryMain, AppTheme.primaryDark],
                    )
                  : null,
              color: _chatEnabled ? null : Colors.grey.shade300,
              borderRadius: BorderRadius.circular(22),
              boxShadow: _chatEnabled
                  ? [
                      BoxShadow(
                        color: AppTheme.primaryMain.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _chatEnabled && !_isSending
                    ? () => _sendMessage(_textController.text)
                    : null,
                borderRadius: BorderRadius.circular(22),
                child: Icon(
                  _isSending ? Icons.hourglass_top : Icons.send_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  Color _getSeverityColor(String severity) {
    switch (severity) {
      case 'normal':
        return AppTheme.successMain;
      case 'monitor':
        return AppTheme.warningMain;
      case 'urgent':
        return AppTheme.errorMain;
      default:
        return AppTheme.primaryMain;
    }
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
