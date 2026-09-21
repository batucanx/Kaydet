import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

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
import '../../core/actions/message_actions.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../compose/compose_launcher.dart';
import '../compose/compose_screen.dart' show ComposeMode;
import 'mail_html_document.dart';

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

  @override
  void initState() {
    super.initState();
    // Gövde indirme burada ELLE tetiklenmez — `build()`'ın izlediği
    // `bodyFetchProvider(_messageId)` ilk kez izlendiği anda (bu widget
    // kurulduğunda) Riverpod tarafından otomatik çalıştırılır (bkz.
    // `app/providers.dart`). Yalnızca okundu işaretinin zamanlayıcısı kalır.
    _scheduleMarkSeen();
  }

  @override
  void dispose() {
    _seenTimer?.cancel();
    super.dispose();
  }

  void _scheduleMarkSeen() {
    _seenTimer?.cancel();

    // Okundu işareti gecikmeli konur: yanlış iletiye dokunup hemen geri
    // çıkan kullanıcı o iletiyi okunmuş bulmamalı.
    final delay = ref.read(settingsProvider).markSeenDelayMs;
    _seenTimer = Timer(Duration(milliseconds: delay), () async {
      if (!mounted) return;
      final row = await ref.read(messageProvider(_messageId).future);
      if (row != null && !row.isSeen) {
        await ref.read(mailRepositoryProvider).setSeen([_messageId], true);
      }
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
    _scheduleMarkSeen();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final message = ref.watch(messageProvider(_messageId)).value;
    final body = ref.watch(messageBodyProvider(_messageId)).value;
    final bodyFetch = ref.watch(bodyFetchProvider(_messageId));
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
              fetchStatus: bodyFetch,
              onRetry: () => ref.invalidate(bodyFetchProvider(_messageId)),
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

class _BodyView extends StatelessWidget {
  const _BodyView({
    required this.body,
    required this.fetchStatus,
    required this.onRetry,
  });

  /// Yerelde (offline-first) elde bulunan en güncel gövde — `null` ise
  /// henüz hiç inmemiş demektir.
  final MessageBodyRow? body;

  /// `bodyFetchProvider`'ın durumu — [body] `null` olduğunda hangi boş
  /// durumun gösterileceğine (shimmer/hata) bu karar verir. Değeri
  /// kullanılmaz; sadece `hasError`/`hasValue` sinyalleri okunur (bkz.
  /// `app/providers.dart`daki `bodyFetchProvider` belgesi — yarış durumunu
  /// önlemek için provider'ın kendisi zaten `body` akışıyla senkron tutulur).
  final AsyncValue<MessageBodyRow?> fetchStatus;

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (body == null && fetchStatus.hasError) {
      final error = fetchStatus.error;
      return _paddedScroll(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xxl),
          child: EmptyState(
            icon: LucideIcons.cloudOff,
            title: 'İçerik indirilemedi',
            description: error is AppFailure ? error.userMessage : '$error',
            action: OutlinedButton(
              onPressed: onRetry,
              child: const Text('Yeniden dene'),
            ),
          ),
        ),
      );
    }

    if (body == null && !fetchStatus.hasValue) {
      // Ekranı bloklayan tekil bir döner gösterge YERİNE: başlık/gönderen/
      // ekler zaten `message` satırından (yerelde, anında) geldiği için
      // yalnızca gövdenin oturacağı alanda hafif bir shimmer gösterilir —
      // Outlook'un okuma bölmesindeki gibi. `bodyFetchProvider` indirme
      // bitse BİLE `messageBodyProvider`nin akışı yeni satırı gerçekten
      // yayana kadar `loading` kalır (bkz. provider belgesi), bu yüzden
      // `hasValue` ikisi de tamamlanana kadar `false` kalır — indirme
      // bitişi ile veri ekranda görünür oluşu arasında "içerik yok"
      // mesajının bir kare yanıp sönmesi yapısal olarak mümkün değildir.
      return const _BodyShimmer();
    }

    final html = body?.html;
    final plain = body?.plainText;

    if (html != null && html.trim().isNotEmpty) {
      // Kalan tüm alanı doldurur: kendi kaydırma/yakınlaştırmasını
      // yönetir, dıştaki bir kaydırma alanına ihtiyacı yoktur.
      return _HtmlWebView(html: html);
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

/// Gövde metninin geleceği alanda hayalet ekran (shimmer) efekti.
///
/// Değişen genişlikte birkaç "satır" üzerinde soldan sağa kayan bir
/// parlaklık bandı (bkz. `ShimmerSurface`) — gerçek metin satırlarının
/// taslağı gibi durur, tekil bir döner gösterge gibi dikkat çekip ekranı
/// domine etmez.
class _BodyShimmer extends StatelessWidget {
  const _BodyShimmer();

  // Gerçek bir paragrafın satır sonlarını taklit eden değişen genişlikler.
  static const _lineWidthFactors = [1.0, 0.94, 0.6, 1.0, 0.86, 0.42];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xxl),
      child: ShimmerSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final factor in _lineWidthFactors)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: ShimmerBar(widthFactor: factor),
              ),
          ],
        ),
      ),
    );
  }
}

/// Gerçek tarayıcı motoruyla (Android'de sistem WebView) gövde render'ı.
///
/// Karmaşık tablo/`div` düzenlerini (fatura/bülten şablonları gibi) hafif,
/// bağımsız bir HTML ayrıştırıcının çözebileceğinden çok daha güvenilir
/// işler; gövde render'ının tek yolu bu.
///
/// Görünümü Outlook mobil gibi profesyonel kılan her şey `MailHtmlDocument`te
/// toplanır (viewport, akışkanlaştırma, yazı boyutu tabanı, koyu tema renk
/// dönüşümü). Uygulamanın temasını (`KaydetTokens`) izler: tema değişince
/// belge yeni renklerle yeniden kurulur.
class _HtmlWebView extends StatefulWidget {
  const _HtmlWebView({required this.html});

  final String html;

  @override
  State<_HtmlWebView> createState() => _HtmlWebViewState();
}

class _HtmlWebViewState extends State<_HtmlWebView> {
  late final WebViewController _controller;
  bool _pageLoading = true;

  // `_load()` art arda (ör. ilk `didChangeDependencies` hemen ardından
  // `didUpdateWidget`) tetiklenirse, önce başlayan ama geç biten bir isolate
  // çağrısı sonucu yeni içeriğin üzerine yazmasın diye her çağrının kendi
  // sırası tutulur.
  int _loadToken = 0;

  // Belgenin en son hangi temayla kurulduğu. Tema `initState`te okunamayan bir
  // InheritedWidget'tır; bu yüzden ilk yükleme `didChangeDependencies`te yapılır.
  KaydetTokens? _tokens;
  Timer? _themeReload;

  @override
  void initState() {
    super.initState();
    // JS açık: çalışan tek betik `MailHtmlDocument`in nonce'lu render
    // betiğidir; e-postanın kendi betikleri belgedeki CSP ile engellenir.
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
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
    // etiketi (bkz. `MailHtmlDocument`) gerçekten uygulanır ve ileti telefon
    // genişliğine sığdırılmış açılır. iOS'ta WKWebView viewport'u zaten
    // doğru uygular; bu yüzden yalnızca Android'de gerekir.
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      unawaited(platform.setUseWideViewPort(true));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tokens = context.tokens;
    final previous = _tokens;
    _tokens = tokens;
    // WebView'ın kendi zemini sayfa yüklenmeden önce ve kaydırma taşmasında
    // görünür; beyaz kalırsa koyu temada göz yakan bir flaş olur.
    unawaited(_controller.setBackgroundColor(tokens.bg));

    if (previous == null) {
      unawaited(_load());
    } else if (previous.isDark != tokens.isDark ||
        previous.bg != tokens.bg ||
        previous.textPrimary != tokens.textPrimary) {
      // Tema geçişi animasyonludur: ara her karede `didChangeDependencies`
      // tetiklenir. Belgeyi her karede yeniden kurmak yerine geçiş durulunca
      // bir kez kurulur.
      _themeReload?.cancel();
      _themeReload = Timer(const Duration(milliseconds: 250), () {
        if (mounted) unawaited(_load());
      });
    }
  }

  @override
  void dispose() {
    _themeReload?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _HtmlWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      unawaited(_load());
    }
  }

  /// Ağır regex temizliğini (viewport, `prefers-color-scheme`)
  /// yalnızca içerik ya da tema gerçekten değiştiğinde, burada bir kez
  /// çalıştırır.
  ///
  /// Önceden bu işlem üst widget'ın `build()`'ında yapılıyordu — Riverpod
  /// kaynaklı her yeniden çizimde AYNI (bazı bültenlerde yüzlerce KB'lık)
  /// HTML üzerinde tekrar tekrar regex taraması demekti. LinkedIn gibi çok
  /// büyük/karmaşık e-postalarda bu, arayüzün donmuş gibi görünmesine yol
  /// açan asıl sebepti.
  ///
  /// Regex zinciri artık `Isolate.run` ile ayrı bir isolate'ta çalışır —
  /// `TextExtraction.htmlToPlain`in senkron gövde önizlemesi için zaten
  /// kullandığı desenin aynısı (bkz. `SyncEngine`). Büyük bültenlerde bu
  /// tarama tek başına birkaç yüz milisaniye sürebilir; UI isolate'ında
  /// çalışsaydı doğrudan kare düşmesine yol açardı.
  Future<void> _load() async {
    final token = ++_loadToken;
    final html = widget.html;
    final tokens = _tokens!;
    final dark = tokens.isDark;

    final (body, emailSupportsDark) = await Isolate.run(() {
      // Kaynağın kendi viewport etiketi kaldırılır ki `MailHtmlDocument`in
      // yazdığı etiket çakışmasız, belgedeki TEK viewport etiketi olsun (bkz.
      // `stripViewportMeta` dokümantasyonu — aksi hâlde bülten e-postalarında
      // sessizce ezilip düzeltme hiç uygulanmamış görünüyordu).
      final noConflictingViewport = TextExtraction.stripViewportMeta(html);
      return (
        TextExtraction.resolveColorSchemeQueries(
          noConflictingViewport,
          dark: dark,
        ),
        TextExtraction.supportsDarkScheme(noConflictingViewport),
      );
    });
    final script = await MailHtmlDocument.renderScript;

    // Ekran bu arada kapanmış ya da yeni bir `_load()` başlamış olabilir —
    // ikisinde de bu (artık eski) sonucu uygulamak yanlış içerik gösterir.
    if (!mounted || token != _loadToken) return;
    unawaited(
      _controller.loadHtmlString(
        MailHtmlDocument.build(
          body: body,
          tokens: tokens,
          emailSupportsDark: emailSupportsDark,
          script: script,
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: _controller)),
        if (_pageLoading)
          Positioned.fill(
            child: Container(
              color: t.bg,
              alignment: Alignment.topCenter,
              padding: const EdgeInsets.only(top: Space.huge),
              child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
            ),
          ),
      ],
    );
  }
}

class _ActionBar extends ConsumerWidget {
  const _ActionBar({required this.message});

  final MessageRow message;

  /// Çubuğun alt güvenli alanın üstünde kapladığı yükseklik. "Taslağa
  /// kaydedildi" bildirimi bunun üstüne yerleşir (bkz. `KaydetNotice`).
  static const double height = 64;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final repository = ref.read(mailRepositoryProvider);

    Future<void> startCompose(ComposeMode mode) => openCompose(
      context,
      ref,
      replyToId: message.id,
      mode: mode,
      fullscreenDialog: true,
      noticeBottomInset: height,
    );

    return Container(
      decoration: BoxDecoration(
        color: t.surfaceElevated,
        border: Border(top: BorderSide(color: t.divider)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              _DetailAction(
                icon: LucideIcons.cornerUpLeft,
                label: 'Yanıtla',
                onTap: () => startCompose(ComposeMode.reply),
              ),
              _DetailAction(
                icon: LucideIcons.reply,
                label: 'Tümünü',
                onTap: () => startCompose(ComposeMode.replyAll),
              ),
              _DetailAction(
                icon: LucideIcons.cornerUpRight,
                label: 'İlet',
                onTap: () => startCompose(ComposeMode.forward),
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

/// Okuma ekranının "..." menüsü — "Etiketle"/"Klasöre taşı" artık ayrı bir
/// alttan panel açmıyor, aynı popup içinde kendi alt menüsüne (bkz.
/// `SubmenuButton`) cascade oluyor (bkz. bellek: popup'lar modallara
/// tercih edilir).
class _MoreMenu extends ConsumerWidget {
  const _MoreMenu({required this.message});

  final MessageRow message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.read(mailRepositoryProvider);

    return MenuAnchor(
      animated: true,
      menuChildren: [
        MenuItemButton(
          leadingIcon: Icon(
            message.isFlagged ? LucideIcons.pinOff : LucideIcons.pin,
            size: IconSize.sm,
          ),
          onPressed: () =>
              repository.setFlagged([message.id], !message.isFlagged),
          child: Text(message.isFlagged ? 'Sabitlemeyi kaldır' : 'Sabitle'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(LucideIcons.mailX, size: IconSize.sm),
          onPressed: () async {
            await repository.setSeen([message.id], false);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('Okunmadı olarak işaretle'),
        ),
        SubmenuButton(
          animated: true,
          leadingIcon: const Icon(LucideIcons.tag, size: IconSize.sm),
          menuChildren: labelMenuItems(context, ref, (label) async {
            await repository.setLabel(
              messageIds: [message.id],
              labelName: label,
              add: true,
            );
          }),
          child: const Text('Etiketle'),
        ),
        SubmenuButton(
          animated: true,
          leadingIcon: const Icon(LucideIcons.folderInput, size: IconSize.sm),
          menuChildren: folderMenuItems(ref, (target) async {
            await repository.moveToMailbox(
              messageIds: [message.id],
              target: target,
            );
            if (context.mounted) Navigator.of(context).pop();
          }),
          child: const Text('Klasöre taşı'),
        ),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: const Icon(LucideIcons.octagonAlert, size: IconSize.sm),
          onPressed: () async {
            await repository.markSpam([message.id]);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('İstenmeyen olarak bildir'),
        ),
      ],
      builder: (context, controller, child) => IconButton(
        icon: const Icon(LucideIcons.ellipsisVertical, size: IconSize.md),
        tooltip: 'Diğer',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
