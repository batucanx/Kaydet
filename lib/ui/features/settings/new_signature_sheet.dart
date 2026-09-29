import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Yeni imza oluşturma penceresi — yazma ekranındaki imza menüsü ve Ayarlar →
/// İmzalar aynı pencereyi kullanır.
///
/// Dar bir iletişim kutusu yerine ekranın büyük bölümünü kaplayan bir alt
/// sayfadır: imza metni uzun/çok satırlı olabildiği için yazma alanı kalan
/// boşluğu doldurur ve klavye açılınca yukarı kayar. Kaydetme mevcut
/// `AccountRepository.createSignature`'ı çağırır (hesabın ilk imzası
/// otomatik varsayılan olur); yeni bir imza mantığı yoktur.
Future<void> showNewSignatureSheet(
  BuildContext context,
  WidgetRef ref, {
  required int accountId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    sheetAnimationStyle: AnimationStyle(
      duration: context.motion(Motion.base),
      reverseDuration: context.motion(Motion.fast),
      curve: Motion.standard,
    ),
    builder: (_) => _NewSignatureSheet(accountId: accountId),
  );
}

class _NewSignatureSheet extends ConsumerStatefulWidget {
  const _NewSignatureSheet({required this.accountId});

  final int accountId;

  @override
  ConsumerState<_NewSignatureSheet> createState() => _NewSignatureSheetState();
}

class _NewSignatureSheetState extends ConsumerState<_NewSignatureSheet> {
  final _name = TextEditingController();
  final _body = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _canSave => !_saving && _name.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(accountRepositoryProvider)
          .createSignature(
            accountId: widget.accountId,
            name: _name.text.trim(),
            body: _body.text,
          );
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SizedBox(
        // Klavyesizken ekranın büyük kısmı; klavye açılınca kalan alana
        // sığar (dış `Padding` yukarı iter, `Expanded` küçülür).
        height: size.height * 0.85 - keyboard.clamp(0, size.height * 0.5),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.xl,
            0,
            Space.xl,
            Space.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Yeni imza',
                      style: AppText.titleLarge.copyWith(
                        color: t.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.x),
                    tooltip: 'Kapat',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: Space.md),
              Text(
                'İmza adı',
                style: textTheme.labelMedium?.copyWith(
                  color: t.textSecondary,
                ),
              ),
              const SizedBox(height: Space.xs),
              TextField(
                controller: _name,
                autofocus: true,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Ör: İş imzası'),
              ),
              const SizedBox(height: Space.xl),
              Text(
                'İmza metni',
                style: textTheme.labelMedium?.copyWith(
                  color: t.textSecondary,
                ),
              ),
              const SizedBox(height: Space.xs),
              Expanded(
                child: TextField(
                  controller: _body,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'İletilerin sonuna eklenecek metin',
                    alignLabelWithHint: true,
                  ),
                ),
              ),
              const SizedBox(height: Space.lg),
              DialogActions(
                cancelLabel: 'Vazgeç',
                onCancel: () => Navigator.of(context).pop(),
                confirmLabel: _saving ? 'Ekleniyor…' : 'Ekle',
                onConfirm: _canSave ? _save : () {},
              ),
            ],
          ),
        ),
      ),
    );
  }
}
