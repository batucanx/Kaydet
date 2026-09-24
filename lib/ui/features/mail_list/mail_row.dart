import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/date_format.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Liste satırı: avatar + (gönderen | tarih) + konu + 2 satırlık önizleme.
///
/// Yandex Mail benzeri yoğun, kompakt ve net tipografi hiyerarşisi:
/// Gönderen ve konu belirgin (Semibold/Medium), altında en fazla 2 satırlık
/// içerik önizlemesi yer alır.
class MailRow extends StatelessWidget {
  const MailRow({
    super.key,
    required this.message,
    required this.labels,
    required this.isSelected,
    required this.isSentFolder,
    required this.onTap,
    required this.onAvatarTap,
    required this.onLongPress,
  });

  final MessageRow message;
  final List<LabelRow> labels;
  final bool isSelected;
  final bool isSentFolder;
  final VoidCallback onTap;
  final VoidCallback onAvatarTap;
  final VoidCallback onLongPress;

  /// Gönderilenler ve Taslaklar klasöründe alıcı gösterilir.
  String get _displayName {
    if (isSentFolder) {
      final to = _decode(message.toAddrJson);
      if (to.isEmpty) return 'Alıcı yok';
      final first = to.first;
      return to.length > 1 ? '$first +${to.length - 1}' : first;
    }
    if (message.fromName.trim().isNotEmpty) return message.fromName;
    if (message.fromEmail.trim().isNotEmpty) return message.fromEmail;
    return 'Bilinmeyen gönderen';
  }

  String get _avatarKey {
    if (isSentFolder) {
      final to = _decodeEmails(message.toAddrJson);
      return to.isEmpty ? '' : to.first;
    }
    return message.fromEmail;
  }

  /// Boş/`[]` girdide `jsonDecode`'a hiç girmez — Gelen Kutusu'nda her
  /// satırın her build'inde koşulsuz çalışan tek decode olan `_labelNames`
  /// için bu, çoğu iletide (etiketsiz) ayrıştırmayı tamamen atlar.
  static bool _isEmptyJsonList(String json) => json.isEmpty || json == '[]';

  static List<String> _decode(String json) {
    if (_isEmptyJsonList(json)) return const [];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(
            (m) => (m['n'] as String?)?.trim().isNotEmpty == true
                ? m['n'] as String
                : (m['e'] as String? ?? ''),
          )
          .where((s) => s.isNotEmpty)
          .toList();
    } on FormatException {
      return const [];
    }
  }

  static List<String> _decodeEmails(String json) {
    if (_isEmptyJsonList(json)) return const [];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((m) => m['e'] as String? ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    } on FormatException {
      return const [];
    }
  }

  List<String> get _labelNames {
    final json = message.labelsJson;
    if (_isEmptyJsonList(json)) return const [];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      return decoded.whereType<String>().toList();
    } on FormatException {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final unread = !message.isSeen;
    final labelNames = _labelNames;
    final outbox = message.outboxState;
    final previewText = message.preview.trim();

    return Semantics(
      selected: isSelected,
      label: '${unread ? 'Okunmamış. ' : ''}$_displayName. ${message.subject}',
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedContainer(
          duration: context.motion(Motion.fast),
          constraints: const BoxConstraints(minHeight: Dimens.listRowMinHeight),
          decoration: BoxDecoration(
            color: isSelected ? t.accentSubtle : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: isSelected ? t.accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: Space.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Okunmamış noktayı avatarın üzerine al: her satırda boş
              // gösterge rayı ayırmadan metin alanına yer kazandırır.
              SizedBox(
                width: Dimens.touchTarget,
                height: Dimens.touchTarget,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    BrandAvatar(
                      name: _displayName,
                      email: _avatarKey,
                      isSelected: isSelected,
                      onTap: onAvatarTap,
                    ),
                    if (unread)
                      Positioned(
                        left: -6,
                        top: (Dimens.touchTarget - 7) / 2,
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: t.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _senderLine(context, unread),
                    const SizedBox(height: 2),
                    _subjectLine(context, unread),
                    if (previewText.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      _previewLine(context, previewText, unread),
                    ],
                    if (labelNames.isNotEmpty) ...[
                      const SizedBox(height: Space.xs),
                      Wrap(
                        spacing: Space.xs,
                        runSpacing: Space.xs,
                        children: [
                          for (final name in labelNames.take(3))
                            LabelChip(
                              name: name,
                              toneIndex:
                                  labels
                                      .where((l) => l.name == name)
                                      .map((l) => l.toneIndex)
                                      .firstOrNull ??
                                  0,
                            ),
                        ],
                      ),
                    ],
                    if (outbox != OutboxState.none &&
                        outbox != OutboxState.sent) ...[
                      const SizedBox(height: Space.xs),
                      _outboxBadge(context, outbox),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Space.sm),
              _trailingDate(context, unread),
            ],
          ),
        ),
      ),
    );
  }

  Widget _senderLine(BuildContext context, bool unread) {
    final t = context.tokens;
    return Text(
      _displayName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: (unread ? AppText.listSenderUnread : AppText.listSenderRead)
          .copyWith(color: unread ? t.textPrimary : t.textSecondary),
    );
  }

  Widget _trailingDate(BuildContext context, bool unread) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (message.hasAttachments)
            Padding(
              padding: const EdgeInsets.only(right: Space.xs),
              child: Icon(LucideIcons.paperclip, size: 13, color: t.textTertiary),
            ),
          Text(
            formatListDate(
              message.dateUtc,
              locale: Localizations.localeOf(context).languageCode,
            ),
            style: AppText.labelMedium.copyWith(
              color: unread ? t.accent : t.textTertiary,
              fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// Konu satırı — tek satır, taşma durumunda "..." ile kısaltılır.
  /// Yanıtla/İlet ikonları varsa konudan hemen önce yer alır.
  Widget _subjectLine(BuildContext context, bool unread) {
    final t = context.tokens;
    final subjectStyle =
        (unread ? AppText.listSubjectUnread : AppText.listSubjectRead).copyWith(
          color: unread ? t.textPrimary : t.textSecondary,
        );
    final subjectText = message.subject.trim().isEmpty
        ? '(konu yok)'
        : message.subject;

    return Text.rich(
      TextSpan(
        children: [
          if (message.isAnswered) _statusIconSpan(LucideIcons.reply, t),
          if (message.isForwarded) _statusIconSpan(LucideIcons.forward, t),
          TextSpan(text: subjectText, style: subjectStyle),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// Önizleme okunmamış iletide biraz daha kalın, fakat ikincil tonda kalır.
  Widget _previewLine(BuildContext context, String previewText, bool unread) {
    final t = context.tokens;
    return Text(
      previewText,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: AppText.listPreview.copyWith(
        color: unread ? t.textSecondary : t.textTertiary,
        fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
      ),
    );
  }

  /// Yanıtla/İlet göstergesi — Gmail/Outlook'taki gibi konudan hemen önce,
  /// küçük bir ok simgesiyle. `WidgetSpan`: `Text.rich`'in tek satır kısaltma
  /// (`TextOverflow.ellipsis`) davranışını bozmadan simgeyi metne gömer.
  WidgetSpan _statusIconSpan(IconData icon, KaydetTokens t) => WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Icon(icon, size: 13, color: t.textTertiary),
    ),
  );

  Widget _outboxBadge(BuildContext context, OutboxState outbox) {
    final t = context.tokens;
    final (icon, text, color) = switch (outbox) {
      OutboxState.queued => (
        LucideIcons.clock,
        'Gönderilmeyi bekliyor',
        t.textTertiary,
      ),
      OutboxState.sending => (LucideIcons.send, 'Gönderiliyor…', t.accent),
      OutboxState.failed => (
        LucideIcons.triangleAlert,
        message.outboxError ?? 'Gönderilemedi',
        t.danger,
      ),
      _ => (LucideIcons.check, 'Gönderildi', t.success),
    };

    return Row(
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: Space.xs),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.labelSmall.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
