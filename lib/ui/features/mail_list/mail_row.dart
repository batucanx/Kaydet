import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/date_format.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Liste satırı: avatar + (gönderen | tarih) + (konu — özet), sağda sabitle.
///
/// Gerçek Gmail/Outlook uygulamalarındaki gibi iki satıra sıkıştırılır:
/// konu ve önizleme aynı satırda, tek satır taşmayla kısaltılır. Sabitleme
/// (Gmail'in yıldızı) satırın sağında, kendi dokunma alanıyla durur.
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
    required this.onFlagTap,
  });

  final MessageRow message;
  final List<LabelRow> labels;
  final bool isSelected;
  final bool isSentFolder;
  final VoidCallback onTap;
  final VoidCallback onAvatarTap;
  final VoidCallback onLongPress;
  final VoidCallback onFlagTap;

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

  static List<String> _decode(String json) {
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
    try {
      final decoded = jsonDecode(message.labelsJson);
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
              bottom: BorderSide(color: t.divider),
              left: BorderSide(
                color: isSelected ? t.accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            Space.md,
            Space.sm,
            Space.sm,
            Space.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BrandAvatar(
                name: _displayName,
                email: _avatarKey,
                isSelected: isSelected,
                onTap: onAvatarTap,
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _headerRow(context, unread),
                    const SizedBox(height: 2),
                    _subjectLine(context, unread),
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
              _FlagButton(isFlagged: message.isFlagged, onTap: onFlagTap),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerRow(BuildContext context, bool unread) {
    final t = context.tokens;
    return Row(
      children: [
        Expanded(
          child: Text(
            _displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (unread ? AppText.listSenderUnread : AppText.listSenderRead)
                .copyWith(color: unread ? t.textPrimary : t.textSecondary),
          ),
        ),
        const SizedBox(width: Space.sm),
        if (message.hasAttachments)
          Padding(
            padding: const EdgeInsets.only(right: Space.xs),
            child: Icon(LucideIcons.paperclip, size: 13, color: t.textTertiary),
          ),
        Text(
          formatListDate(message.dateUtc),
          style: AppText.labelSmall.copyWith(
            color: unread ? t.accent : t.textTertiary,
            fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ],
    );
  }

  /// Konu ve özet Gmail/Outlook'taki gibi tek satırda, "—" ile ayrılmış.
  ///
  /// Okunmamış durumu burada da tek başına renkle değil, konu bölümünün
  /// yazı kalınlığıyla (üst satırdaki gönderen adı gibi) belirtilir; özet
  /// her zaman soluk kalır — Gmail'de de öyle.
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
          TextSpan(text: subjectText, style: subjectStyle),
          if (message.preview.isNotEmpty)
            TextSpan(
              text: '  —  ${message.preview}',
              style: AppText.listPreview.copyWith(color: t.textTertiary),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

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

/// Sağdaki sabitleme (Gmail'in yıldızı) düğmesi — kendi dokunma alanıyla
/// satırın geri kalanından bağımsız çalışır.
class _FlagButton extends StatelessWidget {
  const _FlagButton({required this.isFlagged, required this.onTap});

  final bool isFlagged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      button: true,
      label: isFlagged ? 'Sabitlemeyi kaldır' : 'Sabitle',
      child: InkResponse(
        onTap: onTap,
        radius: Dimens.touchTarget / 2,
        containedInkWell: false,
        child: SizedBox(
          width: 36,
          height: Dimens.avatarSize,
          child: Icon(
            LucideIcons.pin,
            size: 17,
            color: isFlagged ? t.accent : t.textTertiary.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}
