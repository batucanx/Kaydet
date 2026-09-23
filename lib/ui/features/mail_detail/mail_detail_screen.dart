import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/scheduler.dart' show Ticker;
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
///
/// Tek kaydırma alanı: sabitlenmiş (pinned), SABİT boyutlu `SliverAppBar`,
/// büyük konu, gönderen başlığı, ekler ve gövde aynı `CustomScrollView`da
/// kayar. Gövdenin WebView'ı kendi içinde kaydırmaz, içeriğinin boyuna
/// uzatılır (bkz. `_HtmlWebView`): iç içe iki kaydırma alanı oluşmaz, parmak
/// ekranın neresinde olursa olsun başlık gövdeyle birlikte hareket eder.
///
/// App bar kaydırma konumuna göre büyüyüp küçülmez, içeriği değişmez —
/// KASITLI olarak animasyonsuz: konunun app bar'a "kayıp küçülmesi" daha
/// önce denendi (önce elle bir `AnimationController`/scroll dinleyicisiyle,
/// sonra `FlexibleSpaceBar` ile) ve ikisi de kaydırma sırasında her karede
/// yeniden hesaplanan bir geçiş olduğundan performansı düşürdü. Konu bunun
/// yerine `_Header`'ın üstünde sabit, büyük bir başlık olarak durur; app
/// bar'da hiç görünmez.
///
/// Android'de, ekrandan geri çıkılırken (`Navigator.pop`) tüm ekran canlı
/// haliyle DEĞİL, o anki görünümünün az önce çekilmiş sabit bir
/// görüntüsüyle animasyonlanır (bkz. `_watchForExit`). Sebep, gövdedeki
/// WebView'ın (`_HtmlWebView`) çökmeyi önlemek için kullandığı Hybrid
/// Composition (bkz. o widget'ın belgesi): bu kip WebView'ı Flutter'ın kendi
/// Skia sahnesi yerine Android'in View ağacına yerleştirir; geçiş
/// animasyonunun uyguladığı solma/kaydırma ikisini aynı karede senkron
/// tutamayıp ekranda "yırtılma" (tearing) yapar (flutter/flutter#104889).
/// Donmuş görüntü düz bir Flutter widget'ı olduğundan bu sorunu yaşamaz.
/// Görüntü, ekranın TAMAMI (sadece WebView değil) için ve İÇERİĞİN BOYU
/// DEĞİL yalnızca o anki görünen alan (viewport) için çekilir — aksi hâlde
/// uzun bir e-postada bellekte devasa bir görüntü tutulurdu.
class MailDetailScreen extends ConsumerStatefulWidget {
  const MailDetailScreen({super.key, required this.messageId});

  final int messageId;

  @override
  ConsumerState<MailDetailScreen> createState() => _MailDetailScreenState();
}

class _MailDetailScreenState extends ConsumerState<MailDetailScreen> {
  late int _messageId = widget.messageId;

  /// Son yüklenen ileti — önceki/sonraki iletiye geçerken yeni satır bir kare
  /// sonra gelir; o arada ekran "bulunamadı"ya düşüp kaydırma alanını baştan
  /// kurmasın diye bu gösterilmeye devam eder.
  MessageRow? _shownMessage;
  Timer? _seenTimer;

  final ScrollController _scrollController = ScrollController();

  /// Ekranın TAMAMINI (viewport boyunda) sarar — geri çıkışta donmuş görüntü
  /// çekmek için (bkz. `_watchForExit`).
  final GlobalKey _screenBoundaryKey = GlobalKey();
  ui.Image? _frozenScreenshot;
  bool _frozen = false;
  Animation<double>? _exitAnimation;
  void Function(AnimationStatus)? _exitListener;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Yalnızca bir kez kurulur (`_exitAnimation` ilk seferden sonra dolu
    // olur) — yalnızca Android'de (bkz. sınıf belgesi, iOS'ta bu sorun yok).
    if (_exitAnimation == null &&
        defaultTargetPlatform == TargetPlatform.android) {
      _watchForExit();
    }
  }

  @override
  void dispose() {
    _seenTimer?.cancel();
    _scrollController.dispose();
    _cancelExitListener();
    _frozenScreenshot?.dispose();
    super.dispose();
  }

  /// Route'un kendi geçiş animasyonu TERSİNE dönmeye (`reverse`, kullanıcı
  /// geri gitti) başladığı anda ekranın o anki görüntüsünü yakalayıp donmuş
  /// gösterime geçer (bkz. sınıf belgesi). Görüntü henüz hazır değilse (yakalama
  /// bir çerçeve sürer) canlı görünüm kısa süre kalır — boş bir alan
  /// göstermektense yırtılma riski göze alınır. Geri kaydırma yarıda
  /// bırakılıp ekran tekrar tam açılırsa (`completed`) canlı görünüme döner.
  void _watchForExit() {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null) return;
    void listener(AnimationStatus status) {
      if (status == AnimationStatus.reverse) {
        unawaited(_freezeForExit());
      } else if (status.isCompleted && _frozen) {
        setState(() => _frozen = false);
      }
    }

    _exitAnimation = animation;
    _exitListener = listener;
    animation.addStatusListener(listener);
  }

  void _cancelExitListener() {
    final animation = _exitAnimation;
    final listener = _exitListener;
    if (animation != null && listener != null) {
      animation.removeStatusListener(listener);
    }
    _exitAnimation = null;
    _exitListener = null;
  }

  Future<void> _freezeForExit() async {
    final boundary = _screenBoundaryKey.currentContext?.findRenderObject();
    // `reverse` yalnızca ekran tam görünür olduktan (route `completed`e
    // ulaştıktan) sonra tetiklenebilir, bu yüzden burada zaten en az bir kez
    // boyanmıştır; olmayan bir durumda `toImage()`in kendi hatası aşağıdaki
    // `catch` ile yakalanır.
    if (boundary is! RenderRepaintBoundary) return;
    ui.Image image;
    try {
      image = await boundary.toImage(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
    } catch (_) {
      // Yakalanamadı: canlı görünüm kalır (bkz. `_watchForExit` belgesi).
      return;
    }
    if (!mounted) {
      image.dispose();
      return;
    }
    _frozenScreenshot?.dispose();
    _frozenScreenshot = image;
    setState(() => _frozen = true);
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
    // Yeni ileti en üstten, konusu büyük hâliyle açılır.
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _scheduleMarkSeen();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final messageAsync = ref.watch(messageProvider(_messageId));
    if (messageAsync.value case final loaded?) _shownMessage = loaded;
    final message =
        messageAsync.value ?? (messageAsync.isLoading ? _shownMessage : null);
    final body = ref.watch(messageBodyProvider(_messageId)).value;
    final bodyFetch = ref.watch(bodyFetchProvider(_messageId));
    final attachments =
        ref.watch(attachmentsProvider(_messageId)).value ?? const [];
    final rows = ref.watch(messageListProvider).value ?? const <MessageRow>[];
    final index = rows.indexWhere((m) => m.id == _messageId);

    if (message == null) {
      // İlk açılışta satır veritabanından bir kare sonra gelir: o kare boş
      // geçer, "bulunamadı" yalnızca ileti gerçekten yoksa gösterilir.
      final loading = messageAsync.isLoading;
      return Scaffold(
        backgroundColor: t.readingBg,
        appBar: AppBar(
          leading: const _BackButton(),
          title: loading ? null : const Text('İleti'),
        ),
        body: loading
            ? null
            : const EmptyState(
                icon: LucideIcons.mailX,
                title: 'İleti bulunamadı',
                description: 'Bu ileti silinmiş veya taşınmış olabilir.',
              ),
      );
    }

    final subject = message.subject.trim().isEmpty
        ? '(konu yok)'
        : message.subject;

    return RepaintBoundary(
      key: _screenBoundaryKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Donmuş gösterim sırasında canlı ekran çizilmez ve dokunuşları
          // almaz (`Offstage`) ama ağaçta KALIR — WebView'ın platform
          // görünümü asla sökülüp yeniden kurulmaz (bkz. sınıf belgesi).
          Offstage(
            offstage: _frozen,
            child: PrimaryScrollController(
              // iOS'ta durum çubuğuna dokunmak (Scaffold) bu kaydırma alanını
              // başa sarar. Boş platform kümesi: kontrolcü vermeyen başka
              // kaydırılabilirler (ör. "Diğer" menüsünün paneli) buna
              // kendiliğinden bağlanmaz.
              controller: _scrollController,
              automaticallyInheritForPlatforms: const <TargetPlatform>{},
              child: Scaffold(
                backgroundColor: t.readingBg,
                body: ScrollConfiguration(
                  // Android'in esneme (stretch) efekti tüm görünüm alanını ölçekler:
                  // sabitlenmiş app bar da esner, WebView (platform görünümü) ise bu
                  // dönüşümü almadığı için çevresinden kayar. Bu ekranda kapalı.
                  behavior: ScrollConfiguration.of(
                    context,
                  ).copyWith(overscroll: false),
                  child: CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      SliverAppBar(
                        // `expandedHeight`/`flexibleSpace` YOK: app bar kaydırma
                        // konumundan bağımsız, sabit boyutlu (bkz. `MailDetailScreen`
                        // belgesi) — her scroll karesinde yeniden hesaplanan bir
                        // boyut/opaklık geçişi yok.
                        pinned: true,
                        leading: const _BackButton(),
                        actions: [
                          IconButton(
                            icon: const Icon(
                              LucideIcons.chevronUp,
                              size: IconSize.md,
                            ),
                            tooltip: 'Önceki ileti',
                            onPressed: index > 0 ? () => _navigate(-1) : null,
                          ),
                          IconButton(
                            icon: const Icon(
                              LucideIcons.chevronDown,
                              size: IconSize.md,
                            ),
                            tooltip: 'Sonraki ileti',
                            onPressed: index >= 0 && index < rows.length - 1
                                ? () => _navigate(1)
                                : null,
                          ),
                          const SizedBox(width: Space.xs),
                        ],
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            Space.lg,
                            Space.md,
                            Space.lg,
                            0,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(
                                subject,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: Space.md),
                              _Header(message: message),
                              const SizedBox(height: Space.lg),
                              if (attachments.isNotEmpty) ...[
                                _AttachmentStrip(attachments: attachments),
                                const SizedBox(height: Space.lg),
                              ],
                            ],
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Divider(color: t.divider, height: 1),
                      ),
                      SliverToBoxAdapter(
                        child: _BodyView(
                          body: body,
                          fetchStatus: bodyFetch,
                          onRetry: () =>
                              ref.invalidate(bodyFetchProvider(_messageId)),
                        ),
                      ),
                    ],
                  ),
                ),
                bottomNavigationBar: _ActionBar(message: message),
              ),
            ),
          ),
          if (_frozen && _frozenScreenshot != null)
            Positioned.fill(
              child: RawImage(image: _frozenScreenshot, fit: BoxFit.fill),
            ),
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(LucideIcons.arrowLeft),
      tooltip: 'Geri',
      onPressed: () => Navigator.of(context).pop(),
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
        // Konu burada değil, hemen üstünde — bkz. `MailDetailScreen.build`.
        if (_labelNames.isNotEmpty) ...[
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              for (final name in _labelNames)
                LabelChip(name: name, toneIndex: 0),
            ],
          ),
          const SizedBox(height: Space.lg),
        ],
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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          message.fromName.isEmpty
                              ? message.fromEmail
                              : message.fromName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (message.isFlagged)
                        Padding(
                          padding: const EdgeInsets.only(left: Space.sm),
                          child: Icon(
                            LucideIcons.pin,
                            size: IconSize.sm,
                            color: t.accent,
                          ),
                        ),
                    ],
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
      return _padded(
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
      // İçeriğinin boyuna uzar; dikey kaydırmayı ekranın tek kaydırma alanı
      // yapar (bkz. `_HtmlWebView`). İki parmakla yakınlaştırma bunun
      // üstüne ayrı bir katman olarak eklenir (bkz. `_PinchZoomableBody`).
      return _PinchZoomableBody(
        contentKey: body!.messageId,
        child: _HtmlWebView(html: html),
      );
    }

    if (plain != null && plain.trim().isNotEmpty) {
      return _padded(
        SelectableText(plain, style: Theme.of(context).textTheme.bodyLarge),
      );
    }

    return _padded(
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

  /// Gövde ekranın tek kaydırma alanının parçasıdır (bkz. `MailDetailScreen`);
  /// kendi kaydırma görünümü yoktur — iç içe kaydırma oluşmaz.
  Widget _padded(Widget child) => Padding(
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
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.md,
        Space.lg,
        Space.xxl,
      ),
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

/// Gövdeye iki parmakla yakınlaştırma ekler — bazı bültenler/faturalar çok
/// küçük punto ile geliyor. Referans, Outlook mobilin mail okuma
/// deneyimidir: doğal, parmağa yapışık bir pinch, sıçramasız yakınlaştırma
/// ve parmak kalktıktan sonra akıcı bir toparlanma.
///
/// `_HtmlWebView`'ın kendi (native) yakınlaştırması bilinçli olarak kapalı
/// (bkz. o widget'ın belgesi): içerik boyuna uzatılmış bir WebView'da
/// büyütülen içerik dikeyde kaydırılamaz. Bunun yerine burada saf `Listener`
/// ile İKİ (veya daha fazla) parmağın konumu izlenir ve ölçek/kaydırma elle
/// hesaplanıp bir `Transform` ile uygulanır — jest arenasına HİÇ girilmez
/// (`Listener`, `GestureRecognizer` gibi bir hareketi tekeline almaz, sadece
/// izler). Böylece tek parmakla kaydırma, bağlantı dokunuşu, uzun basmayla
/// metin seçme ve yatay sürükleme (`_HtmlWebView`nin kendi tanıyıcıları)
/// aynen öncekiler gibi çalışmaya devam eder; yalnızca ikinci parmak
/// eklendiğinde yakınlaştırma devreye girer. Büyütülen alan kendi kutusunun
/// sınırlarıyla kırpılır (`ClipRect`) — komşu widget'ların (konu başlığı,
/// ekler) üstüne taşmaz.
///
/// BİLİNÇLİ SINIRLAMA: yakınlaştırılmışken TEK parmakla sürükleme, dıştaki
/// `CustomScrollView`ı kaydırmaya devam eder (büyütülmüş alanı olduğu gibi
/// yukarı/aşağı kaydırır); yakınlaştırılmış görünüm İÇİNDE gezinmek pinch'i
/// sürdürerek İKİ parmakla yapılır (native fotoğraf görüntüleyicilerdeki
/// gibi — ölçek sabit tutulup yalnızca iki parmak birlikte kaydırılabilir).
/// Gerçek bir tarayıcıdaki "yakınlaştır, sonra tek parmakla gez" hissinin
/// tam eşleniği değil, ama bunun bedeli ağır: tek parmağı yakınlaştırılmışken
/// ele geçirip ölçek 1'e dönünce dıştaki kaydırmaya geri bırakmak,
/// `Scrollable`ın kendi tanıyıcısıyla jest arenasında rekabete giren özel bir
/// `GestureRecognizer` gerektirir — bu da yukarıdaki "arenaya hiç girilmez"
/// ilkesini bozup bağlantı dokunuşu/metin seçimi/yatay kaydırmayı regresyona
/// sokma riski taşır.
class _PinchZoomableBody extends StatefulWidget {
  const _PinchZoomableBody({required this.contentKey, required this.child});

  /// İçerik değişince (başka bir iletiye geçilince) yakınlaştırmayı
  /// sıfırlamak için kullanılan kimlik — pratikte ileti id'si.
  /// `_HtmlWebView`, önceki/sonraki iletiye akıcı geçiş için bilerek AYNI
  /// örnekte kalır (bkz. o widget'ın belgesi); bu widget da bu yüzden aynı
  /// `State`i korur ve zum durumu kendiliğinden sıfırlanmaz — dışarıdan bu
  /// sinyal olmasa yeni bir iletiye önceki iletinin yakınlaştırmasıyla
  /// girilirdi.
  final Object contentKey;

  final Widget child;

  @override
  State<_PinchZoomableBody> createState() => _PinchZoomableBodyState();
}

class _PinchZoomableBodyState extends State<_PinchZoomableBody>
    with SingleTickerProviderStateMixin {
  static const double _minScale = 1;
  static const double _maxScale = 4;

  /// Sınırın (`_minScale`/`_maxScale`) ötesine ne kadar esneyebileceği —
  /// kauçuk bant hissi. Parmak bırakılınca `_snapToBounds` bunu geçerli
  /// aralığa geri toplar.
  static const double _overscrollFriction = 0.4;

  /// Parmak(lar) kalktıktan sonra sınıra/kimliğe toparlanırken kullanılan
  /// yanıt hızı (1/sn) — yalnızca BU geçiş animasyonludur. Parmaklar
  /// ekrandayken ölçek/kaydırma parmaklara BİREBİR (gecikmesiz) uyar (bkz.
  /// `_onPointerMove`): gerçek cihazların (iOS/Android) yerel pinch-zoom'unda
  /// hissedilen bir gecikme yoktur. Önceki sürümde bu yumuşatma aktif pinch
  /// sırasında da uygulanıyordu; bu da parmağın birkaç kare gerisinde kalan,
  /// "lastik gibi" amatör bir his veriyordu.
  static const double _snapResponse = 12;

  /// O anda ekranda olan parmaklar (pointer id → son konum) — `Listener`in
  /// kendi kutusuna göre, yani DÖNÜŞÜMDEN ÖNCEKİ ham koordinatlarla.
  final Map<int, Offset> _pointers = {};

  // Parmakların o an hedeflediği (ham, kauçuk bantlı olabilen) değer.
  double _targetScale = 1;
  Offset _targetOffset = Offset.zero;

  // Ekrana çizilen değer. Parmaklar ekrandayken `_targetScale`/`_targetOffset`
  // ile birebir aynıdır; yalnızca son parmak kalktıktan sonraki toparlanma
  // sırasında bundan ayrılıp `_onTick` ile hedefe yumuşakça yaklaşır.
  double _scale = 1;
  Offset _offset = Offset.zero;

  /// `_boundsKey`in gerçek (yerleşmiş) kutu boyu — bkz. `_measureSize`.
  /// `LayoutBuilder`+`constraints.biggest` KASITLI olarak kullanılmaz: bu
  /// widget bir `SliverToBoxAdapter` içinde, kaydırma ekseninde SINIRSIZ bir
  /// üst kısıtla (`maxHeight: double.infinity`) düzenlenir — slivers,
  /// içeriğin kendi boyuna göre uzasın diye kısıtı böyle verir. Önceki sürüm
  /// tam da bu kısıtı (`constraints.biggest`) boy olarak kullanıyordu; sonuç
  /// `Size(genişlik, double.infinity)` idi ve dikey kaydırma sınırlaması
  /// (`_clamp`) etkisiz kalıyordu — yakınlaştırılmış içerik dikeyde SINIRSIZ
  /// sürüklenebiliyor, parmak kalkınca da (sınır zaten "yok" sayıldığından)
  /// asla geri toplanmıyordu. Burada bunun yerine gerçek, ÇÖZÜLMÜŞ yerleşim
  /// boyu bir `GlobalKey` üzerinden doğrudan `RenderBox`tan okunur.
  final GlobalKey _boundsKey = GlobalKey();
  Size _size = Size.zero;

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  // İki parmaklı hareketin başladığı (ya da parmak sayısı değiştiği) andaki
  // anlık görüntü — sonraki her `onPointerMove` bu referansa göre yeni ölçek/
  // odak noktasını hesaplar. `_startScale`/`_startOffset` EKRANDA O AN
  // GÖRÜNEN (`_scale`/`_offset`) değerden alınır, `_targetScale`/
  // `_targetOffset`den DEĞİL — parmak tam da bir toparlanma animasyonunun
  // ortasında ekrana değerse (nadir ama mümkün) yeni pinch'in aniden
  // animasyonun BİTİŞ değerine sıçramasını önler.
  double _startSpan = 0;
  double _startScale = 1;
  Offset _startFocal = Offset.zero;
  Offset _startOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    // Boşta (parmak yokken) kare tüketmemesi için yalnızca toparlanma
    // gerektiğinde (`_snapToBounds`) başlatılır.
    _ticker = createTicker(_onTick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureSize());
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _PinchZoomableBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Başka bir iletiye geçildi: `_HtmlWebView` aynı örnekte kalıp içeriği
    // yerinde değiştirdiği için (akıcı geçiş, bkz. o widget'ın belgesi) bu
    // State de kendiliğinden sıfırlanmaz — önceki iletinin yakınlaştırması
    // yeni iletiye taşınmasın diye elle sıfırlanır.
    if (oldWidget.contentKey != widget.contentKey) {
      _pointers.clear();
      _ticker.stop();
      _targetScale = _minScale;
      _targetOffset = Offset.zero;
      _scale = _minScale;
      _offset = Offset.zero;
      // Yeni iletinin gövdesi farklı yükseklikte olabilir.
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureSize());
    }
  }

  /// `_boundsKey`in gerçek yerleşim boyunu okur. Yalnızca boy GERÇEKTEN
  /// değiştiyse `setState` tetikler.
  void _measureSize() {
    if (!mounted) return;
    final box = _boundsKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final size = box.size;
    if (size != _size) setState(() => _size = size);
  }

  void _startTicking() {
    if (!_ticker.isTicking) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  /// Render edilen `_scale`/`_offset`i hedefe üstel biçimde yaklaştırır.
  /// Yalnızca son parmak kalktıktan sonraki toparlanma sırasında çalışır —
  /// parmaklar ekrandayken hiç çağrılmaz (bkz.
  /// `_onPointerMove`, orada değerler doğrudan atanır). Kare süresinden
  /// bağımsızdır (`dtSeconds` ile ölçeklenir) — cihazın tazeleme hızı
  /// 60/90/120 Hz farketmeksizin aynı hissi verir.
  void _onTick(Duration elapsed) {
    final rawDt = _lastTick == Duration.zero ? elapsed : elapsed - _lastTick;
    _lastTick = elapsed;
    final dtSeconds = (rawDt.inMicroseconds / Duration.microsecondsPerSecond)
        .clamp(0.0, 1 / 30);

    final t = 1 - math.exp(-_snapResponse * dtSeconds);
    final nextScale = _scale + (_targetScale - _scale) * t;
    final nextOffset = _offset + (_targetOffset - _offset) * t;

    final settled =
        (nextScale - _targetScale).abs() < 0.002 &&
        (nextOffset - _targetOffset).distance < 0.1;
    setState(() {
      _scale = settled ? _targetScale : nextScale;
      _offset = settled ? _targetOffset : nextOffset;
    });
    if (settled) _ticker.stop();
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      // Yeni pinch: olası bir toparlanma animasyonunun ortasındaysak onu
      // kesip parmaklar O ANKİ render edilen değeri devralır (bkz.
      // `_startScale`/`_startOffset` alan belgesi).
      _ticker.stop();
      _armGesture();
    }
  }

  void _armGesture() {
    final points = _pointers.values.toList(growable: false);
    _startSpan = (points[0] - points[1]).distance;
    _startScale = _scale;
    _startFocal = (points[0] + points[1]) / 2;
    _startOffset = _offset;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length < 2 || _startSpan < 1 || _size == Size.zero) return;

    final points = _pointers.values.toList(growable: false);
    final span = (points[0] - points[1]).distance;
    final focal = (points[0] + points[1]) / 2;
    final rawScale = _startScale * span / _startSpan;
    final scale = _softClamp(rawScale, _minScale, _maxScale);

    // `Transform`ın `alignment: Alignment.center`i yüzünden bir içerik
    // noktası `p` ekranda `center + offset + ölçek*(p - center)`e düşer.
    // Pinch'in başladığı andaki bu denklemden, parmakların o an TAM ÜSTÜNDE
    // durduğu içerik noktası (`anchor`) geriye çözülür; sonra AYNI nokta
    // yeni ölçekte parmakların GÜNCEL orta noktasına (`focal`) denk
    // düşecek şekilde `rawOffset` ileri hesaplanır — bu da parmakların
    // altındaki içeriği pinch boyunca tam parmakların altında tutar. ÖNCEKİ
    // sürüm burada yalnızca odak noktasının HAM hareketini offsete
    // ekliyordu (`_startOffset + (focal - _startFocal)`); bu yalnızca odak
    // tam merkezdeyken doğruydu — merkez dışı bir noktada (ör. bir görselin
    // üstünde) pinch yapılınca ölçek büyüdükçe içerik parmaklardan kayardı.
    final center = _size.center(Offset.zero);
    final anchor = center + (_startFocal - center - _startOffset) / _startScale;
    final rawOffset = focal - center - (anchor - center) * scale;

    setState(() {
      _targetScale = scale;
      _targetOffset = _clamp(rawOffset, scale);
      _scale = _targetScale;
      _offset = _targetOffset;
    });
  }

  void _onPointerGone(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.length >= 2) {
      _armGesture();
    } else if (_pointers.isEmpty) {
      _snapToBounds();
    }
  }

  /// Son parmak da kalkınca: kauçuk bantla sınırın az ötesindeyse geçerli
  /// aralığa, 1'e yakınsa tam kimliğe (`scale=1, offset=0`) yumuşakça
  /// toparlar — `_onTick` bunu akıcı bir animasyona çevirir, aksi halde
  /// (anlık `setState`) tam da şikayet edilen "sınırda kaybolma" sıçraması
  /// oluşurdu.
  void _snapToBounds() {
    final clamped = _targetScale.clamp(_minScale, _maxScale);
    _targetScale = clamped <= _minScale + 0.05 ? _minScale : clamped;
    _targetOffset = _targetScale <= _minScale
        ? Offset.zero
        : _clamp(_targetOffset, _targetScale);
    if (_targetScale == _scale && _targetOffset == _offset) return;
    _startTicking();
  }

  /// Üst sınırın ötesine sert bir duvara çarpmış gibi değil, esneyerek gider
  /// (kauçuk bant) — parmak bırakılınca `_snapToBounds` bunu geri toplar.
  /// Ne kadar hızlı/geniş bir jestte bile mantıksız büyüklüklere gitmesin
  /// diye esneme payının kendi de bir tavanla (`max * 1.5`) sınırlanır.
  ///
  /// Alt sınırın (1x, "normal boy") ASLA altına inmez — kasıtlı: içeriği
  /// normal boyutundan küçültmenin okumada bir faydası yok, ÜSTELİK önceki
  /// sürümde burada da esneme uygulanınca `scale < 1` oluyor, bu da
  /// `_clamp`teki `(scale - 1)` ifadesini negatife düşürüp `offset.dx.clamp`
  /// çağrısını `min > max` haliyle çöktürüyordu — kullanıcının "aşırı
  /// uzaklaştırınca mail kayboluyor" diye bildirdiği hata tam buydu.
  double _softClamp(double value, double min, double max) {
    if (value <= min) return min;
    if (value > max) {
      final capped = math.min(value, max * 1.5);
      return max + (capped - max) * _overscrollFriction;
    }
    return value;
  }

  Offset _clamp(Offset offset, double scale) {
    // `scale <= 1` iken kaydırılacak bir şey yoktur (içerik viewport'u
    // taşmaz) — bunu erken döndürmek hem doğru davranış hem de aşağıdaki
    // `(scale - 1)` negatif olup `min > max` ile çökmesini YAPISAL olarak
    // imkânsız kılar (bkz. `_softClamp` notu).
    if (scale <= 1) return Offset.zero;
    if (_size == Size.zero) return offset;
    final maxDx = _size.width * (scale - 1) / 2;
    final maxDy = _size.height * (scale - 1) / 2;
    return Offset(
      offset.dx.clamp(-maxDx, maxDx),
      offset.dy.clamp(-maxDy, maxDy),
    );
  }

  @override
  Widget build(BuildContext context) {
    // `SizeChangedLayoutNotifier`, `_boundsKey`in gerçek kutusu her yeniden
    // yerleşimde ÖLÇÜSÜ değiştiğinde (içerik yüklendikçe, ekran döndükçe)
    // bunu yukarı bildirir; boy bir sonraki karede (yerleşim kesinleştikten
    // sonra) `_measureSize` ile yeniden okunur (bkz. `_size` alan belgesi).
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _measureSize());
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: ClipRect(
          key: _boundsKey,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: (e) => _onPointerGone(e.pointer),
            onPointerCancel: (e) => _onPointerGone(e.pointer),
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..translate(_offset.dx, _offset.dy)
                ..scale(_scale),
              child: widget.child,
            ),
          ),
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
///
/// Kendi içinde KAYDIRMAZ: render betiği içeriğin yüksekliğini bildirir (bkz.
/// `MailHtmlDocument.layoutChannel`) ve WebView o boya uzatılır; dikey
/// kaydırma, başlıkla birlikte ekranın tek `CustomScrollView`ındadır. WebView
/// yalnızca dokunma (bağlantılar), uzun basma (metin seçimi) ve yatay sürükleme
/// (sığmayan geniş içerik) hareketlerini alır. Yakınlaştırma kapalıdır:
/// içerik boyundaki bir WebView'da büyütülen içerik dikeyde kaydırılamazdı.
/// Sığmayan sabit genişlikli e-postalar Android'de yine "ekrana sığdır" ile
/// açılır (`useWideViewPort` + overview kipi, yakınlaştırma ayarından
/// bağımsızdır).
///
/// Ekranın kendisinin geri geçişte (bkz. `MailDetailScreen` belgesi) donmuş
/// bir görüntüyle animasyonlanması, buradaki Hybrid Composition WebView'ın
/// geçiş sırasında ekranda "yırtılmasını" (tearing) da önler.
class _HtmlWebView extends StatefulWidget {
  const _HtmlWebView({required this.html});

  final String html;

  @override
  State<_HtmlWebView> createState() => _HtmlWebViewState();
}

class _HtmlWebViewState extends State<_HtmlWebView> {
  /// İçerik ölçülene kadarki boy — yalnızca yükleme iskeletini taşıyacak kadar.
  static const double _placeholderHeight = 200;

  /// Son emniyet: bozuk bir yerleşim WebView'ı sınırsız uzatamasın. Gerçek
  /// iletiler bunun çok altında kalır.
  static const double _maxHeight = 100000;

  /// WebView'ın kendisine aldığı hareketler. Listede olmayan dikey sürükleme
  /// dıştaki kaydırma alanında kalır — gövdenin üstünden de kaydırılır ve
  /// başlık geçişi çalışır. Tek dokunuşlar (bağlantılar) listede olmasa da
  /// başka hiçbir tanıyıcı sahiplenmediği için WebView'a ulaşır.
  static final Set<Factory<OneSequenceGestureRecognizer>> _gestures = {
    Factory<LongPressGestureRecognizer>(LongPressGestureRecognizer.new),
    Factory<HorizontalDragGestureRecognizer>(
      HorizontalDragGestureRecognizer.new,
    ),
  };

  late final WebViewController _controller;
  late final Widget _webView;

  // `_load()` art arda (ör. ilk `didChangeDependencies` hemen ardından
  // `didUpdateWidget`) tetiklenirse, önce başlayan ama geç biten bir isolate
  // çağrısı sonucu yeni içeriğin üzerine yazmasın diye her çağrının kendi
  // sırası tutulur. Belgeye de kimlik olarak yazılır: yerine yenisi yüklenmiş
  // eski belgeden geç gelen yükseklik bildirimi bununla ayıklanır.
  int _loadToken = 0;

  // Belgenin en son hangi temayla kurulduğu. Tema `initState`te okunamayan bir
  // InheritedWidget'tır; bu yüzden ilk yükleme `didChangeDependencies`te yapılır.
  KaydetTokens? _tokens;
  Timer? _themeReload;
  Timer? _measureFallback;

  // İlk yüklemenin, ekranın giriş geçişi bitene kadar ertelenmesi için (bkz.
  // `_scheduleInitialLoad`) — geçiş erken kapanırsa (ör. geri dönüldüyse)
  // dinleyici sızmasın diye `dispose()`ta temizlenir.
  Animation<double>? _entranceAnimation;
  void Function(AnimationStatus)? _entranceListener;

  /// WebView'ın ekrandaki genişliği (mantıksal piksel).
  double _viewWidth = 0;

  // Betiğin son bildirdiği içerik yüksekliği ve görünen alan genişliği (CSS px).
  double? _cssHeight;
  double? _cssWidth;

  /// Gövdenin ekrandaki yüksekliği; `null` iken içerik henüz ölçülmedi ve
  /// WebView'ın üstünde yükleme iskeleti durur.
  double? _height;

  @override
  void initState() {
    super.initState();
    // JS açık: çalışan tek betik `MailHtmlDocument`in nonce'lu render
    // betiğidir; e-postanın kendi betikleri belgedeki CSP ile engellenir.
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(false)
      ..setVerticalScrollBarEnabled(false)
      ..setOverScrollMode(WebViewOverScrollMode.never)
      ..addJavaScriptChannel(
        MailHtmlDocument.layoutChannel,
        onMessageReceived: _onLayoutMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: _onPageFinished,
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
    // Android'de Hybrid Composition: varsayılan (doku tabanlı) kip platform
    // görünümünü boyutu kadar bir dokuya çizer; içerik boyuna uzatılmış uzun
    // bir WebView o dokuya sığmaz ve uygulama çöker (flutter/flutter#104889,
    // #116954). Hybrid Composition WebView'ı gerçek bir Android görünümü
    // olarak yerleştirir; yalnızca ekranda görünen kısmı çizilir.
    _webView = platform is AndroidWebViewController
        ? WebViewWidget.fromPlatformCreationParams(
            params: AndroidWebViewWidgetCreationParams(
              controller: platform,
              displayWithHybridComposition: true,
              gestureRecognizers: _gestures,
            ),
          )
        : WebViewWidget(controller: _controller, gestureRecognizers: _gestures);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tokens = context.tokens;
    final previous = _tokens;
    _tokens = tokens;
    // WebView'ın kendi zemini sayfa yüklenmeden önce ve kaydırma taşmasında
    // görünür; beyaz kalırsa koyu temada göz yakan bir flaş olur.
    unawaited(_controller.setBackgroundColor(tokens.readingBg));

    if (previous == null) {
      _scheduleInitialLoad();
    } else if (previous.isDark != tokens.isDark ||
        previous.readingBg != tokens.readingBg ||
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
    _measureFallback?.cancel();
    _cancelEntranceListener();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _HtmlWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      // Yeni içerik: eski ölçü geçersizdir; yeni belge ölçülene kadar iskelet.
      _height = null;
      _cssHeight = null;
      _cssWidth = null;
      unawaited(_load());
    }
  }

  /// İlk yükleme (büyük gövdelerde platform kanalından geçen ağır
  /// `loadHtmlString` çağrısı, ardından isolate/JS işi) ekranın giriş geçişi
  /// (push animasyonu, bkz. `KaydetRoute`) bitene kadar ertelenir. İkisi aynı
  /// karede yarışırsa — özellikle uzun/ağır e-postalarda — geçiş sırasında
  /// gözle görülür bir takılmaya yol açar. Geçiş zaten bitmişse (route
  /// yoksa/animasyonsuzsa, ya da içerik geç geldiği için ekran zaten
  /// oturmuşsa) hemen yüklenir; yalnızca ekranın İLK açılışını etkiler —
  /// tema değişimi ve önceki/sonraki ileti geçişleri buradan geçmez.
  void _scheduleInitialLoad() {
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      unawaited(_load());
      return;
    }
    void listener(AnimationStatus status) {
      if (!status.isCompleted) return;
      _cancelEntranceListener();
      if (mounted) unawaited(_load());
    }

    _entranceAnimation = animation;
    _entranceListener = listener;
    animation.addStatusListener(listener);
  }

  void _cancelEntranceListener() {
    final animation = _entranceAnimation;
    final listener = _entranceListener;
    if (animation != null && listener != null) {
      animation.removeStatusListener(listener);
    }
    _entranceAnimation = null;
    _entranceListener = null;
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
          documentId: token,
        ),
      ),
    );
  }

  /// Render betiğinin yükseklik bildirimi: `{doc, h, w}` (CSS pikseli).
  void _onLayoutMessage(JavaScriptMessage message) {
    final Object? data;
    try {
      data = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    if (data case {
      'doc': final int doc,
      'h': final num h,
      'w': final num w,
    } when doc == _loadToken) {
      _cssHeight = h.toDouble();
      _cssWidth = w.toDouble();
      _applyHeight();
    }
  }

  void _applyHeight() {
    final cssHeight = _cssHeight;
    final cssWidth = _cssWidth;
    if (!mounted || cssHeight == null || cssWidth == null) return;
    if (cssWidth <= 0 || _viewWidth <= 0) return;
    // Ekrandaki boy = CSS boyu × ölçek. Ölçek genellikle 1'dir; sığmayan
    // sabit genişlikli e-postalar Android'de uzaklaştırılmış (< 1) açılır.
    final height = clampDouble(
      (cssHeight * _viewWidth / cssWidth).ceilToDouble(),
      1,
      _maxHeight,
    );
    _measureFallback?.cancel();
    if (height != _height) setState(() => _height = height);
  }

  void _trackViewWidth(double width) {
    if (width == _viewWidth) return;
    _viewWidth = width;
    // Genişlik değişince (döndürme) içerik yeniden akar ve betik yeni ölçüyü
    // kendisi bildirir. Yalnızca ilk bildirim WebView yerleşmeden gelmişse
    // (beklenmez) genişlik belli olunca uygulanır.
    if (_height == null && _cssHeight != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyHeight());
    }
  }

  /// Emniyet ağı: render betiği yüksekliği bildiremezse (beklenmez) iskelet
  /// sonsuza dek kalmasın — sayfa yüklendikten kısa süre sonra yükseklik
  /// doğrudan sorulur.
  void _onPageFinished(String url) {
    if (_height != null) return;
    _measureFallback?.cancel();
    _measureFallback = Timer(const Duration(seconds: 1), _measureDirectly);
  }

  Future<void> _measureDirectly() async {
    final token = _loadToken;
    Object? ratio;
    try {
      // İçerik yüksekliğinin görünen alan genişliğine oranı (ikisi de CSS
      // px): ekrandaki yükseklik = oran × WebView genişliği.
      ratio = await _controller.runJavaScriptReturningResult(
        'document.documentElement.scrollHeight / '
        '((window.visualViewport && window.visualViewport.width) || '
        'window.innerWidth)',
      );
    } catch (_) {
      // Ölçülemedi: iskelet yer tutucu boyda kalkar.
    }
    if (!mounted || token != _loadToken || _height != null) return;
    final height = ratio is num && ratio > 0 && _viewWidth > 0
        ? (ratio * _viewWidth).ceilToDouble()
        : _placeholderHeight;
    setState(() => _height = clampDouble(height, 1, _maxHeight));
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
    return LayoutBuilder(
      builder: (context, constraints) {
        _trackViewWidth(constraints.maxWidth);
        return SizedBox(
          height: _height ?? _placeholderHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _webView,
              // İçerik ölçülene kadar gövde iskeleti WebView'ın üstünde durur
              // (anında belirir); ölçü gelince yumuşakça söner ve ağaçtan
              // çıkar — shimmer animasyonu görünmezken boşuna dönmez.
              AnimatedSwitcher(
                duration: Motion.instant,
                reverseDuration: Motion.base,
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: [...previous, ?current],
                ),
                child: _height == null
                    ? ColoredBox(
                        color: t.readingBg,
                        // Sönerken gövde iskeletten kısa olabilir: iskelet
                        // kendi boyunda çizilip kırpılır, taşma olmaz.
                        child: const ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.topCenter,
                            maxHeight: double.infinity,
                            child: _BodyShimmer(),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Alt eylem çubuğu — Outlook mobil gibi eşit aralıklı, aynı görünümde ikon
/// düğmeler: Yanıtla / İlet / Arşivle / Sil / Diğer. Hiçbiri öne çıkarılmaz.
/// "Tümünü Yanıtla" ayrı bir düğme DEĞİL — [_MoreMenu]nin en üstünde (bkz. o
/// widget'ın belgesi); iki yanıt eylemini iki ayrı düğme olarak göstermek
/// çubuğu kalabalıklaştırıyordu.
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
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(
                icon: const Icon(LucideIcons.cornerUpLeft),
                tooltip: 'Yanıtla',
                onPressed: () => startCompose(ComposeMode.reply),
              ),
              IconButton(
                icon: const Icon(LucideIcons.cornerUpRight),
                tooltip: 'İlet',
                onPressed: () => startCompose(ComposeMode.forward),
              ),
              IconButton(
                icon: const Icon(LucideIcons.archive),
                tooltip: 'Arşivle',
                onPressed: () async {
                  await repository.archive([message.id]);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
              IconButton(
                icon: const Icon(LucideIcons.trash2),
                tooltip: 'Sil',
                onPressed: () async {
                  final deleted = await deleteWithConfirmation(context, ref, [
                    message.id,
                  ]);
                  if (deleted && context.mounted) Navigator.of(context).pop();
                },
              ),
              _MoreMenu(message: message),
            ],
          ),
        ),
      ),
    );
  }
}

/// Okuma ekranının "..." menüsü — alt eylem çubuğunun sağ ucunda yaşıyor
/// (bkz. `_ActionBar`), eskiden üst `AppBar`'daydı: üst kısmın sade kalması
/// için taşındı. "Tümünü Yanıtla" artık ayrı bir düğme değil, bu menünün EN
/// ÜSTÜNDE — alt çubuktaki tek "Yanıtla" düğmesiyle iki yanıt eylemi aynı
/// anda gösterilmiyor. "Etiketle"/"Klasöre taşı" ayrı bir alttan panel
/// açmıyor, aynı popup içinde kendi alt menüsüne (bkz. `SubmenuButton`)
/// cascade oluyor (bkz. bellek: popup'lar modallara tercih edilir).
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
          leadingIcon: const Icon(LucideIcons.replyAll, size: IconSize.sm),
          onPressed: () => openCompose(
            context,
            ref,
            replyToId: message.id,
            mode: ComposeMode.replyAll,
            fullscreenDialog: true,
            noticeBottomInset: _ActionBar.height,
          ),
          child: const Text('Tümünü yanıtla'),
        ),
        const Divider(height: 1),
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
