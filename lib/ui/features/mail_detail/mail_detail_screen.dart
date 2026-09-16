import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../../app/providers.dart';
import '../../../core/date_format.dart';
import '../../../core/result.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/use_cases/text_extraction.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../compose/compose_screen.dart';
import '../mail_list/mail_list_screen.dart';

/// İleti okuma ekranı.
class MailDetailScreen extends ConsumerStatefulWidget {
  const MailDetailScreen({super.key, required this.messageId});

  final int messageId;

  @override
  ConsumerState<MailDetailScreen> createState() => _MailDetailScreenState();
}

class _MailDetailScreenState extends ConsumerState<MailDetailScreen> {
  late int _messageId = widget.messageId;
  Timer? _seenTimer;
  bool _showRemoteImages = false;
  bool _loadingBody = false;
  AppFailure? _bodyError;

  @override
  void initState() {
    super.initState();
    _showRemoteImages = ref.read(settingsProvider).showRemoteImages;
    _onMessageOpened();
  }

  @override
  void dispose() {
    _seenTimer?.cancel();
    super.dispose();
  }

  void _onMessageOpened() {
    _seenTimer?.cancel();
    _loadBody();

    // Okundu işareti gecikmeli konur: yanlış iletiye dokunup hemen geri
    // çıkan kullanıcı o iletiyi okunmuş bulmamalı.
    final delay = ref.read(settingsProvider).markSeenDelayMs;
    _seenTimer = Timer(Duration(milliseconds: delay), () async {
      if (!mounted) return;
      final row = await ref.read(databaseProvider).messageById(_messageId);
      if (row != null && !row.isSeen) {
        await ref.read(mailRepositoryProvider).setSeen([_messageId], true);
      }
    });
  }

  Future<void> _loadBody() async {
    setState(() {
      _loadingBody = true;
      _bodyError = null;
    });
    final result = await ref
        .read(mailRepositoryProvider)
        .ensureBody(_messageId);
    if (!mounted) return;
    setState(() {
      _loadingBody = false;
      _bodyError = result.failureOrNull;
    });
  }

  /// Aynı listedeki önceki/sonraki iletiye geçer.
  void _navigate(int delta) {
    final rows = ref.read(messageListProvider).value ?? const <MessageRow>[];
    final index = rows.indexWhere((m) => m.id == _messageId);
    if (index < 0) return;
    final next = index + delta;
    if (next < 0 || next >= rows.length) return;
    setState(() => _messageId = rows[next].id);
    _onMessageOpened();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final message = ref.watch(messageProvider(_messageId)).value;
    final body = ref.watch(messageBodyProvider(_messageId)).value;
    final attachments =
        ref.watch(attachmentsProvider(_messageId)).value ?? const [];
    final rows = ref.watch(messageListProvider).value ?? const <MessageRow>[];
    final index = rows.indexWhere((m) => m.id == _messageId);

    if (message == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('İleti')),
        body: const EmptyState(
          icon: LucideIcons.mailX,
          title: 'İleti bulunamadı',
          description: 'Bu ileti silinmiş veya taşınmış olabilir.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const SizedBox.shrink(),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.chevronUp, size: IconSize.md),
            tooltip: 'Önceki ileti',
            onPressed: index > 0 ? () => _navigate(-1) : null,
          ),
          IconButton(
            icon: const Icon(LucideIcons.chevronDown, size: IconSize.md),
            tooltip: 'Sonraki ileti',
            onPressed: index >= 0 && index < rows.length - 1
                ? () => _navigate(1)
                : null,
          ),
          _MoreMenu(message: message),
          const SizedBox(width: Space.xs),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(message: message),
                const SizedBox(height: Space.lg),
                if (attachments.isNotEmpty) ...[
                  _AttachmentStrip(attachments: attachments),
                  const SizedBox(height: Space.lg),
                ],
              ],
            ),
          ),
          Divider(color: t.divider, height: 1),
          // Gövde kalan tüm alanı doldurur: WebView kendi içinde
          // kaydırıp yakınlaştırır, dıştaki bir ListView'la iç içe iki
          // kaydırma alanı oluşmaz.
          Expanded(
            child: _BodyView(
              body: body,
              isLoading: _loadingBody,
              error: _bodyError,
              showRemoteImages: _showRemoteImages,
              onShowImages: () => setState(() => _showRemoteImages = true),
              onRetry: _loadBody,
            ),
          ),
        ],
      ),
      bottomNavigationBar: _ActionBar(message: message),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.message});

  final MessageRow message;

  List<String> get _labelNames {
    try {
      final decoded = jsonDecode(message.labelsJson);
      if (decoded is List) return decoded.whereType<String>().toList();
    } on FormatException {
      // Bozuk etiket verisi başlığı engellemez.
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final to = EmailAddress.decodeList(message.toAddrJson);
    final cc = EmailAddress.decodeList(message.ccJson);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                message.subject.trim().isEmpty ? '(konu yok)' : message.subject,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (message.isFlagged)
              Padding(
                padding: const EdgeInsets.only(left: Space.sm, top: 4),
                child: Icon(
                  LucideIcons.pin,
                  size: IconSize.md,
                  color: t.accent,
                ),
              ),
          ],
        ),
        if (_labelNames.isNotEmpty) ...[
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              for (final name in _labelNames)
                LabelChip(name: name, toneIndex: 0),
            ],
          ),
        ],
        const SizedBox(height: Space.lg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BrandAvatar(
              name: message.fromName,
              email: message.fromEmail,
              size: 36,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.fromName.isEmpty
                        ? message.fromEmail
                        : message.fromName,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    message.fromEmail,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    formatDetailDate(message.dateUtc),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (to.isNotEmpty || cc.isNotEmpty) ...[
          const SizedBox(height: Space.md),
          _RecipientLine(label: 'Kime', addresses: to),
          if (cc.isNotEmpty) _RecipientLine(label: 'Bilgi', addresses: cc),
        ],
      ],
    );
  }
}

class _RecipientLine extends StatelessWidget {
  const _RecipientLine({required this.label, required this.addresses});

  final String label;
  final List<EmailAddress> addresses;

  @override
  Widget build(BuildContext context) {
    if (addresses.isEmpty) return const SizedBox.shrink();
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
            ),
          ),
          Expanded(
            child: Text(
              addresses.map((a) => a.display).join(', '),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: t.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentStrip extends ConsumerWidget {
  const _AttachmentStrip({required this.attachments});

  final List<AttachmentRow> attachments;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final visible = attachments.where((a) => !a.isInline).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${visible.length} ek',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
        ),
        const SizedBox(height: Space.sm),
        // Yatay kaydırma: kaç ek olursa olsun bu şerit tek satır
        // yüksekliğinde kalır, gövdeyi aşağı itmez.
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: visible.length,
            separatorBuilder: (context, index) =>
                const SizedBox(width: Space.sm),
            itemBuilder: (context, index) =>
                _AttachmentChip(attachment: visible[index]),
          ),
        ),
      ],
    );
  }
}

class _AttachmentChip extends ConsumerStatefulWidget {
  const _AttachmentChip({required this.attachment});

  final AttachmentRow attachment;

  @override
  ConsumerState<_AttachmentChip> createState() => _AttachmentChipState();
}

class _AttachmentChipState extends ConsumerState<_AttachmentChip> {
  bool _busy = false;

  Future<void> _open() async {
    setState(() => _busy = true);
    final result = await ref
        .read(mailRepositoryProvider)
        .downloadAttachment(widget.attachment.id);
    if (!mounted) return;
    setState(() => _busy = false);

    await result.fold((path) => OpenFilex.open(path), (failure) async {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(failure.userMessage)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final downloaded = widget.attachment.localPath != null;
    return InkWell(
      onTap: _busy ? null : _open,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240, minHeight: 44),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.sm,
        ),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: t.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: t.accent,
                ),
              )
            else
              Icon(
                downloaded ? LucideIcons.fileCheck : LucideIcons.download,
                size: IconSize.sm,
                color: downloaded ? t.success : t.accent,
              ),
            const SizedBox(width: Space.sm),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.attachment.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  Text(
                    formatBytes(widget.attachment.sizeBytes),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
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

class _BodyView extends StatefulWidget {
  const _BodyView({
    required this.body,
    required this.isLoading,
    required this.error,
    required this.showRemoteImages,
    required this.onShowImages,
    required this.onRetry,
  });

  final MessageBodyRow? body;
  final bool isLoading;
  final AppFailure? error;
  final bool showRemoteImages;
  final VoidCallback onShowImages;
  final VoidCallback onRetry;

  @override
  State<_BodyView> createState() => _BodyViewState();
}

class _BodyViewState extends State<_BodyView> {
  // "Uzak görsel var mı" taraması da bir regex geçişi; her yeniden çizimde
  // aynı (genelde çok büyük) HTML üzerinde tekrarlanmaması için önbelleğe
  // alınır — bkz. `_HtmlWebViewState._load` üzerindeki not.
  String? _scannedHtml;
  bool _hasRemote = false;

  void _rescanIfNeeded(String? html) {
    if (html == null || html == _scannedHtml) return;
    _scannedHtml = html;
    _hasRemote = TextExtraction.hasRemoteImages(html);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (widget.body == null && widget.isLoading) {
      return _paddedScroll(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.huge),
          child: Center(
            child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
          ),
        ),
      );
    }

    if (widget.body == null && widget.error != null) {
      return _paddedScroll(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xxl),
          child: EmptyState(
            icon: LucideIcons.cloudOff,
            title: 'İçerik indirilemedi',
            description: widget.error!.userMessage,
            action: OutlinedButton(
              onPressed: widget.onRetry,
              child: const Text('Yeniden dene'),
            ),
          ),
        ),
      );
    }

    final html = widget.body?.html;
    final plain = widget.body?.plainText;

    if (html != null && html.trim().isNotEmpty) {
      _rescanIfNeeded(html);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_hasRemote && !widget.showRemoteImages)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.md,
                Space.lg,
                0,
              ),
              child: _RemoteImageNotice(onShow: widget.onShowImages),
            ),
          // Kalan tüm alanı doldurur: kendi kaydırma/yakınlaştırmasını
          // yönetir, dıştaki bir kaydırma alanına ihtiyacı yoktur.
          Expanded(
            child: _HtmlWebView(
              html: html,
              showRemoteImages: widget.showRemoteImages,
            ),
          ),
        ],
      );
    }

    if (plain != null && plain.trim().isNotEmpty) {
      return _paddedScroll(
        SelectableText(plain, style: Theme.of(context).textTheme.bodyLarge),
      );
    }

    return _paddedScroll(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xxl),
        child: Text(
          'Bu iletinin metin içeriği yok.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: t.textTertiary),
        ),
      ),
    );
  }

  Widget _paddedScroll(Widget child) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xxl),
    child: child,
  );
}

/// Gerçek tarayıcı motoruyla (Android'de sistem WebView) gövde render'ı.
///
/// Karmaşık tablo/`div` düzenlerini (fatura/bülten şablonları gibi) hafif,
/// bağımsız bir HTML ayrıştırıcının çözebileceğinden çok daha güvenilir
/// işler; gövde render'ının tek yolu bu.
class _HtmlWebView extends StatefulWidget {
  const _HtmlWebView({required this.html, required this.showRemoteImages});

  final String html;
  final bool showRemoteImages;

  @override
  State<_HtmlWebView> createState() => _HtmlWebViewState();
}

class _HtmlWebViewState extends State<_HtmlWebView> {
  late final WebViewController _controller;
  bool _pageLoading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(Colors.white)
      ..enableZoom(true)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _pageLoading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _pageLoading = false);
          },
          onNavigationRequest: _onNavigationRequest,
        ),
      );
    // Android WebView varsayılanında `useWideViewPort` kapalıdır ve bu
    // durumda `<meta name="viewport">` tamamen yok sayılıp gövde sabit
    // masaüstü genişliğinde (~980px) render edilir — açılışta yakınlaştırılmış
    // görünüp kullanıcının elle uzaklaştırması gerekir. Açınca viewport meta
    // etiketi (bkz. `_wrapDocument`) gerçekten uygulanır ve ileti telefon
    // genişliğine sığdırılmış açılır. iOS'ta WKWebView viewport'u zaten
    // doğru uygular; bu yüzden yalnızca Android'de gerekir.
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      unawaited(platform.setUseWideViewPort(true));
    }
    _load();
  }

  @override
  void didUpdateWidget(covariant _HtmlWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html ||
        oldWidget.showRemoteImages != widget.showRemoteImages) {
      _load();
    }
  }

  /// Ağır regex temizliğini (uzak görsel + geniş sabit genişlik) yalnızca
  /// içerik gerçekten değiştiğinde, burada bir kez çalıştırır.
  ///
  /// Önceden bu işlem üst widget'ın `build()`'ında yapılıyordu — Riverpod
  /// kaynaklı her yeniden çizimde AYNI (bazı bültenlerde yüzlerce KB'lık)
  /// HTML üzerinde tekrar tekrar regex taraması demekti. LinkedIn gibi çok
  /// büyük/karmaşık e-postalarda bu, arayüzün donmuş gibi görünmesine yol
  /// açan asıl sebepti.
  void _load() {
    final safe = widget.showRemoteImages
        ? widget.html
        : TextExtraction.stripRemoteImages(widget.html);
    // Kaynağın kendi viewport etiketi kaldırılır ki `_wrapDocument`'ın
    // enjekte ettiği etiket çakışmasız, belgedeki TEK viewport etiketi
    // olsun (bkz. `stripViewportMeta` dokümantasyonu — aksi hâlde bülten
    // e-postalarında sessizce ezilip düzeltme hiç uygulanmamış görünüyordu).
    final noConflictingViewport = TextExtraction.stripViewportMeta(safe);
    final fitted = TextExtraction.stripWideFixedWidths(noConflictingViewport);
    unawaited(_controller.loadHtmlString(_wrapDocument(fitted)));
  }

  /// Bağlantı tıklamaları WebView içinde takip edilmez, sistem tarayıcısında
  /// açılır — aksi hâlde kullanıcı gönderenin sayfasına "uygulama içinde",
  /// hiçbir sandbox olmadan gitmiş olur. İlk yüklemenin kendisi (data: URI)
  /// bu engellemeye takılmaz; yalnızca gerçek http(s) gezinmeleri yakalanır.
  FutureOr<NavigationDecision> _onNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  /// Kasıtlı olarak `initial-scale` YAZILMAZ.
  ///
  /// Fatura/makbuz gibi sabit genişlikli (ör. 600px) tablo düzenlerinde
  /// `initial-scale=1.0` yazmak, tarayıcıya "1:1 ölçekte başla" der ve
  /// Android WebView'ın (`setLoadWithOverviewMode` + `setUseWideViewPort`
  /// ile açılan) otomatik "içeriği ekrana sığdır" davranışını devre dışı
  /// bırakır — içerik telefon genişliğinden geniş kaldığı için kullanıcı
  /// her açılışta elle uzaklaştırmak zorunda kalıyordu. Yalnızca
  /// `width=device-width` bırakılınca WebView geniş içeriği otomatik
  /// küçültüp tamamını ekrana sığdırıyor; kullanıcı isterse iki parmakla
  /// yakınlaştırabilir (`enableZoom`).
  static String _wrapDocument(String body) =>
      '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width">
<style>
  body { margin: 0; padding: 16px; font-family: -apple-system, Roboto, sans-serif;
         color: #0F1619; word-wrap: break-word; }
  img { max-width: 100%; height: auto; }
</style>
</head>
<body>$body</body>
</html>
''';

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: _controller)),
        if (_pageLoading)
          Positioned.fill(
            child: Container(
              color: Colors.white,
              alignment: Alignment.topCenter,
              padding: const EdgeInsets.only(top: Space.huge),
              child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
            ),
          ),
      ],
    );
  }
}

/// Uzak görsel uyarısı.
///
/// Uzak görseller varsayılan olarak yüklenmez: yüklenirse gönderen iletinin
/// okunduğunu, ne zaman okunduğunu ve IP adresini öğrenebilir.
class _RemoteImageNotice extends StatelessWidget {
  const _RemoteImageNotice({required this.onShow});

  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: t.divider),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.shieldAlert, size: IconSize.md, color: t.warning),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              'Gizliliğiniz için uzak görseller engellendi.',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: t.textSecondary),
            ),
          ),
          TextButton(onPressed: onShow, child: const Text('Göster')),
        ],
      ),
    );
  }
}

class _ActionBar extends ConsumerWidget {
  const _ActionBar({required this.message});

  final MessageRow message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final repository = ref.read(mailRepositoryProvider);

    Future<void> openCompose(ComposeMode mode) async {
      final savedDraftId = await Navigator.of(context).push<int>(
        MaterialPageRoute<int>(
          builder: (_) => ComposeScreen(replyToId: message.id, mode: mode),
          fullscreenDialog: true,
        ),
      );
      if (savedDraftId != null && context.mounted) {
        showDraftSavedSnackBar(context, ref, savedDraftId);
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: t.surfaceElevated,
        border: Border(top: BorderSide(color: t.divider)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              _DetailAction(
                icon: LucideIcons.cornerUpLeft,
                label: 'Yanıtla',
                onTap: () => openCompose(ComposeMode.reply),
              ),
              _DetailAction(
                icon: LucideIcons.reply,
                label: 'Tümünü',
                onTap: () => openCompose(ComposeMode.replyAll),
              ),
              _DetailAction(
                icon: LucideIcons.cornerUpRight,
                label: 'İlet',
                onTap: () => openCompose(ComposeMode.forward),
              ),
              _DetailAction(
                icon: LucideIcons.archive,
                label: 'Arşivle',
                onTap: () async {
                  await repository.archive([message.id]);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
              _DetailAction(
                icon: LucideIcons.trash2,
                label: 'Sil',
                onTap: () async {
                  final deleted = await deleteWithConfirmation(context, ref, [
                    message.id,
                  ]);
                  if (deleted && context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailAction extends StatelessWidget {
  const _DetailAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          label: label,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: IconSize.md, color: t.textSecondary),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: t.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoreMenu extends ConsumerWidget {
  const _MoreMenu({required this.message});

  final MessageRow message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.read(mailRepositoryProvider);
    return PopupMenuButton<String>(
      icon: const Icon(LucideIcons.ellipsisVertical, size: IconSize.md),
      tooltip: 'Diğer',
      onSelected: (value) async {
        switch (value) {
          case 'pin':
            await repository.setFlagged([message.id], !message.isFlagged);
          case 'unread':
            await repository.setSeen([message.id], false);
            if (context.mounted) Navigator.of(context).pop();
          case 'spam':
            await repository.markSpam([message.id]);
            if (context.mounted) Navigator.of(context).pop();
          case 'move':
            final target = await showFolderPicker(context, ref);
            if (target == null) return;
            await repository.moveToMailbox(
              messageIds: [message.id],
              target: target,
            );
            if (context.mounted) Navigator.of(context).pop();
          case 'label':
            final label = await showLabelPicker(context, ref);
            if (label == null) return;
            await repository.setLabel(
              messageIds: [message.id],
              labelName: label,
              add: true,
            );
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'pin',
          child: Row(
            children: [
              Icon(
                message.isFlagged ? LucideIcons.pinOff : LucideIcons.pin,
                size: IconSize.sm,
              ),
              const SizedBox(width: Space.md),
              Text(message.isFlagged ? 'Sabitlemeyi kaldır' : 'Sabitle'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'unread',
          child: Row(
            children: [
              Icon(LucideIcons.mailX, size: IconSize.sm),
              SizedBox(width: Space.md),
              Text('Okunmadı olarak işaretle'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'label',
          child: Row(
            children: [
              Icon(LucideIcons.tag, size: IconSize.sm),
              SizedBox(width: Space.md),
              Text('Etiketle'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'move',
          child: Row(
            children: [
              Icon(LucideIcons.folderInput, size: IconSize.sm),
              SizedBox(width: Space.md),
              Text('Klasöre taşı'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'spam',
          child: Row(
            children: [
              Icon(LucideIcons.octagonAlert, size: IconSize.sm),
              SizedBox(width: Space.md),
              Text('İstenmeyen olarak bildir'),
            ],
          ),
        ),
      ],
    );
  }
}
