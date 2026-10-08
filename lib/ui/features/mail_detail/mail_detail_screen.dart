import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../../app/providers.dart';
import '../../../app/translation_providers.dart';
import '../../../core/date_format.dart';
import '../../../core/result.dart';
import '../../../data/database/app_database.dart';
import '../../../data/repositories/blocked_sender_repository.dart';
import '../../../data/repositories/translation_repository.dart'
    show MailTranslation;
import '../../../domain/models/mail_models.dart';
import '../../../domain/use_cases/attachment_type.dart';
import '../../../domain/use_cases/text_extraction.dart';
import '../../core/actions/attachment_actions.dart';
import '../../core/actions/message_actions.dart';
import '../../core/navigation/kaydet_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/attachment_icon.dart';
import '../../core/widgets/kaydet_notice.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../attachment_preview/attachment_preview_screen.dart';
import '../compose/compose_launcher.dart';
import '../compose/compose_screen.dart' show ComposeMode;
import '../compose/recipient_details_sheet.dart';
import 'mail_html_document.dart';
import 'translate_bar.dart';
import 'webview_pool.dart';

/// Okuma ekranında app bar yüksekliği (varsayılan 56): gövdeye daha çok yer.
const double _compactAppBarHeight = 44;

/// İleti okuma ekranı.
///
/// Yapı: alçak bir app bar, alt eylem çubuğu ve arasında gövde. Gövdenin
/// WebView'ı (bkz. `_HtmlWebView`) bu alanı doldurur ve KENDİ içinde (yerel
/// olarak) kaydırır — içeriğin boyuna uzatılmaz, kaydırırken yeniden
/// boyutlanmaz, Flutter'ın kaydırma alanına katılmaz. Başlık (konu, gönderen,
/// alıcı özeti, ekler, çeviri çubuğu) gövdenin ÜSTÜNDE bir katmandır; gövdenin
/// üstünde başlık boyu kadar boşluk vardır (`--kd-top`) ve başlık, WebView'ın
/// yerel kaydırma konumuyla birebir yukarı kayar (bkz. `_FollowScroll`): sabit
/// kalıp takip etmez. Alıcı ayrıntıları açılınca başlık içeriği itmeden
/// üstüne biner.
///
/// Kaydırma sırasında yalnızca başlığın dönüşümü yenilenir: `setState`,
/// yeniden yükleme, boy ölçümü ya da JavaScript çalışmaz.
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

  // Başlık gövdenin ÜSTÜNDE durur ve kaydırmayla birlikte yukarı kayar.
  // Gövde başlığın altında kalmasın diye WebView'a başlık boyu kadar üst boşluk
  // (`topInset`) verilir.
  final GlobalKey _headerKey = GlobalKey();
  final _BodyScrollBridge _bodyScroll = _BodyScrollBridge();
  double _headerHeight = 0;

  /// Gövdenin dikey kaydırma konumu (mantıksal piksel). Başlık bu değerle
  /// BİREBİR yukarı kayar (bkz. `_FollowScroll`): gövdenin ilk içeriği gibi
  /// kaydırmayla birlikte gider, sabit kalıp takip etmez. Değer bir
  /// `ValueNotifier`da tutulur — her kaydırma olayında ekranın tamamı değil
  /// yalnızca başlığın dönüşümü yeniden çizilir.
  final ValueNotifier<double> _scrollY = ValueNotifier<double>(0);

  Timer? _headerMeasureTimer;

  /// Alıcı ayrıntıları açıkken başlık gövdenin ÜSTÜNE biner (içeriği itmez,
  /// sıçrama olmaz): bu sürede üst boşluk güncellenmez. Kapanınca boy zaten
  /// eski değerine döner.
  bool _recipientsExpanded = false;

  /// Başlığın o anki gerçek boyu (kaydırırken tamamen çıkması için).
  double _currentHeaderHeight() {
    final box = _headerKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size.height : _headerHeight;
  }

  /// Başlık boyu değişince (alıcılar açılırken/kapanırken, çeviri çubuğu
  /// belirirken) gövdenin üst boşluğu güncellenir. Açılma animasyonu sırasında
  /// boy HER KARE değişir; her karede ekranı yeniden kurup WebView'a JS
  /// göndermek kasma yapardı. Bu yüzden ilk ölçüm hemen (içerik başlığın
  /// altında kalmasın), sonrakiler animasyon durulunca TEK kez uygulanır.
  void _measureHeader() {
    _headerMeasureTimer?.cancel();
    if (_headerHeight == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyHeaderHeight());
      return;
    }
    _headerMeasureTimer = Timer(
      const Duration(milliseconds: 180),
      _applyHeaderHeight,
    );
  }

  void _applyHeaderHeight() {
    if (!mounted || _recipientsExpanded) return;
    final box = _headerKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final height = box.size.height;
    if ((height - _headerHeight).abs() < 0.5) return;
    setState(() => _headerHeight = height);
  }

  @override
  void initState() {
    super.initState();
    // Gövde indirme burada ELLE tetiklenmez — `build()`'ın izlediği
    // `bodyFetchProvider(_messageId)` ilk kez izlendiği anda (bu widget
    // kurulduğunda) Riverpod tarafından otomatik çalıştırılır (bkz.
    // `app/providers.dart`). Yalnızca okundu işaretinin zamanlayıcısı kalır.
    _scheduleMarkSeen();
    _prefetchNeighbors();
  }

  /// Son gösterilen gövdenin HTML'i. Önceki/sonraki iletiye geçerken yeni gövde
  /// bir-iki kare gecikirse WebView ağaçtan sökülüp yeniden yaratılmasın diye
  /// (pahalı) yükleme sürerken de canlı tutulur (bkz. `_BodyView.keepHtml`).
  String? _lastHtml;

  Timer? _prefetchTimer;

  /// Önceki/sonraki iletinin gövdesini ve satır akışlarını önceden ısıtır:
  /// kullanıcı okla geçtiğinde veri hazırdır, gövde yerelde beklenmeden gelir.
  /// Geçerli iletinin kendi indirmesi öne geçsin diye kısa bir gecikmeyle başlar;
  /// hatalar sessizce yutulur (bu yalnızca bir hızlandırıcıdır).
  void _prefetchNeighbors() {
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      final rows = ref.read(messageListProvider).value ?? const <MessageRow>[];
      final index = rows.indexWhere((m) => m.id == _messageId);
      if (index < 0) return;
      for (final neighbor in [index + 1, index - 1]) {
        if (neighbor < 0 || neighbor >= rows.length) continue;
        unawaited(_warm(rows[neighbor].id));
      }
    });
  }

  Future<void> _warm(int id) async {
    try {
      await ref.read(mailRepositoryProvider).ensureBody(id);
      if (!mounted) return;
      await Future.wait([
        ref.read(messageProvider(id).future),
        ref.read(messageBodyProvider(id).future),
        ref.read(attachmentsProvider(id).future),
      ]);
    } on Object catch (_) {
      // Ağ/veritabanı hatası: ileti açılınca normal yoldan yeniden denenir.
    }
  }

  @override
  void dispose() {
    _seenTimer?.cancel();
    _prefetchTimer?.cancel();
    _headerMeasureTimer?.cancel();
    _scrollY.dispose();
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
    setState(() {
      _messageId = rows[next].id;
      _scrollY.value = 0;
    });
    _scheduleMarkSeen();
    _prefetchNeighbors();
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
    // Tüm liste yerine yalnızca (konum, adet) izlenir: eşitleme/yeni ileti
    // listeyi her değiştirdiğinde okuma ekranı (ve WebView'ı içeren ağaç)
    // yeniden kurulmaz; ayrıca her karede O(n) arama yapılmaz.
    final (index, rowCount) = ref.watch(
      messageListProvider.select((async) {
        final list = async.value ?? const <MessageRow>[];
        return (list.indexWhere((m) => m.id == _messageId), list.length);
      }),
    );

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

    // Çeviri gösteriliyorsa konu ve gövde çevrilmiş halleriyle çizilir;
    // gövde WebView'ı aynı örnekte kalıp yalnızca içeriğini değiştirir.
    final translation = ref
        .watch(translationControllerProvider(_messageId))
        .translation;
    final originalSubject = message.subject.trim().isEmpty
        ? '(konu yok)'
        : message.subject;
    final subject = (translation?.subject.trim().isNotEmpty ?? false)
        ? translation!.subject
        : originalSubject;
    final shownBody = _withTranslation(body, translation);
    if (shownBody?.html case final html? when html.trim().isNotEmpty) {
      _lastHtml = html;
    }

    return _nativeScaffold(
      t: t,
      message: message,
      subject: subject,
      attachments: attachments,
      body: body,
      shownBody: shownBody,
      bodyFetch: bodyFetch,
      rowCount: rowCount,
      index: index,
    );
  }

  /// Yerel kaydırmalı düzen: sabit app bar + (en fazla ekranın %40'ı kadar)
  /// başlık + kalan alanı dolduran gövde. Gövde WebView'ı kendi içinde
  /// kaydırır; Flutter yalnızca başlığı (uzunsa kendi içinde kayan) yerleştirir.
  Widget _nativeScaffold({
    required KaydetTokens t,
    required MessageRow message,
    required String subject,
    required List<AttachmentRow> attachments,
    required MessageBodyRow? body,
    required MessageBodyRow? shownBody,
    required AsyncValue<MessageBodyRow?> bodyFetch,
    required int rowCount,
    required int index,
  }) {
    _measureHeader();
    return Scaffold(
      backgroundColor: t.readingBg,
      appBar: AppBar(
        leading: const _BackButton(),
        // Bu ekranda app bar daha alçaktır: gövdeye daha çok yer kalır.
        toolbarHeight: _compactAppBarHeight,
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.chevronUp, size: IconSize.md),
            tooltip: 'Önceki ileti',
            onPressed: index > 0 ? () => _navigate(-1) : null,
          ),
          IconButton(
            icon: const Icon(LucideIcons.chevronDown, size: IconSize.md),
            tooltip: 'Sonraki ileti',
            onPressed: index >= 0 && index < rowCount - 1
                ? () => _navigate(1)
                : null,
          ),
          const SizedBox(width: Space.xs),
        ],
      ),
      body: Stack(
        children: [
          // Gövde tüm alanı kaplar; başlığın altında kalmasın diye içerik
          // `topInset` kadar aşağıdan başlar.
          Positioned.fill(
            child: _BodyView(
              body: shownBody,
              fetchStatus: bodyFetch,
              topInset: _headerHeight,
              keepHtml: _lastHtml,
              // Başlık tamamen çıktıktan sonra değer değişmez: `ValueNotifier`
              // aynı değeri yeniden bildirmediği için kaydırırken yeniden çizim yok.
              onScrollY: (y) =>
                  _scrollY.value = y.clamp(0.0, _currentHeaderHeight()),
              scrollBridge: _bodyScroll,
              onRetry: () => ref.invalidate(bodyFetchProvider(_messageId)),
              onMailto: (address) =>
                  unawaited(openCompose(context, ref, initialTo: address)),
            ),
          ),
          // Başlık gövdenin üstünde durur ve kaydırmayla birebir yukarı kayar
          // (yalnızca bir dönüşüm; WebView yeniden boyutlanmaz).
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _FollowScroll(
              scrollY: _scrollY,
              maxOffset: _currentHeaderHeight,
              child: NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (_) {
                  _measureHeader();
                  return false;
                },
                child: SizeChangedLayoutNotifier(
                  child: GestureDetector(
                    // Başlığın üstünde başlayan dikey sürükleme gövdeyi
                    // kaydırır (WebView başlığın ARKASINDA kalır).
                    onVerticalDragUpdate: (details) =>
                        _bodyScroll.drag(-details.delta.dy),
                    child: ColoredBox(
                      key: _headerKey,
                      color: t.readingBg,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.sizeOf(context).height * 0.4,
                            ),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(
                                Space.lg,
                                Space.sm,
                                Space.lg,
                                0,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SelectableText(
                                    subject,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(
                                          fontSize: 16 * AppText.scale,
                                          height: 22 / 16,
                                        ),
                                  ),
                                  const SizedBox(height: Space.sm),
                                  _Header(
                                    message: message,
                                    onRecipientsExpanded: (v) =>
                                        _recipientsExpanded = v,
                                  ),
                                  const SizedBox(height: Space.md),
                                  if (attachments.isNotEmpty) ...[
                                    _AttachmentStrip(attachments: attachments),
                                    const SizedBox(height: Space.md),
                                  ],
                                  TranslateBar(
                                    messageId: _messageId,
                                    subject: message.subject,
                                    body: body,
                                    noticeBottomInset: _ActionBar.height,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Divider(color: t.divider, height: 1),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _ActionBar(message: message),
    );
  }
}

/// Çeviri gösteriliyorsa gövdenin içeriğini çevrilmiş haliyle değiştirir
/// (HTML iletide `html`, düz metin iletide `plainText`); değilse aynen döner.
MessageBodyRow? _withTranslation(
  MessageBodyRow? body,
  MailTranslation? translation,
) {
  if (body == null || translation == null) return body;
  final hasHtml = body.html?.trim().isNotEmpty ?? false;
  return hasHtml
      ? body.copyWith(html: Value(translation.content))
      : body.copyWith(plainText: Value(translation.content));
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

List<String> _decodeLabelNames(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is List) return decoded.whereType<String>().toList();
  } on FormatException {
    // Bozuk etiket verisi başlığı/menüyü engellemez.
  }
  return const [];
}

class _Header extends ConsumerWidget {
  const _Header({required this.message, this.onRecipientsExpanded});

  final MessageRow message;

  /// Alıcı ayrıntıları açılıp kapanınca bildirilir (bkz. `_RecipientsBlock`).
  final ValueChanged<bool>? onRecipientsExpanded;

  List<String> get _labelNames => _decodeLabelNames(message.labelsJson);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                LabelChip(
                  name: name,
                  toneIndex: 0,
                  onDeleted: () => ref
                      .read(mailRepositoryProvider)
                      .setLabel(
                        messageIds: [message.id],
                        labelName: name,
                        add: false,
                      ),
                ),
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
              size: 32,
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Ad + (sağda) kısa tarih tek satırda; e-posta altında.
                  // Eskiden ad, e-posta ve uzun tarih üç ayrı satırdı.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          message.fromName.isEmpty
                              ? message.fromEmail
                              : message.fromName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontVariations: AppText.semibold,
                              ),
                        ),
                      ),
                      if (message.isFlagged)
                        // Dokununca sabitleme kaldırılır; hedef küçük ikondan
                        // geniştir.
                        Tooltip(
                          message: 'Sabitlemeyi kaldır',
                          child: InkResponse(
                            radius: 18,
                            onTap: () => ref
                                .read(mailRepositoryProvider)
                                .setFlagged([message.id], false),
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: Space.sm,
                                top: Space.xs,
                                bottom: Space.xs,
                              ),
                              child: Icon(
                                LucideIcons.pin,
                                size: 14,
                                color: t.pinIcon,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(width: Space.sm),
                      Text(
                        formatListDate(
                          message.dateUtc,
                          locale: Localizations.localeOf(context).languageCode,
                        ),
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: t.textTertiary),
                      ),
                    ],
                  ),
                  Text(
                    message.fromEmail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: t.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (to.isNotEmpty || cc.isNotEmpty) ...[
          const SizedBox(height: Space.xs),
          _RecipientsBlock(
            to: to,
            cc: cc,
            accountId: message.accountId,
            onExpandedChanged: onRecipientsExpanded,
          ),
        ],
      ],
    );
  }
}

/// Alıcı ayrıntıları varsayılan olarak KAPALIDIR: tek satırlık özet ("Alıcı:
/// Ali, Veli ve 3 kişi daha ⌄"). Dokununca Kime/Bilgi bölümleri yumuşakça
/// açılır, tekrar dokununca kapanır — başlık, çok alıcılı iletilerde bile
/// içeriği aşağı itmez. Durum yalnızca bu ekranın ömrünce tutulur.
class _RecipientsBlock extends StatefulWidget {
  const _RecipientsBlock({
    required this.to,
    required this.cc,
    required this.accountId,
    this.onExpandedChanged,
  });

  final ValueChanged<bool>? onExpandedChanged;

  final List<EmailAddress> to;
  final List<EmailAddress> cc;
  final int? accountId;

  @override
  State<_RecipientsBlock> createState() => _RecipientsBlockState();
}

class _RecipientsBlockState extends State<_RecipientsBlock> {
  static const int _summaryNames = 2;

  bool _expanded = false;

  void _toggle() {
    setState(() => _expanded = !_expanded);
    widget.onExpandedChanged?.call(_expanded);
  }

  @override
  void dispose() {
    // Blok kalkarsa (ör. alıcısız iletiye geçiş) açık durumu sıfırlanır.
    widget.onExpandedChanged?.call(false);
    super.dispose();
  }

  /// "Ali, Veli ve 3 kişi daha" — Kime + Bilgi, tekrarsız.
  String get _summary {
    final seen = <String>{};
    final all = [
      for (final a in [...widget.to, ...widget.cc])
        if (seen.add(a.email.trim().toLowerCase())) a,
    ];
    final names = all.take(_summaryNames).map((a) => a.display).join(', ');
    final rest = all.length - _summaryNames;
    return rest > 0 ? '$names ve $rest kişi daha' : names;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _expanded,
          label: _expanded
              ? 'Alıcı ayrıntılarını gizle'
              : 'Alıcı ayrıntılarını göster',
          excludeSemantics: true,
          onTap: _toggle,
          child: InkWell(
            onTap: _toggle,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 28),
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: 'Alıcı: ',
                            style: TextStyle(color: t.textTertiary),
                          ),
                          TextSpan(text: _summary),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: t.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: context.motion(Motion.fast),
                    curve: Motion.standard,
                    child: Icon(
                      LucideIcons.chevronDown,
                      size: IconSize.sm,
                      color: t.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: context.motion(Motion.base),
          curve: Motion.standard,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: Space.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _RecipientLine(
                        label: 'Kime',
                        addresses: widget.to,
                        accountId: widget.accountId,
                      ),
                      if (widget.cc.isNotEmpty)
                        _RecipientLine(
                          label: 'Bilgi',
                          addresses: widget.cc,
                          accountId: widget.accountId,
                        ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

class _RecipientLine extends StatelessWidget {
  const _RecipientLine({
    required this.label,
    required this.addresses,
    required this.accountId,
  });

  final String label;
  final List<EmailAddress> addresses;
  final int? accountId;

  /// Başlıkta en fazla bu kadar alıcı satırı görünür; kalanı "+N kişi" ile
  /// alt sayfaya taşınır (başlık onlarca satır uzamasın).
  static const int maxVisible = 2;

  @override
  Widget build(BuildContext context) {
    final unique = _dedupe(addresses);
    if (unique.isEmpty) return const SizedBox.shrink();
    final t = context.tokens;
    final visible = unique.take(maxVisible).toList();
    final hidden = unique.length - visible.length;
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            // Etiket ilk alıcı satırıyla (avatar boyunda) dikey ortalanır.
            height: _RecipientInfoChip.rowHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: t.textTertiary),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final address in visible)
                  _RecipientInfoChip(address: address, accountId: accountId),
                if (hidden > 0)
                  InkWell(
                    onTap: () => _showAllRecipients(context, unique),
                    splashColor: t.textTertiary.withValues(alpha: 0.10),
                    highlightColor: t.textTertiary.withValues(alpha: 0.06),
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: _RecipientInfoChip.avatarSize + Space.sm,
                        top: Space.xs,
                        bottom: Space.xs,
                      ),
                      child: Row(
                        children: [
                          Text(
                            '+$hidden kişi',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: t.accent,
                                  fontWeight: FontWeight.w600,
                                  fontVariations: AppText.semibold,
                                ),
                          ),
                          const Spacer(),
                          Icon(
                            LucideIcons.chevronRight,
                            size: IconSize.sm,
                            color: t.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Aynı adresi (büyük/küçük harf farkı yok sayılarak) yalnızca bir kez tutar;
  /// ad taşıyan kayıt, adsız olanın yerine geçer.
  static List<EmailAddress> _dedupe(List<EmailAddress> list) {
    final byEmail = <String, EmailAddress>{};
    for (final a in list) {
      final key = a.email.trim().toLowerCase();
      if (key.isEmpty) continue;
      final existing = byEmail[key];
      if (existing == null ||
          ((existing.name?.trim().isEmpty ?? true) &&
              (a.name?.trim().isNotEmpty ?? false))) {
        byEmail[key] = a;
      }
    }
    return byEmail.values.toList();
  }

  void _showAllRecipients(BuildContext context, List<EmailAddress> all) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      sheetAnimationStyle: AnimationStyle(
        duration: context.motion(Motion.base),
        reverseDuration: context.motion(Motion.fast),
        curve: Motion.standard,
      ),
      builder: (sheetContext) {
        final t = sheetContext.tokens;
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.75,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    Space.sm,
                    Space.xs,
                    Space.xs,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          label == 'Bilgi' ? 'Bilgi alıcıları' : 'Alıcılar',
                          style: AppText.titleLarge.copyWith(
                            color: t.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(LucideIcons.x),
                        tooltip: 'Kapat',
                        onPressed: () => Navigator.of(sheetContext).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(
                      Space.lg,
                      0,
                      Space.lg,
                      Space.lg,
                    ),
                    children: [
                      for (final address in all)
                        _RecipientInfoChip(
                          address: address,
                          accountId: accountId,
                          minHeight: 60,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Salt-okunur, kutusuz kompakt alıcı satırı: küçük avatar + ad (varsa) /
/// e-posta + minimal ok. Dokunulunca [showRecipientDetails] ile aynı ayrıntı
/// sayfasını açar (yazma ekranındaki alıcı çipiyle tutarlı davranış), ama
/// kaldırma düğmesi taşımaz — burada alıcı listesi düzenlenmez. Arka plan,
/// kenarlık ya da gölge yok; yalnızca basılı durumda çok hafif bir iz.
class _RecipientInfoChip extends StatelessWidget {
  const _RecipientInfoChip({
    required this.address,
    required this.accountId,
    this.minHeight,
  });

  /// Satır en az bu kadar yüksek olur; alt sayfadaki uzun listelerde satırların
  /// birbirine yapışmaması için [rowHeight]tan büyük verilir.
  final double? minHeight;

  final EmailAddress address;
  final int? accountId;

  static const double avatarSize = 28;

  /// Tek alıcı satırının yüksekliği (etiketin hizalanması için de kullanılır).
  static const double rowHeight = 40;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final name = address.name?.trim() ?? '';
    final hasName = name.isNotEmpty;

    return InkWell(
      onTap: () =>
          showRecipientDetails(context, address: address, accountId: accountId),
      splashColor: t.textTertiary.withValues(alpha: 0.10),
      highlightColor: t.textTertiary.withValues(alpha: 0.06),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight ?? rowHeight),
        child: Row(
          children: [
            BrandAvatar(
              name: hasName ? name : address.email,
              email: address.email,
              size: avatarSize,
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasName)
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(
                        color: t.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontVariations: AppText.semibold,
                      ),
                    ),
                  Text(
                    address.email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        (hasName ? textTheme.bodySmall : textTheme.bodyMedium)
                            ?.copyWith(color: t.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.xs),
            Icon(
              LucideIcons.chevronRight,
              size: IconSize.sm,
              color: t.textTertiary,
            ),
          ],
        ),
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
                _AttachmentChip(attachments: visible, index: index),
          ),
        ),
      ],
    );
  }
}

class _AttachmentChip extends ConsumerStatefulWidget {
  const _AttachmentChip({required this.attachments, required this.index});

  final List<AttachmentRow> attachments;
  final int index;

  AttachmentRow get attachment => attachments[index];

  @override
  ConsumerState<_AttachmentChip> createState() => _AttachmentChipState();
}

class _AttachmentChipState extends ConsumerState<_AttachmentChip> {
  /// Ekin varsayılan davranışı artık İNDİR değil ÖNİZLE: dokunma doğrudan
  /// `AttachmentPreviewScreen`i açar; ekran kendi içinde önbellek/indirme
  /// durumunu ele alır (bkz. o ekranın belgesi). Ekran, dokunulan ekten
  /// başlayarak şerideki TÜM eklerin sırayla kaydırılabildiği bir galeridir.
  void _openPreview() {
    context.pushScreen(
      AttachmentPreviewScreen(
        attachments: widget.attachments,
        initialIndex: widget.index,
      ),
      transitionStyle: KaydetTransitionStyle.horizontalPush,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final kind = AttachmentType.resolve(
      mimeType: widget.attachment.mimeType,
      fileName: widget.attachment.fileName,
    );
    return InkWell(
      onTap: _openPreview,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280, minHeight: 44),
        padding: const EdgeInsetsDirectional.only(
          start: Space.md,
          top: Space.sm,
          bottom: Space.sm,
          end: Space.xs,
        ),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: t.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AttachmentTypeIcon(
              kind: kind,
              fileName: widget.attachment.fileName,
              mimeType: widget.attachment.mimeType,
              size: IconSize.lg,
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
                    '${AttachmentType.label(widget.attachment.fileName)} · '
                    '${formatBytes(widget.attachment.sizeBytes)}',
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                  ),
                ],
              ),
            ),
            _AttachmentOverflowButton(
              attachment: widget.attachment,
              kind: kind,
            ),
          ],
        ),
      ),
    );
  }
}

/// Ek şeridindeki "⋮" düğmesi — bkz. bellek: kısa seçim listeleri anchored
/// bir popup'ta ([MenuAnchor]), tam ekran bir alttan panelde değil.
///
/// Menü öğeleri yerel dosya yolunu gerektirir (bkz. `attachmentMenuItems`);
/// ek henüz önbellekte değilse ilk dokunuşta önce indirilir (düğmede kısa bir
/// dönen gösterge), menü ancak dosya hazır olduktan SONRA açılır — kullanıcı
/// "Paylaş" gibi bir eylemi seçtiğinde arkada eksik/yanlış bir dosya olmaz.
class _AttachmentOverflowButton extends ConsumerStatefulWidget {
  const _AttachmentOverflowButton({
    required this.attachment,
    required this.kind,
  });

  final AttachmentRow attachment;
  final AttachmentKind kind;

  @override
  ConsumerState<_AttachmentOverflowButton> createState() =>
      _AttachmentOverflowButtonState();
}

class _AttachmentOverflowButtonState
    extends ConsumerState<_AttachmentOverflowButton> {
  final MenuController _menu = MenuController();
  bool _busy = false;
  String? _resolvedPath;

  Future<void> _openMenu() async {
    if (_busy) return;
    var path = _resolvedPath;
    if (path == null) {
      final existing = widget.attachment.localPath;
      if (existing != null && File(existing).existsSync()) {
        path = existing;
      } else {
        setState(() => _busy = true);
        final result = await ref
            .read(mailRepositoryProvider)
            .downloadAttachment(widget.attachment.id);
        if (!mounted) return;
        setState(() => _busy = false);
        path = result.valueOrNull;
        if (path == null) {
          final failure = result.failureOrNull;
          final overlay = Overlay.of(context, rootOverlay: true);
          if (overlay.mounted) {
            KaydetNotice.show(
              overlay,
              message: failure?.userMessage ?? 'Dosya açılamadı.',
            );
          }
          return;
        }
      }
      if (!mounted) return;
      setState(() => _resolvedPath = path);
    }
    // `menuChildren` az önceki `setState` ile güncellenir; açılış BİR KARE
    // sonraya bırakılır ki menü, dosya yolu artık bilinen doğru öğe
    // listesiyle açılsın (aksi hâlde bu karenin eski ağacı kullanılırdı).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menu.open();
    });
  }

  @override
  Widget build(BuildContext context) {
    final path = _resolvedPath;
    return MenuAnchor(
      controller: _menu,
      animated: true,
      menuChildren: path == null
          ? const []
          : attachmentMenuItems(
              context,
              ref,
              attachment: widget.attachment,
              localPath: path,
              kind: widget.kind,
            ),
      builder: (context, controller, child) => IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        visualDensity: VisualDensity.compact,
        icon: _busy
            ? SizedBox(
                width: IconSize.sm,
                height: IconSize.sm,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.tokens.accent,
                ),
              )
            : const Icon(LucideIcons.ellipsisVertical, size: IconSize.sm),
        onPressed: _openMenu,
      ),
    );
  }
}

/// [child]'ı kaydırma konumu kadar yukarı öteler (en fazla [maxOffset]); tam
/// kaybolunca dokunuşları da geçirir. Yalnızca `Transform` yeniden çizilir.
class _FollowScroll extends StatelessWidget {
  const _FollowScroll({
    required this.scrollY,
    required this.maxOffset,
    required this.child,
  });

  final ValueListenable<double> scrollY;
  final double Function() maxOffset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Dış sınır: dönüşüm değişince yalnızca bu katman güncellenir (ekranın
    // geri kalanı yeniden çizilmez). İç sınır: başlığın içeriği bir kez
    // çizilip önbelleğe alınır, kaydırırken yalnızca konumu değişir.
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: scrollY,
        child: RepaintBoundary(child: child),
        builder: (context, y, child) {
          final max = maxOffset();
          final dy = y.clamp(0.0, max).toDouble();
          return IgnorePointer(
            ignoring: max > 0 && dy >= max - 1,
            child: Transform.translate(offset: Offset(0, -dy), child: child),
          );
        },
      ),
    );
  }
}

/// Başlık (Flutter) ile gövde WebView'ı arasındaki küçük köprü: başlığın
/// üstünde başlayan sürükleme gövdeyi kaydırsın diye. WebView durumu kayıt
/// olur; `drag` kesirli birikimi tam piksele çevirip iletir.
class _BodyScrollBridge {
  Future<void> Function(int dy)? scrollBy;
  double _remainder = 0;

  void drag(double dy) {
    final handler = scrollBy;
    if (handler == null) return;
    _remainder += dy;
    final whole = _remainder.truncate();
    if (whole == 0) return;
    _remainder -= whole;
    unawaited(handler(whole));
  }
}

class _BodyView extends StatelessWidget {
  const _BodyView({
    required this.body,
    required this.fetchStatus,
    required this.onRetry,
    required this.onMailto,
    this.topInset = 0,
    this.keepHtml,
    this.onScrollY,
    this.scrollBridge,
  });

  /// Yeni gövde henüz gelmediği kısa aralıkta WebView'ı ağaçtan sökmemek için
  /// son gösterilen HTML (bkz. `_MailDetailScreenState._lastHtml`). WebView
  /// yaratımı pahalıdır; bu aralıkta üstünde iskelet gösterilir.
  final String? keepHtml;

  /// Gövdenin üstünde (başlığın altında kalmasın diye) boş bırakılacak
  /// yükseklik, kaydırma konumu bildirimi ve başlıktan sürükleme köprüsü.
  final double topInset;
  final ValueChanged<double>? onScrollY;
  final _BodyScrollBridge? scrollBridge;

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

  /// İletideki bir `mailto:` bağlantısına dokunulunca çağrılır (alıcı adresi).
  final ValueChanged<String> onMailto;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (body == null && fetchStatus.hasError) {
      final error = fetchStatus.error;
      return _scrolls(
        _padded(
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
        ),
      );
    }

    if (body == null && !fetchStatus.hasValue) {
      final keep = keepHtml;
      if (keep != null) {
        return _HtmlWebView(
          html: keep,
          loading: true,
          onMailto: onMailto,
          topInset: topInset,
          onScrollY: onScrollY,
          bridge: scrollBridge,
        );
      }
      // Ekranı bloklayan tekil bir döner gösterge YERİNE: başlık/gönderen/
      // ekler zaten `message` satırından (yerelde, anında) geldiği için
      // yalnızca gövdenin oturacağı alanda hafif bir shimmer gösterilir —
      // Outlook'un okuma bölmesindeki gibi. `bodyFetchProvider` indirme
      // bitse BİLE `messageBodyProvider`nin akışı yeni satırı gerçekten
      // yayana kadar `loading` kalır (bkz. provider belgesi), bu yüzden
      // `hasValue` ikisi de tamamlanana kadar `false` kalır — indirme
      // bitişi ile veri ekranda görünür oluşu arasında "içerik yok"
      // mesajının bir kare yanıp sönmesi yapısal olarak mümkün değildir.
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: const _BodyShimmer(),
      );
    }

    final html = body?.html;
    final plain = body?.plainText;

    if (html != null && html.trim().isNotEmpty) {
      // WebView alanı doldurur ve kendi içinde kaydırır (bkz. `_HtmlWebView`).
      return _HtmlWebView(
        html: html,
        onMailto: onMailto,
        topInset: topInset,
        onScrollY: onScrollY,
        bridge: scrollBridge,
      );
    }

    if (plain != null && plain.trim().isNotEmpty) {
      // Düz metin de WebView'dan geçer: pinch-zoom, yerel kaydırma ve
      // seçim HTML iletilerle birebir aynı olsun.
      return _HtmlWebView(
        html: _plainTextToHtml(plain),
        onMailto: onMailto,
        topInset: topInset,
        onScrollY: onScrollY,
        bridge: scrollBridge,
      );
    }

    return _scrolls(
      _padded(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xxl),
          child: Text(
            'Bu iletinin metin içeriği yok.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: t.textTertiary),
          ),
        ),
      ),
    );
  }

  /// WebView dışındaki içerik (düz metin, hata, boş durum) kendi kaydırma
  /// alanına sarılır; başlığın altından başlar ve konumunu bildirir.
  Widget _scrolls(Widget child) => NotificationListener<ScrollNotification>(
    onNotification: (n) {
      if (n.depth == 0) onScrollY?.call(n.metrics.pixels);
      return false;
    },
    child: SingleChildScrollView(
      padding: EdgeInsets.only(top: topInset),
      child: child,
    ),
  );

  Widget _padded(Widget child) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xxl),
    child: child,
  );
}

/// Düz metin gövdeyi WebView'ın göstereceği HTML'e çevirir: kaçışlar,
/// satır sonları ve uzun satırlar korunur; http(s) adresleri bağlantı olur.
String _plainTextToHtml(String plain) {
  final escaped = const HtmlEscape(HtmlEscapeMode.element).convert(plain);
  final linked = escaped.replaceAllMapped(
    RegExp(r'https?://[^\s<>"]+', caseSensitive: false),
    (m) => '<a href="${m[0]}">${m[0]}</a>',
  );
  return '<div style="white-space:pre-wrap;overflow-wrap:anywhere;">'
      '$linked</div>';
}

/// Gövde metninin geleceği alanda hayalet ekran (shimmer) efekti.
///
/// Değişen genişlikte "satırlar" üzerinde soldan sağa kayan bir parlaklık
/// bandı (bkz. `ShimmerSurface`) — gerçek metin satırlarının taslağı gibi
/// durur. Satır sayısı sabit değil: kullanılabilir yüksekliğe göre hesaplanır,
/// böylece iskelet ekran boyutundan bağımsız olarak alanı doldurur.
class _BodyShimmer extends StatelessWidget {
  const _BodyShimmer();

  // Gerçek bir paragrafın satır sonlarını taklit eden değişen genişlikler;
  // her tur bir paragraftır ve altında ekstra boşluk bırakılır.
  static const _lineWidthFactors = [1.0, 0.94, 0.6, 1.0, 0.86, 0.42];
  static const double _barHeight = 14;
  static const EdgeInsets _padding = EdgeInsets.fromLTRB(
    Space.lg,
    Space.md,
    Space.lg,
    Space.xxl,
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;
        final available = height - _padding.vertical;

        // Sığdığı kadar satır; her satır `_barHeight + Space.sm`, paragraf
        // sonunda ek `Space.lg` boşluk.
        final rows = <(double, double)>[]; // (genişlik oranı, alt boşluk)
        var used = 0.0;
        for (var i = 0; ; i++) {
          final factor = _lineWidthFactors[i % _lineWidthFactors.length];
          final endOfParagraph =
              i % _lineWidthFactors.length == _lineWidthFactors.length - 1;
          final gap = endOfParagraph ? Space.lg : Space.sm;
          if (used + _barHeight > available || rows.length >= 80) break;
          rows.add((factor, gap));
          used += _barHeight + gap;
        }

        return Padding(
          padding: _padding,
          child: ShimmerSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (factor, gap) in rows)
                  Padding(
                    padding: EdgeInsets.only(bottom: gap),
                    child: ShimmerBar(widthFactor: factor, height: _barHeight),
                  ),
              ],
            ),
          ),
        );
      },
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
/// YEREL KAYDIRMA: WebView, verilen alanı doldurur ve kendi içinde (yerel
/// olarak) kaydırır; içeriğin boyuna uzatılmaz, kaydırma sırasında yeniden
/// boyutlanmaz. Parmak → yerel WebView → yerel bileşik katman akışı Flutter'a
/// hiç uğramaz. Flutter'a yalnızca (1) ilk "içerik hazır" bildirimi (yükleme
/// iskeletini kaldırmak için) ve (2) başlığın kaydırmayla birlikte yukarı
/// gitmesi için kaydırma konumu gider (yalnızca başlığın dönüşümünü yeniler,
/// `setState` yok). Yakınlaştırma da yereldir (pinch).
///
/// Android'de WebView varsayılan, doku (texture) tabanlı kipte çalışır: görünen
/// alan boyunda olduğu için dokuya her zaman sığar ve Hybrid Composition'ın
/// (kare düşüren) maliyeti yoktur.
class _HtmlWebView extends StatefulWidget {
  const _HtmlWebView({
    required this.html,
    required this.onMailto,
    this.loading = false,
    this.topInset = 0,
    this.onScrollY,
    this.bridge,
  });

  final String html;

  /// Yeni içerik bekleniyor: WebView canlı kalır ama üstünde iskelet durur.
  final bool loading;

  /// Belgenin üstünde bırakılacak boşluk (CSS `--kd-top`; başlığın altında
  /// kalmasın diye), kaydırma konumu bildirimi ve sürükleme köprüsü.
  final double topInset;
  final ValueChanged<double>? onScrollY;
  final _BodyScrollBridge? bridge;

  /// `mailto:` bağlantısına dokunulunca alıcı adres(ler)i ile çağrılır.
  final ValueChanged<String> onMailto;

  @override
  State<_HtmlWebView> createState() => _HtmlWebViewState();
}

class _HtmlWebViewState extends State<_HtmlWebView> {
  /// WebView tüm dokunuşları (kaydırma, pinch, uzun basma) kendisi alır.
  static final Set<Factory<OneSequenceGestureRecognizer>> _gestures = {
    Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
  };

  /// Regex temizliğinden geçmiş gövdeler: `(ham html, koyu tema)` → `(temiz
  /// html, e-posta koyu tema destekliyor mu)`. LRU (son kullanılan sona).
  static final Map<(String, bool), (String, bool)> _preparedCache = {};
  // Mevcut + önceki + sonraki ileti (× açık/koyu tema) yeter; büyük bültenlerde
  // her giriş ham ve temiz HTML'i birlikte tuttuğundan daha fazlası RAM'i şişirir.
  static const int _preparedCacheSize = 4;

  late final MailWebViewHandle _handle;
  WebViewController get _controller => _handle.controller;
  late final Widget _webView;

  // `_load()` art arda (ör. ilk `didChangeDependencies` hemen ardından
  // `didUpdateWidget`) tetiklenirse, önce başlayan ama geç biten bir isolate
  // çağrısı sonucu yeni içeriğin üzerine yazmasın diye her çağrının kendi
  // sırası tutulur. Belgeye de kimlik olarak yazılır: yerine yenisi yüklenmiş
  // eski belgeden geç gelen "hazır" bildirimi bununla ayıklanır.
  int _loadToken = 0;

  // Belgenin en son hangi temayla kurulduğu. Tema `initState`te okunamayan bir
  // InheritedWidget'tır; bu yüzden ilk yükleme `didChangeDependencies`te yapılır.
  KaydetTokens? _tokens;
  Timer? _themeReload;
  Timer? _readyFallback;

  // İlk yüklemenin, ekranın giriş geçişi bitene kadar ertelenmesi için (bkz.
  // `_scheduleInitialLoad`) — geçiş erken kapanırsa (ör. geri dönüldüyse)
  // dinleyici sızmasın diye `dispose()`ta temizlenir.
  Animation<double>? _entranceAnimation;
  void Function(AnimationStatus)? _entranceListener;

  /// Android kaydırma konumunu mantıksal piksele çevirmek için.
  double _pixelRatio = 1;

  /// İçerik yerleşti mi: `false` iken WebView'ın üstünde yükleme iskeleti durur.
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _createWebView();
    _registerBridge();
  }

  void _registerBridge() {
    widget.bridge?.scrollBy = (dy) => _controller.scrollBy(0, dy);
  }

  /// Belgenin üst boşluğunu (başlık boyu) CSS değişkenine yazar.
  void _applyTopInset() {
    unawaited(
      _controller.runJavaScript(
        "document.documentElement.style.setProperty('--kd-top', "
        "'${widget.topInset.toStringAsFixed(1)}px');",
      ),
    );
  }

  void _createWebView() {
    // Denetleyici havuzdan (önceden kurulmuş, ısıtılmış) devralınır; kurulumu
    // ve yapılandırması `WebViewPool`da (JS kipi, kanallar, viewport ayarı).
    _handle = WebViewPool.acquire()
      ..attach(
        onLayout: _onLayoutMessage,
        onPageFinished: _onPageFinished,
        onNavigationRequest: _onNavigationRequest,
      );
    // Yerel kaydırma konumu: Flutter başlığı bununla birebir kayar.
    unawaited(_controller.setOnScrollPositionChange(_onScrollPosition));
    _webView = WebViewWidget(
      controller: _controller,
      gestureRecognizers: _gestures,
    );
  }

  /// Android kaydırma konumunu fiziksel pikselle bildirir; mantıksal piksele
  /// çevrilir.
  void _onScrollPosition(ScrollPositionChange change) {
    final scale = _controller.platform is AndroidWebViewController
        ? _pixelRatio
        : 1.0;
    widget.onScrollY?.call(change.y / scale);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pixelRatio = MediaQuery.devicePixelRatioOf(context);
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
    _readyFallback?.cancel();
    _cancelEntranceListener();
    _handle.detach();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _HtmlWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _registerBridge();
    if (oldWidget.topInset != widget.topInset) _applyTopInset();
    if (oldWidget.html != widget.html) {
      // Yeni içerik: yeni belge yerleşene kadar iskelet. WebView AYNI kalır
      // (yalnızca içerik yüklenir) — önceki/sonraki iletiye geçiş akıcıdır.
      _ready = false;
      widget.onScrollY?.call(0);
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

    final cacheKey = (html, dark);
    final cached = _preparedCache.remove(cacheKey);
    final (body, emailSupportsDark) =
        cached ??
        await Isolate.run(() {
          // Kaynağın kendi viewport etiketi kaldırılır ki `MailHtmlDocument`in
          // yazdığı etiket çakışmasız, belgedeki TEK viewport etiketi olsun (bkz.
          // `stripViewportMeta` dokümantasyonu — aksi hâlde bülten e-postalarında
          // sessizce ezilip düzeltme hiç uygulanmamış görünüyordu).
          final noConflictingViewport =
              TextExtraction.stripMetaRefresh(
                TextExtraction.stripViewportMeta(html),
              ).replaceAllMapped(
                // Görsel çözme (decode) ana iş parçacığını tutmasın: `decoding=async`.
                RegExp(r'<img\b(?![^>]*\bdecoding\s*=)', caseSensitive: false),
                (m) => '<img decoding="async"',
              );
          return (
            TextExtraction.resolveColorSchemeQueries(
              noConflictingViewport,
              dark: dark,
            ),
            TextExtraction.supportsDarkScheme(noConflictingViewport),
          );
        });
    // Son kullanılan başa yazılır (LRU): aynı iletiye önceki/sonraki ile geri
    // dönüldüğünde regex temizliği ve isolate açılışı yeniden yapılmaz.
    _preparedCache[cacheKey] = (body, emailSupportsDark);
    while (_preparedCache.length > _preparedCacheSize) {
      _preparedCache.remove(_preparedCache.keys.first);
    }
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

  /// Render betiğinin "içerik yerleşti" bildirimi: `{doc, h, w}`. WebView
  /// yerel kaydırdığı için boyun kendisi kullanılmaz; yalnızca yükleme
  /// iskeletini kaldırmak için ilk bildirim beklenir.
  void _onLayoutMessage(JavaScriptMessage message) {
    final Object? data;
    try {
      data = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    if (data case {'doc': final int doc} when doc == _loadToken) {
      _markReady();
    }
  }

  void _markReady() {
    _readyFallback?.cancel();
    if (!_ready && mounted) {
      setState(() => _ready = true);
    }
  }

  /// Emniyet ağı: render betiği bildirim yapamazsa (beklenmez) iskelet sonsuza
  /// dek kalmasın — sayfa yüklendikten kısa süre sonra hazır sayılır.
  void _onPageFinished(String url) {
    _applyTopInset();
    if (_ready) return;
    _readyFallback?.cancel();
    _readyFallback = Timer(const Duration(seconds: 1), _markReady);
  }

  /// Bağlantı tıklamaları WebView içinde takip edilmez — aksi hâlde kullanıcı
  /// gönderenin sayfasına "uygulama içinde", hiçbir sandbox olmadan gitmiş olur:
  ///
  /// - `http(s)`: sistem tarayıcısında açılır.
  /// - `mailto:`: uygulamanın kendi yazma ekranı ([_HtmlWebView.onMailto]).
  /// - `tel:` / `sms:`: sistemin ilgili uygulaması.
  /// - `about:`: belgenin kendisi (`loadHtmlString`) ve sayfa içi bağlantılar
  ///   (`#bolum`) — WebView içinde kalır.
  /// - Diğer her şey (`data:`, `intent:`, `file:`, `content:`, `javascript:`…)
  ///   engellenir. Özellikle `data:` içinde kalmamalı: uygulamanın kendi
  ///   yüklemesi `data:` kullanmaz, ama dokunulan bir `data:text/html` bağlantısı
  ///   WebView'a tarayıcı kaynaklı bir gezinme olarak yüklenir ve gönderenin
  ///   betiği CSP'siz çalışırdı. Eskiden bilinmeyen şemalar WebView içinde
  ///   açılıyor, `mailto:`/`tel:` bağlantıları ileti gövdesini bir hata
  ///   sayfasıyla değiştiriyordu.
  ///
  /// `<iframe>` yüklemeleri buraya hiç ulaşmaz: belgedeki CSP (`frame-src
  /// 'none'`, bkz. `MailHtmlDocument`) onları daha önce engeller. Bu yüzden
  /// `request.isMainFrame` süzgeci KULLANILMAZ — iOS'ta `target="_blank"`
  /// bağlantıları hedef çerçevesiz geldiği için `false` olur ve dokunulan
  /// bağlantı sessizce yutulurdu.
  FutureOr<NavigationDecision> _onNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;

    switch (uri.scheme.toLowerCase()) {
      case 'about':
      case 'applewebdata':
        return NavigationDecision.navigate;
      case 'http':
      case 'https':
      case 'tel':
      case 'sms':
        unawaited(_launchExternally(uri));
        return NavigationDecision.prevent;
      case 'mailto':
        final address = _mailtoRecipients(uri);
        if (address.isNotEmpty) {
          widget.onMailto(address);
        } else {
          unawaited(_launchExternally(uri));
        }
        return NavigationDecision.prevent;
      default:
        return NavigationDecision.prevent;
    }
  }

  /// `mailto:a@x.com,b@y.com?subject=…` → `a@x.com,b@y.com` (alıcı listesi).
  static String _mailtoRecipients(Uri uri) {
    try {
      return Uri.decodeComponent(uri.path).trim();
    } on Object catch (_) {
      // Bozuk yüzde kodlaması: adres okunamadı, çağıran harici uygulamaya düşer.
      return '';
    }
  }

  Future<void> _launchExternally(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object catch (_) {
      // Bu bağlantıyı açacak bir uygulama yok; sessizce yok sayılır.
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Stack(
      fit: StackFit.expand,
      children: [
        _webView,
        // İçerik yerleşene kadar gövde iskeleti WebView'ın üstünde durur
        // (anında belirir); hazır olunca yumuşakça söner ve ağaçtan çıkar —
        // shimmer animasyonu görünmezken boşuna dönmez. İskelet başlığın
        // altından başlar.
        AnimatedSwitcher(
          duration: Motion.instant,
          reverseDuration: Motion.base,
          layoutBuilder: (current, previous) =>
              Stack(fit: StackFit.expand, children: [...previous, ?current]),
          child: _ready && !widget.loading
              ? const SizedBox.shrink()
              : ColoredBox(
                  color: t.readingBg,
                  child: ClipRect(
                    child: Padding(
                      padding: EdgeInsets.only(top: widget.topInset),
                      child: const _BodyShimmer(),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Alt eylem çubuğu — Outlook mobil gibi eşit aralıklı, aynı görünümde ikon
/// düğmeler: Yanıtla / Tümünü yanıtla / İlet / Arşivle / Sil / Diğer. Hiçbiri
/// öne çıkarılmaz. "Tümünü yanıtla" yalnızca iletide birden çok katılımcı
/// varsa görünür (bkz. `MessageRowReplyX.hasMultipleRecipients`); altı düğme
/// 48dp'lik dokunma alanıyla dar ekrana da (320dp) sığar.
class _ActionBar extends ConsumerWidget {
  const _ActionBar({required this.message});

  final MessageRow message;

  /// Çubuğun alt güvenli alanın üstünde kapladığı yükseklik. "Taslağa
  /// kaydedildi" bildirimi bunun üstüne yerleşir (bkz. `KaydetNotice`).
  static const double height = 64;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final selfEmail = ref.watch(accountByIdProvider(message.accountId))?.email;
    final showReplyAll = message.hasMultipleRecipients(selfEmail);

    Future<void> startCompose(ComposeMode mode) => openCompose(
      context,
      ref,
      replyToId: message.id,
      mode: mode,
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
              if (showReplyAll)
                IconButton(
                  icon: const Icon(LucideIcons.replyAll),
                  tooltip: 'Tümünü yanıtla',
                  onPressed: () => startCompose(ComposeMode.replyAll),
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
                  await archiveMessages(context, ref, [message.id]);
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

/// "Göndericiyi engelle": adres engellenir, iletileri sunucuda İstenmeyen'e taşınır ve ekran
/// kapanır; "Geri al" engeli yeniden kaldırır (iletiler Gelen Kutusu'na döner).
Future<void> _blockSender(
  BuildContext context,
  WidgetRef ref,
  MessageRow message,
) async {
  final overlay = Overlay.of(context);
  final navigator = Navigator.of(context);
  final repository = ref.read(blockedSenderRepositoryProvider);
  final result = await repository.block(
    accountId: message.accountId,
    email: message.fromEmail,
    name: message.fromName,
  );
  switch (result.outcome) {
    case BlockOutcome.blocked:
      if (navigator.mounted) navigator.pop();
      final id = result.row?.id;
      KaydetNotice.show(
        overlay,
        message: '${message.fromEmail} engellendi.',
        actionLabel: id == null ? null : 'Geri al',
        onAction: id == null ? null : () => unawaited(repository.unblock(id)),
        duration: const Duration(seconds: 6),
      );
    case BlockOutcome.alreadyBlocked:
      KaydetNotice.show(
        overlay,
        message: '${message.fromEmail} zaten engelli.',
      );
    case BlockOutcome.ownAddress:
      KaydetNotice.show(
        overlay,
        message: 'Kendi adresinizi engelleyemezsiniz.',
      );
    case BlockOutcome.invalidAddress:
      KaydetNotice.show(overlay, message: 'Geçerli bir e-posta adresi girin.');
  }
}

/// "Göndericinin engelini kaldır": adres listeden çıkar, iletileri Gelen Kutusu'na döner.
Future<void> _unblockSender(
  BuildContext context,
  WidgetRef ref,
  BlockedSenderRow sender,
) async {
  final overlay = Overlay.of(context);
  await ref.read(blockedSenderRepositoryProvider).unblock(sender.id);
  KaydetNotice.show(overlay, message: '${sender.email} için engel kaldırıldı.');
}

/// Okuma ekranının "..." menüsü — alt eylem çubuğunun sağ ucunda yaşıyor
/// (bkz. `_ActionBar`), eskiden üst `AppBar`'daydı: üst kısmın sade kalması
/// için taşındı. "Etiketle"/"Klasöre taşı" ayrı bir alttan panel
/// açmıyor, aynı popup içinde kendi alt menüsüne (bkz. `SubmenuButton`)
/// cascade oluyor (bkz. bellek: popup'lar modallara tercih edilir).
class _MoreMenu extends ConsumerWidget {
  const _MoreMenu({required this.message});

  final MessageRow message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.read(mailRepositoryProvider);
    final inJunk =
        (ref.watch(mailboxesForAccountProvider(message.accountId)).value ??
                const <MailboxRow>[])
            .any(
              (m) =>
                  m.id == message.mailboxId && m.specialUse == SpecialUse.junk,
            );
    final fromKey = message.fromEmail.trim().toLowerCase();
    final blockedRow =
        (ref.watch(blockedSendersOfAccountProvider(message.accountId)).value ??
                const <BlockedSenderRow>[])
            .where((b) => b.email == fromKey)
            .firstOrNull;

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
          menuChildren: labelMenuItems(
            context,
            ref,
            (label) async {
              await repository.setLabel(
                messageIds: [message.id],
                labelName: label,
                add: true,
              );
            },
            accountId: message.accountId,
            applied: _decodeLabelNames(message.labelsJson).toSet(),
            onRemoved: (label) async {
              await repository.setLabel(
                messageIds: [message.id],
                labelName: label,
                add: false,
              );
            },
          ),
          child: const Text('Etiketle'),
        ),
        SubmenuButton(
          animated: true,
          leadingIcon: const Icon(LucideIcons.folderInput, size: IconSize.sm),
          menuChildren: folderMenuItems(
            ref,
            (target) async {
              await repository.moveToFolder(
                messageIds: [message.id],
                targetMailboxId: target.id,
              );
              if (context.mounted) Navigator.of(context).pop();
            },
            accountId: message.accountId,
            excludeMailboxId: message.mailboxId,
          ),
          child: const Text('Klasöre taşı'),
        ),
        const Divider(height: 1),
        if (!inJunk)
          MenuItemButton(
            leadingIcon: const Icon(
              LucideIcons.octagonAlert,
              size: IconSize.sm,
            ),
            onPressed: () async {
              await repository.markSpam([message.id]);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('İstenmeyen olarak bildir'),
          ),
        if (message.fromEmail.isNotEmpty && !message.isLocalOnly)
          if (blockedRow != null)
            MenuItemButton(
              leadingIcon: const Icon(
                LucideIcons.circleCheck,
                size: IconSize.sm,
              ),
              onPressed: () => _unblockSender(context, ref, blockedRow),
              child: const Text('Göndericinin engelini kaldır'),
            )
          else
            MenuItemButton(
              leadingIcon: const Icon(LucideIcons.ban, size: IconSize.sm),
              onPressed: () => _blockSender(context, ref, message),
              child: const Text('Göndericiyi engelle'),
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

extension MessageRowReplyX on MessageRow {
  /// Bu iletide 1'den fazla katılan/alıcı var mı?
  ///
  /// Outlook tarzı: Tek kişili bir iletiyse (gönderici + tek alıcı) "Tümünü yanıtla"
  /// seçeneği görünmez.
  bool hasMultipleRecipients(String? selfEmail) {
    final to = EmailAddress.decodeList(toAddrJson);
    final cc = EmailAddress.decodeList(ccJson);

    final participants = <String>{};
    if (fromEmail.trim().isNotEmpty) {
      participants.add(fromEmail.trim().toLowerCase());
    }
    for (final a in to) {
      final e = a.email.trim().toLowerCase();
      if (e.isNotEmpty) participants.add(e);
    }
    for (final a in cc) {
      final e = a.email.trim().toLowerCase();
      if (e.isNotEmpty) participants.add(e);
    }

    if (selfEmail != null && selfEmail.trim().isNotEmpty) {
      participants.remove(selfEmail.trim().toLowerCase());
    } else {
      final toCcOnly = <String>{};
      final fromLower = fromEmail.trim().toLowerCase();
      for (final a in to) {
        final e = a.email.trim().toLowerCase();
        if (e.isNotEmpty && e != fromLower) toCcOnly.add(e);
      }
      for (final a in cc) {
        final e = a.email.trim().toLowerCase();
        if (e.isNotEmpty && e != fromLower) toCcOnly.add(e);
      }
      return toCcOnly.length > 1;
    }

    return participants.length > 1;
  }
}
