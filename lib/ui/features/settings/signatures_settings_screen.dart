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
    final signatures =
        ref.watch(signaturesProvider).value ?? const <SignatureRow>[];

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
                    onTap: () => _editSignature(context, ref, signature),
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

  Future<void> _editSignature(
    BuildContext context,
    WidgetRef ref,
    SignatureRow signature,
  ) async {
    final t = context.tokens;
    final nameController = TextEditingController(text: signature.name);
    final bodyController = TextEditingController(text: signature.body);

    final result = await showDialog<_SignatureDialogResult>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('İmzayı düzenle')),
            IconButton(
              icon: Icon(LucideIcons.trash2, size: 20, color: t.danger),
              tooltip: 'Sil',
              onPressed: () =>
                  Navigator.of(context).pop(_SignatureDialogResult.delete),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(controller: nameController, autofocus: true),
              const SizedBox(height: Space.lg),
              TextField(controller: bodyController, maxLines: 6, minLines: 3),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          DialogActions(
            cancelLabel: 'Vazgeç',
            onCancel: () => Navigator.of(context).pop(),
            confirmLabel: 'Kaydet',
            onConfirm: () =>
                Navigator.of(context).pop(_SignatureDialogResult.save),
          ),
        ],
      ),
    );

    switch (result) {
      case _SignatureDialogResult.save:
        final name = nameController.text.trim();
        if (name.isEmpty) return;
        await ref
            .read(accountRepositoryProvider)
            .updateSignatureContent(
              signatureId: signature.id,
              name: name,
              body: bodyController.text,
            );
      case _SignatureDialogResult.delete:
        await ref.read(accountRepositoryProvider).deleteSignature(signature.id);
      case null:
        return;
    }
  }
}

/// [SignaturesSettingsScreen._editSignature] diyaloğunun sonucu.
enum _SignatureDialogResult { save, delete }

/// İmza listesindeki tek satır: ad + gövdenin ilk satırı önizleme olarak,
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
    final preview = signature.body.trim();

    return SettingsTile(
      icon: LucideIcons.penLine,
      title: signature.name,
      subtitle: preview.isEmpty ? 'Boş' : preview.split('\n').first,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
