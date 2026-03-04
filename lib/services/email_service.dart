// lib/services/email_service.dart
//
// IMAP/SMTP email service using the enough_mail package.
// Provides mailbox listing, email search, read, send, delete, and move.
// Sending emails ALWAYS requires user approval via the approval callback.

import 'dart:async';
import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Actions that may require user approval before execution.
enum EmailAction { sendEmail, deleteEmail, moveEmail, markAsRead }

/// Callback type for requesting user approval before destructive actions.
///
/// Returns `true` if the user approves the action, `false` to cancel.
/// [action] identifies what kind of operation is requested.
/// [details] is a human-readable summary of what will happen.
typedef EmailApprovalCallback =
    Future<bool> Function(EmailAction action, String details);

/// Email account configuration for IMAP/SMTP connections.
///
/// Includes factory constructors for common providers with sensible defaults.
class EmailConfig {
  final String email;
  final String password;
  final String imapHost;
  final int imapPort;
  final bool imapUseSsl;
  final String smtpHost;
  final int smtpPort;
  final bool smtpUseSsl;
  final String? displayName;

  const EmailConfig({
    required this.email,
    required this.password,
    required this.imapHost,
    this.imapPort = 993,
    this.imapUseSsl = true,
    required this.smtpHost,
    this.smtpPort = 587,
    this.smtpUseSsl = true,
    this.displayName,
  });

  /// Gmail preset (requires app-specific password with 2FA).
  factory EmailConfig.gmail({
    required String email,
    required String password,
    String? displayName,
  }) => EmailConfig(
    email: email,
    password: password,
    imapHost: 'imap.gmail.com',
    imapPort: 993,
    imapUseSsl: true,
    smtpHost: 'smtp.gmail.com',
    smtpPort: 587,
    smtpUseSsl: true,
    displayName: displayName,
  );

  /// Outlook / Hotmail / Live preset.
  factory EmailConfig.outlook({
    required String email,
    required String password,
    String? displayName,
  }) => EmailConfig(
    email: email,
    password: password,
    imapHost: 'outlook.office365.com',
    imapPort: 993,
    imapUseSsl: true,
    smtpHost: 'smtp.office365.com',
    smtpPort: 587,
    smtpUseSsl: true,
    displayName: displayName,
  );

  /// Yahoo Mail preset.
  factory EmailConfig.yahoo({
    required String email,
    required String password,
    String? displayName,
  }) => EmailConfig(
    email: email,
    password: password,
    imapHost: 'imap.mail.yahoo.com',
    imapPort: 993,
    imapUseSsl: true,
    smtpHost: 'smtp.mail.yahoo.com',
    smtpPort: 587,
    smtpUseSsl: true,
    displayName: displayName,
  );

  Map<String, dynamic> toJson() => {
    'email': email,
    'password': password,
    'imapHost': imapHost,
    'imapPort': imapPort,
    'imapUseSsl': imapUseSsl,
    'smtpHost': smtpHost,
    'smtpPort': smtpPort,
    'smtpUseSsl': smtpUseSsl,
    if (displayName != null) 'displayName': displayName,
  };

  factory EmailConfig.fromJson(Map<String, dynamic> json) => EmailConfig(
    email: json['email'] as String,
    password: json['password'] as String,
    imapHost: json['imapHost'] as String,
    imapPort: json['imapPort'] as int? ?? 993,
    imapUseSsl: json['imapUseSsl'] as bool? ?? true,
    smtpHost: json['smtpHost'] as String,
    smtpPort: json['smtpPort'] as int? ?? 587,
    smtpUseSsl: json['smtpUseSsl'] as bool? ?? true,
    displayName: json['displayName'] as String?,
  );
}

/// Helper to build IMAP SEARCH query strings.
class SearchQueryBuilder {
  final List<String> _parts = [];

  /// Match messages from a specific sender.
  SearchQueryBuilder from(String address) {
    _parts.add('FROM "$address"');
    return this;
  }

  /// Match messages sent to a specific address.
  SearchQueryBuilder to(String address) {
    _parts.add('TO "$address"');
    return this;
  }

  /// Match subject containing text.
  SearchQueryBuilder subject(String text) {
    _parts.add('SUBJECT "$text"');
    return this;
  }

  /// Match body containing text.
  SearchQueryBuilder body(String text) {
    _parts.add('BODY "$text"');
    return this;
  }

  /// Full-text search (subject + body).
  SearchQueryBuilder text(String text) {
    _parts.add('TEXT "$text"');
    return this;
  }

  /// Messages received since a date (inclusive). Format: DD-Mon-YYYY.
  SearchQueryBuilder since(DateTime date) {
    _parts.add('SINCE ${_formatDate(date)}');
    return this;
  }

  /// Messages received before a date. Format: DD-Mon-YYYY.
  SearchQueryBuilder before(DateTime date) {
    _parts.add('BEFORE ${_formatDate(date)}');
    return this;
  }

  /// Only unseen messages.
  SearchQueryBuilder unseen() {
    _parts.add('UNSEEN');
    return this;
  }

  /// Only seen messages.
  SearchQueryBuilder seen() {
    _parts.add('SEEN');
    return this;
  }

  /// Only flagged messages.
  SearchQueryBuilder flagged() {
    _parts.add('FLAGGED');
    return this;
  }

  /// Build the final IMAP search string.
  String build() {
    if (_parts.isEmpty) return 'ALL';
    return _parts.join(' ');
  }

  static String _formatDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${date.day}-${months[date.month - 1]}-${date.year}';
  }
}

/// IMAP/SMTP email service.
///
/// Manages email account connections and provides mailbox operations including
/// listing, reading, searching, sending, deleting, and moving messages.
///
/// **Security**: Sending emails ALWAYS requires user approval via the
/// configured [EmailApprovalCallback]. If no callback is set, send operations
/// are refused outright.
class EmailService {
  ImapClient? _imapClient;
  SmtpClient? _smtpClient;
  EmailConfig? _config;
  EmailApprovalCallback? _approvalCallback;

  bool get isConnected => _imapClient?.isLoggedIn ?? false;
  bool get isConfigured => _config != null;
  EmailConfig? get config => _config;

  /// Set the approval callback. Must be set before calling [sendEmail].
  void setApprovalCallback(EmailApprovalCallback callback) {
    _approvalCallback = callback;
  }

  // ---------------------------------------------------------------------------
  // Config persistence
  // ---------------------------------------------------------------------------

  /// Load a previously saved email configuration from SharedPreferences.
  Future<EmailConfig?> loadSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('email_config');
    if (raw == null) return null;
    try {
      _config = EmailConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      return _config;
    } catch (_) {
      return null;
    }
  }

  /// Save the current configuration to SharedPreferences.
  Future<void> saveConfig(EmailConfig config) async {
    _config = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('email_config', jsonEncode(config.toJson()));
  }

  /// Remove saved configuration from SharedPreferences and disconnect.
  Future<void> clearConfig() async {
    await disconnect();
    _config = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('email_config');
  }

  // ---------------------------------------------------------------------------
  // Connection management
  // ---------------------------------------------------------------------------

  /// Connect to the IMAP server using the current configuration.
  ///
  /// Returns a result map with `success` and optional `error`.
  Future<Map<String, dynamic>> connect({EmailConfig? config}) async {
    final cfg = config ?? _config;
    if (cfg == null) {
      return {'success': false, 'error': 'No email configuration provided'};
    }
    _config = cfg;

    try {
      // IMAP
      _imapClient = ImapClient(isLogEnabled: false);
      await _imapClient!.connectToServer(
        cfg.imapHost,
        cfg.imapPort,
        isSecure: cfg.imapUseSsl,
      );
      await _imapClient!.login(cfg.email, cfg.password);

      return {'success': true};
    } catch (e) {
      _imapClient = null;
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Disconnect from both IMAP and SMTP servers.
  Future<void> disconnect() async {
    try {
      if (_imapClient?.isLoggedIn ?? false) {
        await _imapClient!.logout();
      }
    } catch (_) {
      // Best-effort disconnect
    }
    _imapClient = null;

    try {
      if (_smtpClient != null) {
        await _smtpClient!.quit();
      }
    } catch (_) {
      // Best-effort disconnect
    }
    _smtpClient = null;
  }

  /// Test the connection by logging in and immediately logging out.
  Future<Map<String, dynamic>> testConnection(EmailConfig config) async {
    ImapClient? testClient;
    try {
      testClient = ImapClient(isLogEnabled: false);
      await testClient.connectToServer(
        config.imapHost,
        config.imapPort,
        isSecure: config.imapUseSsl,
      );
      await testClient.login(config.email, config.password);
      await testClient.logout();
      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    } finally {
      try {
        await testClient?.disconnect();
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Mailbox operations
  // ---------------------------------------------------------------------------

  /// List all available mailboxes (folders).
  Future<Map<String, dynamic>> listMailboxes() async {
    if (!isConnected) {
      return {'success': false, 'error': 'Not connected to IMAP server'};
    }
    try {
      final mailboxes = await _imapClient!.listMailboxes();
      final result = mailboxes.map((m) {
        return {
          'name': m.name,
          'path': m.path,
          'isInbox': m.isInbox,
          'hasChildren': m.hasChildren,
          'flags': m.flags.map((f) => f.toString()).toList(),
        };
      }).toList();
      return {'success': true, 'mailboxes': result};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// List emails in a mailbox with pagination.
  ///
  /// [mailbox] is the mailbox path (e.g. 'INBOX').
  /// [limit] is the maximum number of messages to return.
  /// [offset] is the number of messages to skip from the end (newest first).
  Future<Map<String, dynamic>> listEmails(
    String mailbox, {
    int limit = 20,
    int offset = 0,
  }) async {
    if (!isConnected) {
      return {'success': false, 'error': 'Not connected to IMAP server'};
    }
    try {
      final box = await _imapClient!.selectMailboxByPath(mailbox);
      final total = box.messagesExists;
      if (total == 0) {
        return {'success': true, 'emails': [], 'total': 0};
      }

      // Calculate sequence range (newest first)
      final end = total - offset;
      final start = (end - limit + 1).clamp(1, end);
      if (end < 1) {
        return {'success': true, 'emails': [], 'total': total};
      }

      final sequence = MessageSequence.fromRange(start, end);
      final fetchResult = await _imapClient!.fetchMessages(
        sequence,
        '(FLAGS ENVELOPE RFC822.SIZE)',
      );

      final emails = fetchResult.messages.reversed.map((msg) {
        return _messageToMap(msg);
      }).toList();

      return {'success': true, 'emails': emails, 'total': total};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Search emails in a mailbox using IMAP SEARCH criteria.
  ///
  /// All search parameters are optional; combine as needed.
  Future<Map<String, dynamic>> searchEmails(
    String mailbox, {
    String? from,
    String? to,
    String? subject,
    String? body,
    String? text,
    DateTime? since,
    DateTime? before,
    bool unreadOnly = false,
    int limit = 50,
  }) async {
    if (!isConnected) {
      return {'success': false, 'error': 'Not connected to IMAP server'};
    }
    try {
      await _imapClient!.selectMailboxByPath(mailbox);

      final qb = SearchQueryBuilder();
      if (from != null) qb.from(from);
      if (to != null) qb.to(to);
      if (subject != null) qb.subject(subject);
      if (body != null) qb.body(body);
      if (text != null) qb.text(text);
      if (since != null) qb.since(since);
      if (before != null) qb.before(before);
      if (unreadOnly) qb.unseen();

      final searchResult = await _imapClient!.searchMessages(
        searchCriteria: qb.build(),
      );

      if (searchResult.matchingSequence == null ||
          searchResult.matchingSequence!.toList().isEmpty) {
        return {'success': true, 'emails': [], 'total': 0};
      }

      // Limit results
      var seq = searchResult.matchingSequence!;
      final ids = seq.toList();
      if (ids.length > limit) {
        final trimmed = ids.sublist(ids.length - limit);
        seq = MessageSequence();
        for (final id in trimmed) {
          seq.add(id);
        }
      }

      final fetchResult = await _imapClient!.fetchMessages(
        seq,
        '(FLAGS ENVELOPE RFC822.SIZE)',
      );

      final emails = fetchResult.messages.reversed.map((msg) {
        return _messageToMap(msg);
      }).toList();

      return {
        'success': true,
        'emails': emails,
        'total': searchResult.matchingSequence!.toList().length,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ---------------------------------------------------------------------------
  // Message operations
  // ---------------------------------------------------------------------------

  /// Read a specific email by sequence ID.
  ///
  /// Returns the full message body (plain text and/or HTML).
  /// Optionally marks the message as read.
  Future<Map<String, dynamic>> readEmail(
    String mailbox,
    int sequenceId, {
    bool markAsRead = true,
  }) async {
    if (!isConnected) {
      return {'success': false, 'error': 'Not connected to IMAP server'};
    }
    try {
      await _imapClient!.selectMailboxByPath(mailbox);

      final sequence = MessageSequence.fromId(sequenceId);
      final fetchResult = await _imapClient!.fetchMessages(
        sequence,
        '(FLAGS ENVELOPE BODY[] RFC822.SIZE)',
      );

      if (fetchResult.messages.isEmpty) {
        return {'success': false, 'error': 'Message not found'};
      }

      final msg = fetchResult.messages.first;
      final mime = msg.decodeContentMessage();

      String? textBody;
      String? htmlBody;
      final attachments = <Map<String, dynamic>>[];

      if (mime != null) {
        textBody = mime.decodeTextPlainPart();
        htmlBody = mime.decodeTextHtmlPart();

        // Collect attachment info (names and sizes, not full content)
        for (final part in mime.allPartsFlat) {
          final disposition = part.getHeaderContentDisposition();
          if (disposition != null &&
              disposition.disposition == ContentDisposition.attachment) {
            attachments.add({
              'filename': disposition.filename ?? 'unnamed',
              'contentType': part.mediaType.text,
            });
          }
        }
      }

      // Mark as read if requested
      if (markAsRead) {
        try {
          await _imapClient!.store(sequence, [
            MessageFlags.seen,
          ], action: StoreAction.add);
        } catch (_) {
          // Non-critical — continue even if marking fails
        }
      }

      final result = _messageToMap(msg);
      result['textBody'] = textBody;
      result['htmlBody'] = htmlBody;
      result['attachments'] = attachments;

      return {'success': true, 'email': result};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Send an email via SMTP.
  ///
  /// **ALWAYS** requires user approval via [_approvalCallback].
  /// If no callback is configured, the operation is refused.
  Future<Map<String, dynamic>> sendEmail({
    required String to,
    required String subject,
    required String body,
    List<String>? cc,
    List<String>? bcc,
    bool isHtml = false,
  }) async {
    if (_config == null) {
      return {'success': false, 'error': 'Email is not configured'};
    }

    // Approval is MANDATORY for sending
    if (_approvalCallback == null) {
      return {
        'success': false,
        'error':
            'No approval callback configured. '
            'Sending email requires user approval.',
      };
    }

    final recipients = [to, ...?cc, ...?bcc];
    final details =
        'Send email to ${recipients.join(", ")}\n'
        'Subject: $subject\n'
        'Body length: ${body.length} characters';

    final approved = await _approvalCallback!(EmailAction.sendEmail, details);
    if (!approved) {
      return {'success': false, 'error': 'User declined to send email'};
    }

    try {
      final fromAddress = MailAddress(
        _config!.displayName ?? _config!.email,
        _config!.email,
      );

      final builder = MessageBuilder.prepareMultipartAlternativeMessage()
        ..from = [fromAddress]
        ..to = [MailAddress(null, to)]
        ..subject = subject;

      if (cc != null) {
        builder.cc = cc.map((a) => MailAddress(null, a)).toList();
      }
      if (bcc != null) {
        builder.bcc = bcc.map((a) => MailAddress(null, a)).toList();
      }

      if (isHtml) {
        builder.addTextHtml(body);
        // Also add a plain-text fallback (strip tags naively)
        builder.addTextPlain(body.replaceAll(RegExp(r'<[^>]*>'), ''));
      } else {
        builder.addTextPlain(body);
      }

      final message = builder.buildMimeMessage();

      // Connect SMTP
      _smtpClient = SmtpClient(_config!.smtpHost, isLogEnabled: false);
      await _smtpClient!.connectToServer(
        _config!.smtpHost,
        _config!.smtpPort,
        isSecure: _config!.smtpPort == 465,
      );
      await _smtpClient!.ehlo();

      // STARTTLS for port 587
      if (_config!.smtpPort == 587) {
        await _smtpClient!.startTls();
      }

      await _smtpClient!.authenticate(
        _config!.email,
        _config!.password,
        AuthMechanism.plain,
      );
      await _smtpClient!.sendMessage(message);
      await _smtpClient!.quit();
      _smtpClient = null;

      return {'success': true, 'message': 'Email sent successfully'};
    } catch (e) {
      try {
        await _smtpClient?.quit();
      } catch (_) {}
      _smtpClient = null;
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Delete an email from a mailbox.
  ///
  /// When [permanent] is false, moves to Trash instead (if Trash exists).
  /// When [permanent] is true, sets the \Deleted flag and expunges.
  Future<Map<String, dynamic>> deleteEmail(
    String mailbox,
    int sequenceId, {
    bool permanent = false,
  }) async {
    if (!isConnected) {
      return {'success': false, 'error': 'Not connected to IMAP server'};
    }

    // Request approval for delete
    if (_approvalCallback != null) {
      final details = permanent
          ? 'Permanently delete message #$sequenceId from $mailbox'
          : 'Move message #$sequenceId from $mailbox to Trash';
      final approved = await _approvalCallback!(
        EmailAction.deleteEmail,
        details,
      );
      if (!approved) {
        return {'success': false, 'error': 'User declined to delete email'};
      }
    }

    try {
      await _imapClient!.selectMailboxByPath(mailbox);
      final sequence = MessageSequence.fromId(sequenceId);

      if (permanent) {
        await _imapClient!.store(sequence, [
          MessageFlags.deleted,
        ], action: StoreAction.add);
        await _imapClient!.expunge();
      } else {
        // Try to move to Trash
        final trashNames = ['Trash', '[Gmail]/Trash', 'Deleted Items'];
        String? trashPath;
        try {
          final mailboxes = await _imapClient!.listMailboxes();
          for (final name in trashNames) {
            final match = mailboxes
                .where(
                  (m) =>
                      m.path.toLowerCase() == name.toLowerCase() ||
                      m.name.toLowerCase() == name.toLowerCase(),
                )
                .toList();
            if (match.isNotEmpty) {
              trashPath = match.first.path;
              break;
            }
          }
        } catch (_) {}

        if (trashPath != null) {
          await _imapClient!.selectMailboxByPath(mailbox);
          await _imapClient!.copy(sequence, targetMailboxPath: trashPath);
          await _imapClient!.store(sequence, [
            MessageFlags.deleted,
          ], action: StoreAction.add);
          await _imapClient!.expunge();
        } else {
          // No Trash folder found — flag as deleted
          await _imapClient!.store(sequence, [
            MessageFlags.deleted,
          ], action: StoreAction.add);
          await _imapClient!.expunge();
        }
      }

      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Move an email from one mailbox to another (IMAP COPY + DELETE).
  Future<Map<String, dynamic>> moveEmail(
    String sourceMailbox,
    int sequenceId,
    String destinationMailbox,
  ) async {
    if (!isConnected) {
      return {'success': false, 'error': 'Not connected to IMAP server'};
    }

    if (_approvalCallback != null) {
      final details =
          'Move message #$sequenceId from $sourceMailbox to $destinationMailbox';
      final approved = await _approvalCallback!(EmailAction.moveEmail, details);
      if (!approved) {
        return {'success': false, 'error': 'User declined to move email'};
      }
    }

    try {
      await _imapClient!.selectMailboxByPath(sourceMailbox);
      final sequence = MessageSequence.fromId(sequenceId);

      await _imapClient!.copy(sequence, targetMailboxPath: destinationMailbox);
      await _imapClient!.store(sequence, [
        MessageFlags.deleted,
      ], action: StoreAction.add);
      await _imapClient!.expunge();

      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Mark an email as read (set \Seen flag).
  Future<Map<String, dynamic>> markAsRead(
    String mailbox,
    int sequenceId,
  ) async {
    if (!isConnected) {
      return {'success': false, 'error': 'Not connected to IMAP server'};
    }
    try {
      await _imapClient!.selectMailboxByPath(mailbox);
      final sequence = MessageSequence.fromId(sequenceId);
      await _imapClient!.store(sequence, [
        MessageFlags.seen,
      ], action: StoreAction.add);
      return {'success': true};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Get the number of unread (unseen) messages in a mailbox.
  Future<Map<String, dynamic>> getUnreadCount(String mailbox) async {
    if (!isConnected) {
      return {'success': false, 'error': 'Not connected to IMAP server'};
    }
    try {
      final box = await _imapClient!.selectMailboxByPath(mailbox);
      // Use STATUS query for UNSEEN count
      final statusResult = await _imapClient!.statusMailbox(box, [
        StatusFlags.unseen,
      ]);
      return {
        'success': true,
        'unread': statusResult.messagesUnseen,
        'total': box.messagesExists,
      };
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Convert a [MimeMessage] into a serializable map for tool results.
  Map<String, dynamic> _messageToMap(MimeMessage msg) {
    final envelope = msg.envelope;
    return {
      'sequenceId': msg.sequenceId,
      'uid': msg.uid,
      'subject': envelope?.subject ?? msg.decodeSubject() ?? '(no subject)',
      'from': _addressListToString(envelope?.from ?? msg.from),
      'to': _addressListToString(envelope?.to ?? msg.to),
      'cc': _addressListToString(envelope?.cc ?? msg.cc),
      'date':
          envelope?.date?.toIso8601String() ??
          msg.decodeDate()?.toIso8601String(),
      'size': msg.size,
      'flags': msg.flags?.map((f) => f.toString()).toList() ?? [],
      'isRead': msg.isSeen,
      'isFlagged': msg.isFlagged,
    };
  }

  /// Format a list of [MailAddress] into a readable string.
  String? _addressListToString(List<MailAddress>? addresses) {
    if (addresses == null || addresses.isEmpty) return null;
    return addresses
        .map((a) {
          if (a.personalName != null && a.personalName!.isNotEmpty) {
            return '${a.personalName} <${a.email}>';
          }
          return a.email;
        })
        .join(', ');
  }
}
