import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../data/database/app_database.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import 'new_signature_sheet.dart';

/// İmzalar alt sayfası: imza listesi, oluşturma, düzenleme ve varsayılan
/// seçimi.
class SignaturesSettingsScreen extends ConsumerWidget {
  const SignaturesSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final account = ref.watch(activeAccountProvider).value;
    final all = ref.watch(signaturesProvider).value ?? const <SignatureRow>[];
    // Varsayılan imza her zaman en üstte.
    final signatures = [
      ...all.where((s) => s.isDefault),
      ...all.where((s) => !s.isDefault),
    ];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('İmzalar'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          SectionHeader(
            'İMZALAR',
            trailing: IconButton(
              icon: const Icon(LucideIcons.plus, size: IconSize.md),
              tooltip: 'İmza ekle',
              onPressed: account == null
                  ? null
                  : () => showNewSignatureSheet(context, ref, accountId: account.id),
            ),
          ),
          SettingsGroup(
            children: [
              if (signatures.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Text(
                    'Henüz imza yok. Kullanıcı isterse birden fazla imza '
                    'ekleyip yazarken aralarında seçim yapabilir.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: t.textTertiary),
                  ),
                )
              else
                for (final signature in signatures)
                  _SignatureListTile(
                    signature: signature,
                    onTap: () => showNewSignatureSheet(
                      context,
                      ref,
                      accountId: signature.accountId,
                      existingSignature: signature,
                    ),
                    onSetDefault: () => ref
                        .read(accountRepositoryProvider)
                        .setDefaultSignature(signature.accountId, signature.id),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

/// İmza listesindeki tek satır: ad + görsel rozeti / gövdenin ilk satırı önizleme olarak,
/// sağda varsayılan rozeti (veya varsayılan yapma yıldızı) ve düzenleme oku.
class _SignatureListTile extends StatelessWidget {
  const _SignatureListTile({
    required this.signature,
    required this.onTap,
    required this.onSetDefault,
  });

  final SignatureRow signature;
  final VoidCallback onTap;
  final VoidCallback onSetDefault;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hasImage = signature.imageType == 'remote';
    final preview = signature.body.trim();

    String subtitleText;
    if (preview.isNotEmpty) {
      subtitleText = preview.split('\n').first;
    } else if (hasImage) {
      subtitleText = 'Uzak Görsel İmza';
    } else {
      subtitleText = 'Boş imza';
    }

    return SettingsTile(
      icon: hasImage ? LucideIcons.image : LucideIcons.penLine,
      title: signature.name,
      subtitle: subtitleText,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasImage) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.xs,
                vertical: 2,
              ),
              margin: const EdgeInsets.only(right: Space.xs),
              decoration: BoxDecoration(
                color: t.surfaceDeep,
                borderRadius: BorderRadius.circular(Radii.xs),
                border: Border.all(color: t.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.globe,
                    size: 11,
                    color: t.textSecondary,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    'URL',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          color: t.textSecondary,
                        ),
                  ),
                ],
              ),
            ),
          ],
          if (signature.isDefault)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.sm,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: t.accentSubtle,
                borderRadius: BorderRadius.circular(Radii.full),
              ),
              child: Text(
                'Varsayılan',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: t.accent),
              ),
            )
          else
            IconButton(
              icon: Icon(LucideIcons.star, size: 18, color: t.textTertiary),
              tooltip: 'Varsayılan yap',
              onPressed: onSetDefault,
            ),
          const SizedBox(width: Space.xs),
          Icon(LucideIcons.chevronRight, size: 18, color: t.textTertiary),
        ],
      ),
    );
  }
}
