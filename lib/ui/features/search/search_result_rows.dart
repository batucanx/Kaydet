import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/date_format.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/actions/message_actions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Arama sonucundaki bir ileti kartı: avatar, gönderen (taslak/gönderilmiş
/// iletilerde alıcı), konu — özet, tarih ve bulunduğu klasör etiketi.
/// Taslaklar başlığın önünde kırmızı `[Taslak]` ile ayırt edilir.
class MailResultRow extends StatelessWidget {
  const MailResultRow({
    super.key,
    required this.message,
    required this.mailbox,
    required this.onTap,
  });

  final MessageRow message;
  final MailboxRow? mailbox;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final counterpart = _counterpartOf(message, mailbox);
    final subject = message.subject.trim().isEmpty
        ? '(konu yok)'
        : message.subject;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BrandAvatar(name: counterpart.name, email: counterpart.email),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              if (message.isDraft)
                                TextSpan(
                                  text: '[Taslak] ',
                                  style: TextStyle(color: t.danger),
                                ),
                              TextSpan(text: counterpart.label),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.listSenderRead.copyWith(
                            color: t.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      Text(
                        formatListDate(message.dateUtc),
                        style: AppText.labelSmall.copyWith(
                          color: t.textTertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: subject,
                          style: AppText.listSubjectRead.copyWith(
                            color: t.textSecondary,
                          ),
                        ),
                        if (message.preview.isNotEmpty)
                          TextSpan(
                            text: '  —  ${message.preview}',
                            style: AppText.listPreview.copyWith(
                              color: t.textTertiary,
                            ),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (mailbox != null) ...[
                    const SizedBox(height: Space.xs),
                    _FolderTag(mailbox: mailbox!),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Satırın başlığındaki kişi: gelen iletilerde gönderen; taslak ve
/// gönderilmiş iletilerde (kendi adresiniz yerine) ilk alıcı — Gelen
/// Kutusu listesindeki `MailRow._displayName` ile aynı kural.
///
/// [name]/[email] avatarın rengini ve harfini belirler, [label] görünen metindir.
({String label, String? name, String? email}) _counterpartOf(
  MessageRow message,
  MailboxRow? mailbox,
) {
  final showsRecipients =
      message.isDraft ||
      mailbox?.specialUse == SpecialUse.sent ||
      mailbox?.specialUse == SpecialUse.drafts;

  if (showsRecipients) {
    final to = EmailAddress.decodeList(message.toAddrJson);
    if (to.isEmpty) return (label: 'Alıcı yok', name: null, email: null);
    final first = to.first;
    final firstName = first.name?.trim() ?? '';
    final label = firstName.isNotEmpty ? firstName : first.email;
    return (
      label: to.length > 1 ? '$label +${to.length - 1}' : label,
      name: first.name,
      email: first.email,
    );
  }

  final label = message.fromName.trim().isNotEmpty
      ? message.fromName
      : (message.fromEmail.trim().isNotEmpty
            ? message.fromEmail
            : 'Bilinmeyen gönderen');
  return (label: label, name: message.fromName, email: message.fromEmail);
}

class _FolderTag extends StatelessWidget {
  const _FolderTag({required this.mailbox});

  final MailboxRow mailbox;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 2),
      decoration: BoxDecoration(
        color: t.surfaceElevated,
        borderRadius: BorderRadius.circular(Radii.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(folderIcon(mailbox.specialUse), size: 11, color: t.textTertiary),
          const SizedBox(width: 4),
          // Kullanıcı klasörlerinin adı sınırsız uzun olabilir.
          Flexible(
            child: Text(
              mailbox.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.labelSmall.copyWith(color: t.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Arama sonucundaki bir kişi kartı.
class ContactResultRow extends StatelessWidget {
  const ContactResultRow({
    super.key,
    required this.contact,
    required this.onTap,
  });

  final ContactRow contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final name = contact.name.trim().isNotEmpty ? contact.name : contact.email;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            BrandAvatar(name: contact.name, email: contact.email),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.listSenderRead.copyWith(
                      color: t.textPrimary,
                    ),
                  ),
                  if (contact.name.trim().isNotEmpty)
                    Text(
                      contact.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.labelSmall.copyWith(
                        color: t.textTertiary,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Arama sonucundaki bir ek dosya kartı — ait olduğu iletinin bağlamıyla
/// (gönderen/konu/tarih) birlikte.
class AttachmentResultRow extends StatelessWidget {
  const AttachmentResultRow({
    super.key,
    required this.result,
    required this.onTap,
  });

  final AttachmentSearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final message = result.message;
    final sender = message.fromName.trim().isNotEmpty
        ? message.fromName
        : message.fromEmail;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            Container(
              width: Dimens.avatarSize,
              height: Dimens.avatarSize,
              decoration: BoxDecoration(
                color: t.surfaceElevated,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                LucideIcons.paperclip,
                size: IconSize.md,
                color: t.textSecondary,
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.attachment.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.listSenderRead.copyWith(
                      color: t.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$sender  —  ${formatBytes(result.attachment.sizeBytes)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.labelSmall.copyWith(color: t.textTertiary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.sm),
            Text(
              formatListDate(message.dateUtc),
              style: AppText.labelSmall.copyWith(color: t.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
