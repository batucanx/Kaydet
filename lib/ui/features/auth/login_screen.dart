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

    final result = await ref
        .read(accountRepositoryProvider)
        .signIn(
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

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Scaffold(
      // Kök gezinme olarak (hesap yokken) geri düğmesi anlamsız; yalnızca
      // "hesap ekle" akışında, mevcut hesaba dönmek için gösterilir.
      appBar: widget.isAddingAccount
          ? AppBar(title: const Text('Hesap ekle'))
          : null,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 700;
            final verticalPadding = compact ? Space.lg : Space.xxxl;
            return SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.symmetric(
                horizontal: constraints.maxWidth < 400 ? Space.lg : Space.xxl,
                vertical: verticalPadding,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - verticalPadding * 2)
                      .clamp(0, double.infinity),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: reduceMotion ? 1 : 0, end: 1),
                      duration: reduceMotion ? Motion.instant : Motion.slow,
                      curve: Motion.standard,
                      builder: (context, value, child) => Opacity(
                        opacity: value,
                        child: Transform.translate(
                          offset: Offset(0, (1 - value) * Space.md),
                          child: child,
                        ),
                      ),
                      child: Column(
                        children: [
                          if (widget.isAddingAccount)
                            const SizedBox(height: Space.sm),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(Radii.lg),
                            child: Image.asset(
                              'assets/icon/app_logo.png',
                              width: compact ? 60 : 68,
                              height: compact ? 60 : 68,
                              fit: BoxFit.cover,
                              semanticLabel: 'Kaydet e-posta uygulaması logosu',
                            ),
                          ),
                          const SizedBox(height: Space.lg),
                          Text(
                            'Mail Hesabınıza Giriş Yapın',
                            textAlign: TextAlign.center,
                            style: text.titleLarge?.copyWith(
                              fontSize: 28 * AppText.scale,
                              letterSpacing: -0.7,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: compact ? Space.xl : Space.xxxl),
                          Form(
                            key: _formKey,
                            child: Container(
                              padding: const EdgeInsets.all(Space.xl),
                              decoration: BoxDecoration(
                                color: t.surfaceElevated,
                                borderRadius: BorderRadius.circular(Radii.lg),
                                border: Border.all(color: t.border),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _Field(
                                    controller: _email,
                                    label: 'E-posta adresi',
                                    hint: 'ornek@sirket.com',
                                    keyboardType: TextInputType.emailAddress,
                                    autofillHints: const [AutofillHints.email],
                                    validator: (value) {
                                      final v = (value ?? '').trim();
                                      if (v.isEmpty) {
                                        return 'E-posta adresi gerekli';
                                      }
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
                                    autofillHints: const [
                                      AutofillHints.password,
                                    ],
                                    validator: (value) => (value ?? '').isEmpty
                                        ? 'Şifre gerekli'
                                        : null,
                                    suffix: IconButton(
                                      icon: Icon(
                                        _obscure
                                            ? LucideIcons.eye
                                            : LucideIcons.eyeOff,
                                        size: IconSize.md,
                                      ),
                                      tooltip: _obscure
                                          ? 'Şifreyi göster'
                                          : 'Şifreyi gizle',
                                      onPressed: _loading
                                          ? null
                                          : () => setState(
                                              () => _obscure = !_obscure,
                                            ),
                                    ),
                                  ),
                                  const SizedBox(height: Space.md),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed: _loading
                                          ? null
                                          : () => setState(
                                              () => _showAdvanced =
                                                  !_showAdvanced,
                                            ),
                                      icon: Icon(
                                        _showAdvanced
                                            ? LucideIcons.chevronDown
                                            : LucideIcons.chevronRight,
                                        size: IconSize.sm,
                                      ),
                                      label: const Text('Sunucu ayarları'),
                                      style: TextButton.styleFrom(
                                        foregroundColor: t.textSecondary,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: Space.sm,
                                        ),
                                      ),
                                    ),
                                  ),
                                  AnimatedSize(
                                    duration: reduceMotion
                                        ? Motion.instant
                                        : Motion.base,
                                    curve: Motion.standard,
                                    alignment: Alignment.topCenter,
                                    child: _showAdvanced
                                        ? Padding(
                                            padding: const EdgeInsets.only(
                                              top: Space.sm,
                                            ),
                                            child: Column(
                                              children: [
                                                _ServerBlock(
                                                  title: 'Gelen sunucu · IMAP',
                                                  host: _imapHost,
                                                  port: _imapPort,
                                                  security: _imapSecurity,
                                                  onSecurityChanged: (value) =>
                                                      setState(() {
                                                        _imapSecurity = value;
                                                        _imapPort.text =
                                                            switch (value) {
                                                              SocketSecurity
                                                                  .ssl =>
                                                                '993',
                                                              SocketSecurity
                                                                  .startTls =>
                                                                '143',
                                                              SocketSecurity
                                                                  .none =>
                                                                '143',
                                                            };
                                                      }),
                                                  onHostEdited: () =>
                                                      _hostsTouched = true,
                                                ),
                                                const SizedBox(
                                                  height: Space.md,
                                                ),
                                                _ServerBlock(
                                                  title: 'Giden sunucu · SMTP',
                                                  host: _smtpHost,
                                                  port: _smtpPort,
                                                  security: _smtpSecurity,
                                                  onSecurityChanged: (value) =>
                                                      setState(() {
                                                        _smtpSecurity = value;
                                                        _smtpPort.text =
                                                            switch (value) {
                                                              SocketSecurity
                                                                  .ssl =>
                                                                '465',
                                                              SocketSecurity
                                                                  .startTls =>
                                                                '587',
                                                              SocketSecurity
                                                                  .none =>
                                                                '25',
                                                            };
                                                      }),
                                                  onHostEdited: () =>
                                                      _hostsTouched = true,
                                                ),
                                              ],
                                            ),
                                          )
                                        : const SizedBox.shrink(),
                                  ),
                                  AnimatedSize(
                                    duration: reduceMotion
                                        ? Motion.instant
                                        : Motion.base,
                                    curve: Motion.standard,
                                    alignment: Alignment.topCenter,
                                    child: _failure == null
                                        ? const SizedBox.shrink()
                                        : Padding(
                                            padding: const EdgeInsets.only(
                                              top: Space.md,
                                            ),
                                            child: _ErrorBox(
                                              failure: _failure!,
                                            ),
                                          ),
                                  ),
                                  const SizedBox(height: Space.lg),
                                  SizedBox(
                                    height: Dimens.controlHeight + 4,
                                    child: FilledButton(
                                      onPressed: _loading ? null : _submit,
                                      child: AnimatedSwitcher(
                                        duration: Motion.fast,
                                        child: _loading
                                            ? SizedBox(
                                                key: const ValueKey('loading'),
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      color: t.onAccentFill,
                                                    ),
                                              )
                                            : const Text(
                                                'Giriş yap',
                                                key: ValueKey('idle'),
                                              ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (widget.isAddingAccount)
                            const SizedBox(height: Space.lg),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
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
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: t.textSecondary),
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
          decoration: InputDecoration(
            hintText: hint,
            suffixIcon: suffix,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: Space.lg,
              vertical: Space.md,
            ),
          ),
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
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: t.textPrimary),
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
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: t.textSecondary),
          ),
          const SizedBox(height: Space.xs),
          SegmentedButton<SocketSecurity>(
            segments: const [
              ButtonSegment(value: SocketSecurity.ssl, label: Text('SSL/TLS')),
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
        color: t.danger.withValues(alpha: t.isDark ? 0.10 : 0.06),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: t.danger.withValues(alpha: 0.28)),
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
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: t.textPrimary),
                ),
                if (failure.detail != null) ...[
                  const SizedBox(height: Space.xs),
                  Text(
                    failure.detail!,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
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
