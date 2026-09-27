import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/push_protocol.dart';
import '../../../app/push_service.dart';
import '../../../app/remote_push_controller.dart';
import '../../../app/sync_controller.dart';
import '../../../core/result.dart';
import '../theme/tokens.dart';
import '../widgets/kaydet_widgets.dart';

/// Kimlik doğrulama hatası (şifre sunucuda değişti ya da cihazın Keystore'u
/// sıfırlandı) sonrası etkin hesabın şifresini günceller.
///
/// Yeni şifre IMAP ve SMTP'ye karşı doğrulanır ve yalnızca doğruysa saklanır;
/// hesap, yerel iletiler ve taslaklar korunur (çıkış yapıp yeniden girmek
/// hepsini silerdi). Başarılı olursa hata bandı temizlenir, eşitleme yeniden
/// başlar ve ön plan servisinin durmuş izleyicileri yeniden kurulur.
Future<void> showUpdatePasswordDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final accountId = ref.read(accountIdProvider);
  if (accountId == null) return;
  // Diyalog açıkken çağıran ekran kapanabilir; `ref` bekledikten sonra
  // kullanılmasın diye gereken her şey önceden alınır.
  final sync = ref.read(syncControllerProvider.notifier);

  final updated = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdatePasswordDialog(accountId: accountId),
  );
  if (updated != true) return;

  sync.clearError();
  // Kimlik hatasıyla durmuş izleyiciler yeni şifreyle yeniden denenir
  // (bkz. `PushTaskHandler._reconcile`).
  unawaited(PushService.send(PushProtocol.message(PushProtocol.accounts)));
  // iOS: parmak izi şifreyi içermediğinden (bkz. `RemotePushSync.fingerprint`)
  // bu olmadan push backend'deki eski şifre sessizce kalıcı olurdu.
  ref.read(remotePushControllerProvider.notifier).passwordChanged(accountId);
  unawaited(sync.syncAll());
}

class _UpdatePasswordDialog extends ConsumerStatefulWidget {
  const _UpdatePasswordDialog({required this.accountId});

  final int accountId;

  @override
  ConsumerState<_UpdatePasswordDialog> createState() =>
      _UpdatePasswordDialogState();
}

class _UpdatePasswordDialogState extends ConsumerState<_UpdatePasswordDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final password = _controller.text;
    if (password.isEmpty) {
      setState(() => _error = 'Şifre boş bırakılamaz.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await ref
        .read(accountRepositoryProvider)
        .updatePassword(widget.accountId, password);
    if (!mounted) return;

    if (result is Err<void>) {
      setState(() {
        _busy = false;
        _error = result.failure.userMessage;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final account = ref.watch(accountByIdProvider(widget.accountId));

    return AlertDialog(
      title: const Text('Şifreyi güncelle'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            account == null
                ? 'Hesabın yeni şifresini girin.'
                : '${account.email} için yeni şifreyi girin. Yerel iletileriniz '
                      've taslaklarınız korunur.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: t.textSecondary),
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_busy,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Şifre',
              errorText: _error,
              errorMaxLines: 3,
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Şifreyi göster' : 'Şifreyi gizle',
                icon: Icon(_obscure ? LucideIcons.eye : LucideIcons.eyeOff),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        DialogActions(
          cancelLabel: 'Vazgeç',
          onCancel: () {
            if (!_busy) Navigator.of(context).pop(false);
          },
          confirmLabel: _busy ? 'Doğrulanıyor…' : 'Güncelle',
          onConfirm: () => unawaited(_submit()),
        ),
      ],
    );
  }
}
