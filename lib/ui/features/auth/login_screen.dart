import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../core/result.dart';
import '../../../data/repositories/account_repository.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';

/// Giriş ekranı.
///
/// IMAP ve SMTP ayrı ayrı doğrulanır; yalnızca biri hatalıysa kullanıcı
/// hangi tarafın yanlış olduğunu görür. Şifre yalnızca güvenli depolamaya
/// yazılır, veritabanına veya log'a asla düşmez.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.isAddingAccount = false});

  /// `true` ise bu ekran kök gezinme değil, mevcut bir hesabın üzerine
  /// "hesap ekle" akışıyla push edilmiştir: başarılı girişte kapanır,
  /// üstteki uygulamaya dönülür (yeni hesap otomatik etkinleşmiş olur).
  final bool isAddingAccount;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _imapHost = TextEditingController();
  final _imapPort = TextEditingController(text: '993');
  final _smtpHost = TextEditingController();
  final _smtpPort = TextEditingController(text: '465');

  SocketSecurity _imapSecurity = SocketSecurity.ssl;
  SocketSecurity _smtpSecurity = SocketSecurity.ssl;
  bool _showAdvanced = false;
  bool _obscure = true;
  bool _loading = false;
  AppFailure? _failure;
  bool _hostsTouched = false;

  @override
  void initState() {
    super.initState();
    _email.addListener(_autofillHosts);
  }

  @override
  void dispose() {
    _email.removeListener(_autofillHosts);
    _email.dispose();
    _password.dispose();
    _imapHost.dispose();
    _imapPort.dispose();
    _smtpHost.dispose();
    _smtpPort.dispose();
    super.dispose();
  }

  /// Alan adından sunucu adını tahmin eder: `info@pazarlik.com.tr`
  /// → `mail.pazarlik.com.tr`. Kullanıcı elle değiştirdiyse dokunulmaz.
  void _autofillHosts() {
    if (_hostsTouched) return;
    final email = _email.text.trim();
    final at = email.indexOf('@');
    if (at <= 0 || at == email.length - 1) return;
    final domain = email.substring(at + 1);
    if (!domain.contains('.')) return;
    final guess = 'mail.$domain';
    if (_imapHost.text != guess) _imapHost.text = guess;
    if (_smtpHost.text != guess) _smtpHost.text = guess;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _loading = true;
      _failure = null;
    });

    final result = await ref.read(accountRepositoryProvider).signIn(
          SignInRequest(
            email: _email.text.trim(),
            password: _password.text,
            imapHost: _imapHost.text.trim(),
            imapPort: int.tryParse(_imapPort.text.trim()) ?? 993,
            imapSecurity: _imapSecurity,
            smtpHost: _smtpHost.text.trim(),
            smtpPort: int.tryParse(_smtpPort.text.trim()) ?? 465,
            smtpSecurity: _smtpSecurity,
          ),
        );

    if (!mounted) return;
    setState(() => _loading = false);

    result.fold(
      (_) {
        // Hesap eklendi ve etkinleşti; "hesap ekle" akışında bu ekranın işi
        // biter — kapanınca üstteki uygulama yeni hesabı zaten gösterir.
        if (widget.isAddingAccount && mounted) Navigator.of(context).pop();
      },
      (failure) => setState(() {
        _failure = failure;
        // Kimlik hatasında gelişmiş ayarlar açılır: kullanıcı port ve
        // güvenlik ayarlarını gözden geçirebilsin.
        if (failure is TlsFailure || failure is ConnectionFailure) {
          _showAdvanced = true;
        }
      }),
    );
  }

  /// Google ile giriş — tarayıcıda OAuth onayı alınır, sunucu/port sorulmaz.
  Future<void> _submitGoogle() async {
    setState(() {
      _loading = true;
      _failure = null;
    });

    final result =
        await ref.read(accountRepositoryProvider).signInWithGoogle();

    if (!mounted) return;
    setState(() => _loading = false);

    result.fold(
      (_) {
        if (widget.isAddingAccount && mounted) Navigator.of(context).pop();
      },
      (failure) => setState(() => _failure = failure),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      // Kök gezinme olarak (hesap yokken) geri düğmesi anlamsız; yalnızca
      // "hesap ekle" akışında, mevcut hesaba dönmek için gösterilir.
      appBar: widget.isAddingAccount
          ? AppBar(title: const Text('Hesap ekle'))
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.xxl,
              vertical: Space.xxxl,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Kaydet',
                      textAlign: TextAlign.center,
                      style: text.titleLarge?.copyWith(
                        fontSize: 32 * AppText.scale,
                        letterSpacing: -1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: Space.xs),
                    Text(
                      'Güvenli e-posta istemcisi',
                      textAlign: TextAlign.center,
                      style: text.labelSmall?.copyWith(color: t.textTertiary),
                    ),
                    const SizedBox(height: Space.xxxl),

                    OutlinedButton.icon(
                      onPressed: _loading ? null : _submitGoogle,
                      icon: const Icon(LucideIcons.mail, size: IconSize.md),
                      label: const Text('Google ile devam et'),
                    ),
                    const SizedBox(height: Space.lg),
                    Row(
                      children: [
                        Expanded(child: Divider(color: t.divider)),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.sm,
                          ),
                          child: Text(
                            'veya e-posta ile giriş yap',
                            style: text.labelSmall
                                ?.copyWith(color: t.textTertiary),
                          ),
                        ),
                        Expanded(child: Divider(color: t.divider)),
                      ],
                    ),
                    const SizedBox(height: Space.lg),

                    _Field(
                      controller: _email,
                      label: 'E-posta adresi',
                      hint: 'ornek@sirket.com',
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      validator: (value) {
                        final v = (value ?? '').trim();
                        if (v.isEmpty) return 'E-posta adresi gerekli';
                        if (!EmailAddress.isValidEmail(v)) {
                          return 'Geçerli bir e-posta adresi girin';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: Space.lg),

                    _Field(
                      controller: _password,
                      label: 'Şifre',
                      hint: '••••••••',
                      obscure: _obscure,
                      autofillHints: const [AutofillHints.password],
                      validator: (value) =>
                          (value ?? '').isEmpty ? 'Şifre gerekli' : null,
                      suffix: IconButton(
                        icon: Icon(
                          _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                          size: IconSize.md,
                        ),
                        tooltip: _obscure ? 'Şifreyi göster' : 'Şifreyi gizle',
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    const SizedBox(height: Space.lg),

                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () =>
                            setState(() => _showAdvanced = !_showAdvanced),
                        icon: Icon(
                          _showAdvanced
                              ? LucideIcons.chevronDown
                              : LucideIcons.chevronRight,
                          size: IconSize.sm,
                        ),
                        label: const Text('Sunucu ayarları'),
                        style: TextButton.styleFrom(
                          foregroundColor: t.textSecondary,
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ),

                    if (_showAdvanced) ...[
                      const SizedBox(height: Space.sm),
                      _ServerBlock(
                        title: 'Gelen sunucu (IMAP)',
                        host: _imapHost,
                        port: _imapPort,
                        security: _imapSecurity,
                        onSecurityChanged: (value) => setState(() {
                          _imapSecurity = value;
                          _imapPort.text = switch (value) {
                            SocketSecurity.ssl => '993',
                            SocketSecurity.startTls => '143',
                            SocketSecurity.none => '143',
                          };
                        }),
                        onHostEdited: () => _hostsTouched = true,
                      ),
                      const SizedBox(height: Space.lg),
                      _ServerBlock(
                        title: 'Giden sunucu (SMTP)',
                        host: _smtpHost,
                        port: _smtpPort,
                        security: _smtpSecurity,
                        onSecurityChanged: (value) => setState(() {
                          _smtpSecurity = value;
                          _smtpPort.text = switch (value) {
                            SocketSecurity.ssl => '465',
                            SocketSecurity.startTls => '587',
                            SocketSecurity.none => '25',
                          };
                        }),
                        onHostEdited: () => _hostsTouched = true,
                      ),
                      const SizedBox(height: Space.md),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            LucideIcons.info,
                            size: IconSize.sm,
                            color: t.textTertiary,
                          ),
                          const SizedBox(width: Space.sm),
                          Expanded(
                            child: Text(
                              'Güvenlik "Yok" seçilirse şifreniz ağ üzerinde '
                              'açık metin olarak gönderilir. SSL/TLS önerilir.',
                              style: text.labelSmall
                                  ?.copyWith(color: t.textTertiary),
                            ),
                          ),
                        ],
                      ),
                    ],

                    if (_failure != null) ...[
                      const SizedBox(height: Space.lg),
                      _ErrorBox(failure: _failure!),
                    ],

                    const SizedBox(height: Space.xxl),
                    FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: t.onAccentFill,
                              ),
                            )
                          : const Text('Giriş yap'),
                    ),
                    const SizedBox(height: Space.lg),
                    Text(
                      'Şifreniz yalnızca bu cihazda, Android Keystore ile '
                      'şifrelenerek saklanır.',
                      textAlign: TextAlign.center,
                      style: text.labelSmall?.copyWith(color: t.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.hint,
    this.obscure = false,
    this.keyboardType,
    this.validator,
    this.suffix,
    this.autofillHints,
    this.onChanged,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final Widget? suffix;
  final List<String>? autofillHints;
  final ValueChanged<String>? onChanged;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: t.textSecondary),
        ),
        const SizedBox(height: Space.xs),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          validator: validator,
          autofillHints: autofillHints,
          onChanged: onChanged,
          inputFormatters: inputFormatters,
          style: Theme.of(context).textTheme.bodyMedium,
          decoration: InputDecoration(hintText: hint, suffixIcon: suffix),
        ),
      ],
    );
  }
}

class _ServerBlock extends StatelessWidget {
  const _ServerBlock({
    required this.title,
    required this.host,
    required this.port,
    required this.security,
    required this.onSecurityChanged,
    required this.onHostEdited,
  });

  final String title;
  final TextEditingController host;
  final TextEditingController port;
  final SocketSecurity security;
  final ValueChanged<SocketSecurity> onSecurityChanged;
  final VoidCallback onHostEdited;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: t.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: t.textPrimary),
          ),
          const SizedBox(height: Space.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _Field(
                  controller: host,
                  label: 'Sunucu',
                  hint: 'mail.ornek.com',
                  onChanged: (_) => onHostEdited(),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Gerekli' : null,
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: _Field(
                  controller: port,
                  label: 'Port',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (value) {
                    final parsed = int.tryParse((value ?? '').trim());
                    if (parsed == null || parsed < 1 || parsed > 65535) {
                      return 'Geçersiz';
                    }
                    return null;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          Text(
            'Güvenlik',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: t.textSecondary),
          ),
          const SizedBox(height: Space.xs),
          SegmentedButton<SocketSecurity>(
            segments: const [
              ButtonSegment(
                value: SocketSecurity.ssl,
                label: Text('SSL/TLS'),
              ),
              ButtonSegment(
                value: SocketSecurity.startTls,
                label: Text('STARTTLS'),
              ),
              ButtonSegment(value: SocketSecurity.none, label: Text('Yok')),
            ],
            selected: {security},
            showSelectedIcon: false,
            onSelectionChanged: (values) => onSecurityChanged(values.first),
            style: ButtonStyle(
              textStyle: WidgetStatePropertyAll(
                Theme.of(context).textTheme.labelSmall,
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.failure});

  final AppFailure failure;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: t.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.triangleAlert, size: IconSize.md, color: t.danger),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  failure.userMessage,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: t.textPrimary),
                ),
                if (failure.detail != null) ...[
                  const SizedBox(height: Space.xs),
                  Text(
                    failure.detail!,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: t.textTertiary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
