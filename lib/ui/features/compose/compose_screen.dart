import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart' show Delta;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_to_text.dart';


import '../../../app/providers.dart';
import '../../../core/date_format.dart';
import '../../../core/turkish.dart';
import '../../../data/database/app_database.dart';
import '../../../data/services/attachment_files.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/use_cases/attachment_type.dart';
import '../../../domain/use_cases/compose_formatting.dart';
import '../../../domain/use_cases/email_html_codec.dart';
import '../../../domain/use_cases/image_attachment_resize.dart';
import '../../../domain/use_cases/share_attachment_policy.dart';
import '../../../domain/use_cases/text_extraction.dart';
import '../../../domain/use_cases/threading.dart';
import '../../../domain/use_cases/signature_formatter.dart';
import '../../core/navigation/kaydet_route.dart';
import '../settings/new_signature_sheet.dart';
import 'widgets/compose_image_embed_builder.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/attachment_icon.dart';
import '../../core/widgets/kaydet_notice.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../attachment_preview/attachment_preview_screen.dart';
import 'attachment_reminder.dart';
import 'image_size_prompt.dart';
import 'quick_contacts_strip.dart';
import 'quick_templates_sheet.dart';
import 'recipient_chip_layout.dart';
import 'recipient_details_sheet.dart';

/// Yazma ekranının açılış biçimi.
enum ComposeMode { newMessage, reply, replyAll, forward }

/// Yazma ekranı kapanırken çağırana döndürdüğü sonuç (bkz. `openCompose`).
///
/// Ekran kapandıktan sonra kullanıcıya geri bildirim veren, ekranı açan
/// tarafın işidir: yazma ekranının kendisi artık ağaçta değildir.
sealed class ComposeOutcome {
  const ComposeOutcome();
}

/// İçerikli bir taslak kaydedilerek kapandı.
final class ComposeDraftSaved extends ComposeOutcome {
  const ComposeDraftSaved(this.draftId);

  final int draftId;
}

/// İleti gönderim kuyruğuna alındı; gerçek gönderim arka planda sürer ve
/// sonucu [messageId]'nin gönderim durumundan izlenir.
final class ComposeSendQueued extends ComposeOutcome {
  const ComposeSendQueued(
    this.messageId, {
    this.undoDuration = const Duration(seconds: 5),
    this.accountId,
  });

  final int messageId;
  final Duration undoDuration;
  final int? accountId;
}

/// İleti yazma ekranı.
class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({
    super.key,
    this.draftId,
    this.replyToId,
    this.mode = ComposeMode.newMessage,
    this.initialTo,
    this.initialAttachmentPaths = const [],
    this.initialSubject,
    this.initialBody,
  });

  /// Var olan taslağı düzenlemek için.
  final int? draftId;

  /// Yanıtlanan/iletilen ileti.
  final int? replyToId;

  final ComposeMode mode;

  /// Kişiler sekmesinden "yaz" ile açıldığında Kime alanına önceden
  /// doldurulacak adres (bkz. `ContactsScreen`).
  final String? initialTo;

  /// Sistem "Paylaş" menüsünden gelen dosyalar (bkz. `ShareNavigator`) —
  /// yalnızca YENİ iletide, ek listesine seçicilerle eklenmiş gibi girer.
  final List<String> initialAttachmentPaths;

  /// Paylaşan uygulamanın verdiği konu (ör. tarayıcıdaki sayfa başlığı).
  final String? initialSubject;

  /// Paylaşılan düz metin/bağlantı; imzanın ÜSTÜNE, gövdenin başına konur.
  final String? initialBody;

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen> {
  final _to = TextEditingController();
  final _cc = TextEditingController();
  final _bcc = TextEditingController();
  final _subject = TextEditingController();
  late final QuillController _quill;
  final _bodyFocus = FocusNode();

  /// Editörün state'ini sabitler. Gövde bir `ListView` çocuğudur ve
  /// üstündeki alanların sayısı değişince (Bilgi/Gizli açılıp kapanınca, ek
  /// eklenince/çıkarılınca) dizini kayar; anahtarsız çocuk dizine göre
  /// eşleştiği için editör yeniden yaratılırdı.
  final _editorKey = GlobalKey();
  final _toFocus = FocusNode();
  final _ccFocus = FocusNode();
  final _bccFocus = FocusNode();

  /// `PopScope.canPop`in kendisi — açılışta `false`, gerçekten kapatma
  /// kararı verildiğinde (bkz. [_closeScreen]) anlık olarak `true`ya
  /// çevrilip hemen ardından pop çağrılır. Bunu hep `false` bırakıp
  /// `onPopInvokedWithResult` içinden ikinci bir `Navigator.pop` çağırmak
  /// (eski kod) her kapatma denemesinde geri çağrıyı yeniden tetikliyordu:
  /// taslak iki kez kaydediliyor, "kaydedildi" bildirimi de iki kez
  /// gösteriliyordu.
  bool _readyToPop = false;

  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;

  /// Dinleme başladığındaki imleç (veya seçim) konumu — sesli yazılan
  /// metin belgenin sonuna değil, buraya eklenir/değiştirilir.
  int _speechInsertIndex = 0;

  /// O konuma şu ana kadar eklenen sesli metnin uzunluğu; her yeni kısmi
  /// sonuçta bir öncekinin yerine geçmesi için kullanılır.
  int _speechInsertedLength = 0;

  bool _showCcBcc = false;
  bool _showFormatBar = false;
  bool _sending = false;
  bool _initialised = false;
  int? _draftId;

  /// "Gönderen" olarak seçilen hesap — AppBar'daki hesap popup'ından
  /// değiştirilebilir. GENEL aktif hesaptan (`accountIdProvider`) bağımsızdır:
  /// burada değiştirmek yalnızca bu iletiyi etkiler, Gelen Kutusu'nun hangi
  /// hesabı gösterdiğini değiştirmez (bkz. `build()`'daki hesap popup'ı).
  int? _fromAccountId;

  /// Yanıtlanan/iletilen kaynak ileti. `widget.replyToId` ile başlar, ama bir
  /// taslak devam ettirilirken taslağın kendi kaydından yeniden yüklenir —
  /// aksi hâlde taslağı yarıda bırakıp sonra gönderen kullanıcının yanıt/
  /// iletme oku (bkz. `MailRepository._markSourceMessage`) hiç görünmezdi.
  int? _replyToMessageId;
  String? _inReplyTo;
  String? _references;
  final List<String> _attachments = [];

  /// Henüz kalıcı depoya kopyalanmayı bekleyen (boyut kontrolü + `persist`)
  /// ekler — listede bir yükleniyor ikonuyla gösterilir (bkz. `_AttachmentList`).
  final List<_PendingAttachment> _pendingAttachments = [];

  /// Kalıcı depoya az önce kopyalanmış eklerin yolu — kısa süreliğine bir
  /// onay ikonuyla gösterilip ardından normal dosya türü ikonuna döner.
  final Set<String> _justUploaded = {};

  /// Seçicinin verdiği ORİJİNAL yol → kalıcı kopyanın yolu. Aynı dosya iki kez
  /// seçilirse (kalıcı kopyanın yolu her seferinde farklı olduğundan) tekrar
  /// eklenmez; ek listeden çıkarılınca kaydı da düşer, yeniden eklenebilir.
  final Map<String, String> _storedBySource = {};
  final Set<String> _labels = {};

  Timer? _autosave;
  late final ValueNotifier<bool> _hasRecipientChips;

  @override
  void initState() {
    super.initState();
    _draftId = widget.draftId;
    _replyToMessageId = widget.replyToId;
    // `_prefill` taslak/yanıt ise gerçek sahibiyle değiştirecek (aşağı bkz.);
    // yeni bir iletide bu, ilk karede gösterilecek tek değerdir.
    _fromAccountId = ref.read(accountIdProvider);
    _hasRecipientChips = ValueNotifier<bool>(
      EmailAddress.parseInput(_to.text).any((a) => a.isValid),
    );
    _quill = _createQuillController();
    _quill.addListener(_onChanged);
    for (final controller in [_to, _cc, _bcc, _subject]) {
      controller.addListener(_onChanged);
    }
    scheduleMicrotask(_prefill);
  }

  /// Dışarıdan yapıştırılan zengin içerik keyfi boyut/öznitelik taşıyabilir
  /// (bkz. [ComposeFontSize]); editöre girmeden [ComposeDeltaSanitizer]'dan
  /// geçirilir. `flutter_quill` bu kancayı `@experimental` işaretlemiş ama
  /// belgelenmiş tek yol bu; sürüm `pubspec.lock` ile sabit.
  static QuillController _createQuillController() => QuillController.basic(
    config: QuillControllerConfig(
      // ignore: experimental_member_use
      clipboardConfig: QuillClipboardConfig(
        // ignore: experimental_member_use
        onRichTextPaste: (delta, _) async =>
            ComposeDeltaSanitizer.sanitize(delta),
      ),
    ),
  );

  /// Yalnızca gerçekten YENİ bir ileti — taslak düzenlemelerde ve
  /// yanıt/iletmelerde "Kime" zaten dolu, odak gövdeye düşebilir.
  bool get _isBrandNewMessage =>
      widget.mode == ComposeMode.newMessage && widget.draftId == null;

  void _showKeyboard() {
    if (!mounted) return;
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  /// Yeni ileti açıldığında "Kime" alanına odağı platform klavyesine
  /// yansıtır. Odağın kendisi zaten `_RecipientField`'ın `autofocus`'uyla,
  /// ilk kare boyanmadan önce "Kime"ye verilmiştir (bkz. aşağıdaki
  /// `_RecipientField(label: 'Kime', autofocus: _isBrandNewMessage, ...)`)
  /// — gövde hiçbir karede odağı almaz. Yalnızca rota geçiş animasyonu
  /// bitene kadar beklenir; aksi hâlde platform klavyeyi görmezden gelir.
  void _showKeyboardAfterTransition() {
    if (!_isBrandNewMessage) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Gövde belgesi atanınca Quill (`_didChangeTextEditingValue`) klavye
      // isteyip odağı gövdeye çeker; "Kime" autofocus'u bunu geri alamaz.
      _toFocus.requestFocus();
      final animation = ModalRoute.of(context)?.animation;
      if (animation == null || animation.isCompleted) {
        _showKeyboard();
      } else {
        void listener(AnimationStatus status) {
          if (status != AnimationStatus.completed) return;
          animation.removeStatusListener(listener);
          _showKeyboard();
        }
        animation.addStatusListener(listener);
      }
    });
  }

  @override
  void dispose() {
    _autosave?.cancel();
    _hasRecipientChips.dispose();
    _quill.removeListener(_onChanged);
    _quill.dispose();
    for (final controller in [_to, _cc, _bcc, _subject]) {
      controller.dispose();
    }
    _bodyFocus.dispose();
    _toFocus.dispose();
    _ccFocus.dispose();
    _bccFocus.dispose();
    if (_listening) _speech.stop();
    super.dispose();
  }

  void _onChanged() {
    if (!_initialised) return;
    // Yazma durduktan 3 sn sonra otomatik kaydeder: uygulama çökse bile
    // yazılan metin kaybolmaz.
    _autosave?.cancel();
    _autosave = Timer(const Duration(seconds: 3), _persistDraft);
  }

  // `databaseProvider`'dan doğrudan tek seferlik sorgu kullanılır — bu
  // ekranın kendi gösterdiği ileti kalıcı olarak değişmez, bu yüzden
  // `messageProvider`/`messageBodyProvider`/`attachmentsProvider` gibi
  // canlı-izleyen (ve `mail_detail_screen.dart`'ın aksine burada hiç
  // `ref.watch` edilmeyen) `StreamProvider.family`'ler `autoDispose`
  // olmadıkları için her farklı taslak/yanıt id'sinde kalıcı bir veritabanı
  // aboneliği sızdırırdı.
  Future<void> _prefill() async {
    final db = ref.read(databaseProvider);
    final missingAttachments = <String>[];
    if (widget.draftId != null) {
      final id = widget.draftId!;
      // Üçü de bağımsız; ayrı ayrı `await` etmek yerine hepsini hemen
      // başlatıp en yavaşı kadar beklemek toplam süreyi üçe bölür.
      final rowFuture = db.messageById(id);
      final bodyFuture = db.bodyOf(id);
      final attachmentsFuture = db.attachmentsOf(id);
      final row = await rowFuture;
      final body = await bodyFuture;
      if (row != null) {
        // Taslak hangi hesapta oluşturulduysa "Gönderen" o kalır — GENEL
        // aktif hesap taslaktan sonra değişmiş olabilir.
        _fromAccountId = row.accountId;
        _to.text = EmailAddress.decodeList(
          row.toAddrJson,
        ).map((a) => a.formatted).join(', ');
        _cc.text = EmailAddress.decodeList(
          row.ccJson,
        ).map((a) => a.formatted).join(', ');
        _bcc.text = EmailAddress.decodeList(
          row.bccJson,
        ).map((a) => a.formatted).join(', ');
        _subject.text = row.subject;
        _loadBody(body?.html, body?.plainText);
        _replyToMessageId = row.replyToMessageId;
        _inReplyTo = row.inReplyTo;
        _references = row.referencesRaw;
        _showCcBcc = _cc.text.isNotEmpty || _bcc.text.isNotEmpty;
        final existing = await attachmentsFuture;
        for (final attachment in existing.where(
          (a) => a.isOutgoing && a.localPath != null,
        )) {
          final path = attachment.localPath!;
          // Cihazdan silinmiş (geçici klasör temizlenmiş) bir ek gönderimde
          // sessizce atlanmamalı: kullanıcı açılışta bilgilendirilir ve ek
          // listeden çıkarılır.
          if (File(path).existsSync()) {
            _attachments.add(path);
          } else {
            missingAttachments.add(attachment.fileName);
          }
        }
        _labels.addAll(_decodeLabels(row.labelsJson));
      }
    } else if (widget.replyToId != null) {
      final id = widget.replyToId!;
      final rowFuture = db.messageById(id);
      final bodyFuture = db.bodyOf(id);
      final row = await rowFuture;
      final body = await bodyFuture;
      if (row != null) {
        // Yanıt/iletme, iletiyi alan hesaptan gönderilir.
        _fromAccountId = row.accountId;
        await _prefetchDefaultSignature();
        final selfEmail = ref.read(accountByIdProvider(row.accountId))?.email;
        _applyReply(row, body, selfEmail);
      }
    } else {
      if (widget.initialTo != null) _to.text = widget.initialTo!;
      if (widget.initialSubject != null) _subject.text = widget.initialSubject!;
      _attachments.addAll(widget.initialAttachmentPaths);
      await _prefetchDefaultSignature();
      _initNewMessageBody();
    }

    if (!mounted) return;
    setState(() => _initialised = true);
    _hasRecipientChips.value =
        EmailAddress.parseInput(_to.text).any((a) => a.isValid);
    _showKeyboardAfterTransition();
    // Paylaşımdan gelen dosyalar henüz hiçbir yerde kayıtlı değil; ilk
    // kullanıcı dokunuşunu beklemeden otomatik kaydetmeyi başlat ki uygulama
    // hemen kapanırsa da taslak (ve ek) kaybolmasın. Cihazda bulunamayan ekler
    // listeden çıkarıldığı için taslak da güncellenir.
    if (_attachments.isNotEmpty || missingAttachments.isNotEmpty) _onChanged();
    if (missingAttachments.isNotEmpty) {
      _showError(
        'Şu ekler cihazda bulunamadığı için çıkarıldı: '
        '${missingAttachments.join(', ')}. Gerekirse yeniden ekleyin.',
      );
    }
  }

  /// Yeni iletinin ilk gövdesini ve varsayılan imzayı düzenleyiciye yükler.
  ///
  /// Paylaşılan metin varsa başa konur; varsayılan imza hem metin hem de görsel/HTML
  /// öğelerini eksiksiz koruyacak biçimde doğrudan [_insertSignature] üzerinden eklenir.
  /// Böylece otomatik eklenen imza ile araç çubuğundaki İmza düğmesinden eklenen
  /// imza birebir aynı Delta/HTML hattını kullanır.
  void _initNewMessageBody() {
    final shared = widget.initialBody?.trim() ?? '';
    if (shared.isNotEmpty) {
      _setPlainBody(shared);
      _quill.updateSelection(
        TextSelection.collapsed(
          offset: math.max(0, _quill.document.length - 1),
        ),
        ChangeSource.local,
      );
    } else {
      _setPlainBody('');
    }
    final defaultSig = _defaultSignatureRow;
    if (defaultSig != null) {
      _insertSignature(defaultSig);
    }
  }

  /// Kaydedilmiş gövdeyi düzenleyiciye yükler.
  ///
  /// HTML varsa biçimlendirmeyi korumak için önce o denenir (bkz.
  /// [EmailHtmlCodec.decode]); ayrıştırma başarısız olursa düz metne düşülür —
  /// metin hiçbir zaman kaybolmaz, yalnızca biçim kaybolabilir.
  void _loadBody(String? html, String? plainText) {
    if (html != null && html.trim().isNotEmpty) {
      try {
        final delta = EmailHtmlCodec.decode(html);
        _quill.document = Document.fromDelta(delta);
        return;
      } on Object {
        // Düz metne düş.
      }
    }
    _setPlainBody(plainText ?? '');
  }

  void _setPlainBody(String text) {
    final content = text.isEmpty
        ? '\n'
        : (text.endsWith('\n') ? text : '$text\n');
    _quill.document = Document.fromDelta(Delta()..insert(content));
  }

  static List<String> _decodeLabels(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) return decoded.whereType<String>().toList();
    } on FormatException {
      // Bozuk etiket verisi taslağı engellemez.
    }
    return const [];
  }

  void _applyReply(MessageRow row, MessageBodyRow? body, String? selfEmail) {
    final from = EmailAddress(email: row.fromEmail, name: row.fromName);
    final to = EmailAddress.decodeList(row.toAddrJson);
    final cc = EmailAddress.decodeList(row.ccJson);
    final sigRow = _defaultSignatureRow;
    final sigDelta =
        sigRow != null ? SignatureFormatter.toDelta(sigRow) : Delta();

    final quotedSource =
        body?.plainText ??
        (body?.html != null ? TextExtraction.htmlToPlain(body!.html!) : '');
    final quoteHeader =
        '\n\n${formatDetailDate(row.dateUtc)} tarihinde '
        '${from.display} <${from.email}> yazdı:\n';

    void setReplyBody(String quotePrefix, String quoteText) {
      final docDelta = Delta();
      if (sigDelta.isNotEmpty) {
        for (final op in sigDelta.toList()) {
          docDelta.push(op);
        }
      }
      docDelta.insert('$quotePrefix$quoteText\n');
      _quill.document = Document.fromDelta(docDelta);
    }

    switch (widget.mode) {
      case ComposeMode.reply:
        _to.text = from.formatted;
        _subject.text = _prefixSubject(row.subject, 'Yanıt');
        setReplyBody(quoteHeader, TextExtraction.quote(quotedSource));

      case ComposeMode.replyAll:
        // Kendi adresimiz alıcı listesinden çıkarılır.
        final others = [...to, ...cc]
            .where(
              (a) =>
                  selfEmail == null ||
                  a.email.toLowerCase() != selfEmail.toLowerCase(),
            )
            .where((a) => a.email.toLowerCase() != from.email.toLowerCase())
            .toList();
        _to.text = from.formatted;
        _cc.text = others.map((a) => a.formatted).join(', ');
        _showCcBcc = others.isNotEmpty;
        _subject.text = _prefixSubject(row.subject, 'Yanıt');
        setReplyBody(quoteHeader, TextExtraction.quote(quotedSource));

      case ComposeMode.forward:
        _subject.text = _prefixSubject(row.subject, 'İlet');
        setReplyBody(
          '\n\n---------- İletilen ileti ----------\n'
          'Kimden: ${from.formatted}\n'
          'Tarih: ${formatDetailDate(row.dateUtc)}\n'
          'Konu: ${row.subject}\n'
          'Kime: ${to.map((a) => a.formatted).join(', ')}\n\n',
          quotedSource,
        );

      case ComposeMode.newMessage:
        break;
    }

    // Konuşma zinciri: bu başlıklar olmadan alıcının istemcisi yanıtı
    // konuşmaya bağlayamaz.
    if (widget.mode != ComposeMode.forward) {
      _inReplyTo = row.messageIdHeader;
      _references = Threading.buildReferences(
        originalReferences: row.referencesRaw,
        originalMessageId: row.messageIdHeader,
      );
    }
  }

  static String _prefixSubject(String subject, String prefix) {
    final trimmed = subject.trim();
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('re:') ||
        lower.startsWith('yanıt:') ||
        lower.startsWith('yanit:') ||
        lower.startsWith('fwd:') ||
        lower.startsWith('ilet:')) {
      return trimmed;
    }
    return '$prefix: $trimmed';
  }

  String get _bodyPlainText => _quill.document.toPlainText().trim();

  /// Zengin metni gönderim/kaydetme için e-posta HTML'ine çevirir (bkz.
  /// [EmailHtmlCodec.encode]); içerik boşsa `null` döner (düz taslak olarak
  /// kalır).
  String? get _bodyHtml {
    if (_quill.document.length <= 1 && _bodyPlainText.isEmpty) return null;
    return EmailHtmlCodec.encode(_quill.document.toDelta());
  }

  bool get _hasContent =>
      _to.text.trim().isNotEmpty ||
      _cc.text.trim().isNotEmpty ||
      _bcc.text.trim().isNotEmpty ||
      _subject.text.trim().isNotEmpty ||
      _attachments.isNotEmpty ||
      _bodyDiffersFromSignature;

  bool get _bodyDiffersFromSignature {
    final signature = _defaultSignatureRow;
    if (signature == null) return _bodyPlainText.isNotEmpty;
    // Embed karakterlerini (\uFFFC) temizleyerek kullanıcının girdiği metne odaklan.
    final cleanDocText = _bodyPlainText.replaceAll('\uFFFC', '').trim();
    final sigText = signature.body.trim();
    if (cleanDocText.isNotEmpty) {
      return cleanDocText != sigText;
    }
    // Metin yok veya kullanıcı tarafından silinmiş.
    // Belgede imza görseli dışında fazladan içerik veya görsel var mı?
    final currentDelta = _quill.document.toDelta();
    final imageSource = signature.remoteImageUrl;
    final extraEmbeds = currentDelta.toList().where((op) {
      if (op.data is Map) {
        final img = (op.data as Map)['image'];
        if (img != null && img == imageSource) return false;
        return true;
      }
      return false;
    });
    return extraEmbeds.isNotEmpty;
  }

  /// [_fromAccountId] için varsayılan imza satırı.
  SignatureRow? get _defaultSignatureRow {
    final accountId = _fromAccountId;
    if (accountId == null) return null;
    final fresh = _freshDefaultSignature;
    if (fresh != null && fresh.accountId == accountId) return fresh;
    return ref.read(defaultSignatureForAccountProvider(accountId));
  }

  SignatureRow? _freshDefaultSignature;

  /// Varsayılan imzayı doğrudan veritabanından okur. `ref.read` ile okunan
  /// akış sağlayıcısı dinleyicisiz kaldığında duraklatılır ve imza
  /// ayarlarında yapılan değişiklikten önceki değeri döndürebilir.
  Future<void> _prefetchDefaultSignature() async {
    final accountId = _fromAccountId;
    if (accountId == null) return;
    final rows = await ref.read(databaseProvider).signaturesOf(accountId);
    if (rows.isEmpty) {
      _freshDefaultSignature = null;
      return;
    }
    rows.sort((a, b) => a.id.compareTo(b.id));
    _freshDefaultSignature =
        rows.where((s) => s.isDefault).firstOrNull ?? rows.first;
  }

  Future<void> _persistDraft() async {
    final accountId = _fromAccountId;
    if (accountId == null || !_hasContent) return;
    final id = await ref
        .read(mailRepositoryProvider)
        .saveDraft(
          accountId: accountId,
          draftId: _draftId,
          to: _to.text,
          cc: _cc.text,
          bcc: _bcc.text,
          subject: _subject.text,
          body: _bodyPlainText,
          html: _bodyHtml,
          attachmentPaths: _attachments,
          replyToMessageId: _replyToMessageId,
          inReplyTo: _inReplyTo,
          references: _references,
        );
    if (id > 0) _draftId = id;
  }

  /// Yanıt taslağı yalnızca `references`'ı yazılır (bkz. `_applyReply`),
  /// iletme taslağında bu alan hiç doldurulmaz. Taslak yarıda bırakılıp
  /// sonra gönderildiğinde `widget.mode` artık `newMessage`dır; bu yüzden
  /// yanıt/iletme ayrımı burada bu izden çıkarılır.
  bool get _sourceIsReply =>
      widget.mode == ComposeMode.reply ||
      widget.mode == ComposeMode.replyAll ||
      (widget.mode == ComposeMode.newMessage &&
          _replyToMessageId != null &&
          _inReplyTo != null);

  bool get _sourceIsForward =>
      widget.mode == ComposeMode.forward ||
      (widget.mode == ComposeMode.newMessage &&
          _replyToMessageId != null &&
          _inReplyTo == null);

  bool _checkForForgottenAttachment() {
    return AttachmentReminder.shouldWarn(
      subject: _subject.text,
      body: _bodyPlainText,
      hasAttachments: _attachments.isNotEmpty,
      isReplyOrForward: _sourceIsReply || _sourceIsForward,
    );
  }

  Future<bool?> _confirmMissingAttachment() => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Ek eklemeyi unuttunuz mu?'),
      content: const Text(
        'İletinizin metninde veya konusunda ekli bir dosyadan bahsedilmiş ancak herhangi bir ek bulunmuyor. Yine de göndermek istiyor musunuz?',
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        DialogActions(
          cancelLabel: 'Ek Ekle',
          onCancel: () => Navigator.of(context).pop(false),
          confirmLabel: 'Yine de Gönder',
          onConfirm: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );

  Future<void> _send() async {
    final accountId = _fromAccountId;
    if (accountId == null) return;

    final recipients = EmailAddress.parseInput(_to.text);
    if (recipients.isEmpty) {
      _showError('En az bir alıcı girin.');
      return;
    }
    final invalid = [
      ...recipients,
      ...EmailAddress.parseInput(_cc.text),
      ...EmailAddress.parseInput(_bcc.text),
    ].where((a) => !a.isValid).toList();
    if (invalid.isNotEmpty) {
      _showError('Geçersiz adres: ${invalid.first.email}');
      return;
    }

    if (_checkForForgottenAttachment()) {
      final proceed = await _confirmMissingAttachment();
      if (proceed != true) {
        // Kullanıcı ek eklemek istiyor: dosya seçiciyi aç
        await _pickFilesFromDisk();
        return;
      }
    }

    if (_subject.text.trim().isEmpty) {
      final proceed = await _confirmNoSubject();
      if (proceed != true) return;
    }

    setState(() => _sending = true);
    _autosave?.cancel();

    final undoWindow = ref.read(sendUndoWindowProvider);
    final repository = ref.read(mailRepositoryProvider);
    final messageId = await repository.queueSend(
      accountId: accountId,
      draftId: _draftId,
      to: _to.text,
      cc: _cc.text,
      bcc: _bcc.text,
      subject: _subject.text,
      body: _bodyPlainText,
      html: _bodyHtml,
      attachmentPaths: _attachments,
      replyToMessageId: _replyToMessageId,
      inReplyTo: _inReplyTo,
      references: _references,
      markSourceAnswered: _sourceIsReply,
      markSourceForwarded: _sourceIsForward,
      undoDelay: undoWindow,
    );
    if (!mounted) return;

    // Negatif kimlik ileti hiç kaydedilemedi demektir (klasörler henüz
    // eşitlenmemiş). Ekran kapatılıp "gönderiliyor" denirse ileti sessizce
    // kaybolurdu; kullanıcı yazdıklarıyla ekranda kalır ve yeniden dener.
    if (messageId < 0) {
      setState(() => _sending = false);
      _showError(
        'İleti gönderilemedi. Lütfen birkaç saniye sonra tekrar deneyin.',
      );
      return;
    }

    Navigator.of(context).pop<ComposeOutcome>(
      ComposeSendQueued(
        messageId,
        undoDuration: undoWindow,
        accountId: accountId,
      ),
    );
  }

  void _showQuickTemplates() {
    QuickTemplatesSheet.show(
      context,
      onSelect: _insertTemplate,
    );
  }

  void _insertTemplate(String text) {
    if (text.isEmpty) return;
    final selection = _quill.selection;
    final index = selection.isValid
        ? selection.start
        : math.max(0, _quill.document.length - 1);
    final length = selection.isValid ? selection.end - selection.start : 0;
    final formatted = text.endsWith('\n') ? text : '$text\n\n';
    _quill.replaceText(
      index,
      length,
      formatted,
      TextSelection.collapsed(offset: index + formatted.length),
    );
    _onChanged();
  }

  void _showError(String message) {
    KaydetNotice.show(Overlay.of(context, rootOverlay: true), message: message);
  }

  Future<bool?> _confirmNoSubject() => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Konu boş'),
      content: const Text('Konu satırı boş. Yine de gönderilsin mi?'),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        DialogActions(
          cancelLabel: 'Vazgeç',
          onCancel: () => Navigator.of(context).pop(false),
          confirmLabel: 'Gönder',
          onConfirm: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );

  /// Geri tuşu/kapatma: içerik varsa sormadan doğrudan taslak olarak
  /// kaydedilir ve kaydedilen taslak [ComposeDraftSaved] olarak
  /// `Navigator.pop` sonucuyla döndürülür — ekranı `openCompose` açtığı için
  /// "İleti Taslaklara kaydedildi" bildirimini, yanında bir "Sil" eylemiyle o
  /// gösterir (bkz. `compose_launcher.dart`). İçerik yoksa kaydetmeden `null`
  /// döner.
  Future<int?> _saveDraftOnExit() async {
    if (!_hasContent) return null;
    _autosave?.cancel();
    await _persistDraft();
    return _draftId;
  }

  /// Ekranı kapatmanın TEK yolu — hem sistem geri tuşu (bkz. `PopScope`)
  /// hem de AppBar'daki X düğmesi buraya çıkar. Taslağı kaydeder, `canPop`u
  /// gerçek kapanış anında `true`ya çevirir ve öyle pop eder — bu sayede
  /// pop yalnızca BİR kez gerçekleşir (bkz. [_readyToPop] alanının
  /// açıklaması).
  Future<void> _closeScreen() async {
    final draftId = await _saveDraftOnExit();
    if (!mounted) return;
    setState(() => _readyToPop = true);
    Navigator.of(
      context,
    ).pop<ComposeOutcome>(draftId == null ? null : ComposeDraftSaved(draftId));
  }

  /// Ek kaynağı seçildikten sonra (bkz. `_AttachMenuButton`) ilgili
  /// seçiciyi açar.
  Future<void> _handleAttachSource(_AttachSource source) async {
    // Sistem galeri/kamera/dosya seçicisi açılırken pencere odağı
    // Flutter'dan uzaklaşıyor; hâlâ bağlı bir metin girişi varsa bu geçiş
    // sırasında yazılım klavyesi (özellikle Samsung klavyesi) anlık olarak
    // yeniden tetikleniyor. Seçiciyi açmadan önce odağı kaldırmak bu
    // titremeyi engeller.
    FocusScope.of(context).unfocus();
    // `unfocus()` eşzamanlı döner ama klavyenin gerçek kapanma animasyonu
    // asenkron sürer (~100-200ms). Seçici (yeni bir native Activity/Intent)
    // hemen ardından açılırsa bu animasyon tam bitmeden pencere odağı
    // geçişi olur ve klavye bir anlığına yeniden görünür — bu gecikme
    // animasyonun bitmesini bekleyerek titremeyi engeller.
    await Future.delayed(const Duration(milliseconds: 150));
    if (!mounted) return;
    switch (source) {
      case _AttachSource.gallery:
        await _pickFromGallery();
      case _AttachSource.camera:
        await _pickFromCamera();
      case _AttachSource.files:
        await _pickFilesFromDisk();
    }
  }

  /// Seçili metnin (varsa) yerine, yoksa imleç konumuna imzayı (metin + görsel)
  /// ekler — sesli yazmayla aynı yerleştirme deseni (bkz. `_startListening`).
  void _insertSignature(SignatureRow signature) {
    final sigDelta = SignatureFormatter.toDelta(signature);
    if (sigDelta.isEmpty) return;

    // Aynı imza gövdede zaten varsa (otomatik eklenen varsayılan dahil) tekrar eklenmez.
    final currentDelta = _quill.document.toDelta();
    final jsonStr = jsonEncode(currentDelta.toJson());
    if (SignatureFormatter.isAlreadyInserted(jsonStr, signature) ||
        (signature.body.trim().isNotEmpty &&
            _bodyPlainText.contains(signature.body.trim()))) {
      return;
    }

    final selection = _quill.selection;
    final index = selection.isValid
        ? selection.start
        : math.max(0, _quill.document.length - 1);
    final length = selection.isValid ? selection.end - selection.start : 0;

    final insertDelta = Delta();
    if (index > 0 && !_quill.document.toPlainText().endsWith('\n\n')) {
      insertDelta.insert('\n');
    }
    for (final op in sigDelta.toList()) {
      insertDelta.push(op);
    }

    final docLength = _quill.document.length;
    final targetIndex = index.clamp(0, docLength);
    final validLength = length.clamp(0, docLength - targetIndex);

    final composeDelta = Delta();
    if (targetIndex > 0) composeDelta.retain(targetIndex);
    if (validLength > 0) composeDelta.delete(validLength);
    for (final op in insertDelta.toList()) {
      composeDelta.push(op);
    }
    _quill.compose(
      composeDelta,
      TextSelection.collapsed(offset: targetIndex + insertDelta.length),
      ChangeSource.local,
    );
  }

  Future<void> _pickFromGallery() async {
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles(type: FileType.image);
    } on Object catch (_) {
      // Fallback: FilePicker başarısız olursa ImagePicker dene
      try {
        final multi = await ImagePicker().pickMultiImage();
        if (multi.isNotEmpty) {
          final picks = <({String path, String? originalName})>[];
          for (final xfile in multi) {
            final clean = AttachmentFiles.cleanPickedName(
              xfile.name,
              sourcePath: xfile.path,
            );
            picks.add((path: xfile.path, originalName: clean));
          }
          await _addPickedPaths(picks);
          return;
        }
      } on Object catch (_) {
        if (!mounted) return;
        _showError('Galeriye erişilemedi.');
        return;
      }
      if (!mounted) return;
      _showError('Galeriye erişilemedi.');
      return;
    }
    if (files.isEmpty) return;
    await _addPlatformFiles(files);
  }

  Future<void> _pickFromCamera() async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.camera);
    } on Object catch (_) {
      if (!mounted) return;
      _showError('Kameraya erişilemedi.');
      return;
    }
    if (picked == null) return;
    final now = DateTime.now();
    final dateStr = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final ext = p.extension(picked.path).isNotEmpty
        ? p.extension(picked.path)
        : '.jpg';
    final name = 'IMG_$dateStr$ext';
    await _addPickedPaths([
      (path: picked.path, originalName: name),
    ]);
  }

  Future<void> _pickFilesFromDisk() async {
    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles();
    } on Object catch (_) {
      if (mounted) _showError('Dosya seçilemedi.');
      return;
    }
    if (files.isEmpty) return;
    await _addPlatformFiles(files);
  }

  Future<void> _addPlatformFiles(List<PlatformFile> files) async {
    final picks = <({String path, String? originalName})>[];
    for (final file in files) {
      final cleanName = AttachmentFiles.cleanPickedName(
        file.name,
        sourcePath: file.path,
      );
      final path = file.path;
      if (path != null) {
        picks.add((path: path, originalName: cleanName));
      } else {
        // iOS: path null — readAsByteStream ile oku, geçici dosyaya yaz.
        try {
          final tmpDir = await getTemporaryDirectory();
          final tmpFile = File(
            p.join(
              tmpDir.path,
              'kaydet_pick_${DateTime.now().microsecondsSinceEpoch}_$cleanName',
            ),
          );
          final sink = tmpFile.openWrite();
          await sink.addStream(file.readAsByteStream());
          await sink.flush();
          await sink.close();
          picks.add((path: tmpFile.path, originalName: cleanName));
        } on Object catch (_) {
          if (mounted) _showError('"$cleanName" okunamadı, eklenemedi.');
        }
      }
    }
    await _addPickedPaths(picks);
  }

  /// Az önce seçilen dosyaları ek listesine katar. Aralarında görsel varsa
  /// önce boyut tercihi sorulur (bkz. `showImageSizePrompt`) — gerçek
  /// Outlook/Gmail davranışı: küçültme yalnızca bu partideki GÖRSELLERE
  /// uygulanır, diğer dosya türleri her zamanki gibi olduğu gibi eklenir.
  Future<void> _addPickedPaths(
    List<({String path, String? originalName})> picks,
  ) async {
    if (picks.isEmpty) return;
    final imageIndexes = <int>{
      for (var i = 0; i < picks.length; i++)
        if (AttachmentType.resolve(
              mimeType: '',
              fileName: picks[i].originalName ?? picks[i].path,
            ) ==
            AttachmentKind.image)
          i,
    };

    var reduce = false;
    if (imageIndexes.isNotEmpty && mounted) {
      final choice = await showImageSizePrompt(
        context,
        imageCount: imageIndexes.length,
      );
      reduce = choice == ImageSizeChoice.reduced;
    }

    for (var i = 0; i < picks.length; i++) {
      if (!mounted) return;
      final pick = picks[i];
      if (reduce && imageIndexes.contains(i)) {
        final resized = await resizeImageAttachment(
          File(pick.path),
          originalName: pick.originalName,
        );
        await _addAttachmentPath(resized.path, originalName: pick.originalName);
      } else {
        await _addAttachmentPath(pick.path, originalName: pick.originalName);
      }
    }
  }


  /// Seçilen dosyayı ek listesine katar.
  ///
  /// - Boyut sınırları (bkz. [ShareAttachmentPolicy]): SMTP gönderimi eki
  ///   bütünüyle belleğe alıp base64'e çevirir; sınırsız bir dosya düşük
  ///   donanımlı cihazda bellek yetersizliğine yol açar, çoğu sunucu da 25 MB
  ///   üstünü reddeder.
  /// - Dosya kalıcı depoya kopyalanır (bkz. `OutgoingAttachmentStore`):
  ///   seçicinin verdiği yol geçici bir klasördedir ve taslak beklerken
  ///   silinebilir.
  Future<void> _addAttachmentPath(String path, {String? originalName}) async {
    if (_attachments.contains(path) || _storedBySource.containsKey(path)) return;
    // Orijinal ad verilmişse onu, yoksa path'ten temizlenmiş adı al.
    final name = AttachmentFiles.cleanPickedName(
      (originalName != null && originalName.trim().isNotEmpty)
          ? originalName
          : path.split(RegExp(r'[\\/]')).last,
      sourcePath: path,
    );

    // Boyut kontrolü ve `persist` kopyası bitene kadar kullanıcı bir
    // yükleniyor ikonu görür — aksi hâlde ek, işlem bitene kadar listede hiç
    // görünmez ve kullanıcı eklemenin gerçekten başladığını bilemez.
    final pending = _PendingAttachment(path, name);
    if (mounted) setState(() => _pendingAttachments.add(pending));
    void dropPending() {
      if (mounted) setState(() => _pendingAttachments.remove(pending));
    }

    final int size;
    try {
      size = await File(path).length();
    } on FileSystemException {
      dropPending();
      if (mounted) _showError('“$name” okunamadı, eklenemedi.');
      return;
    }
    if (size > ShareAttachmentPolicy.maxFileBytes) {
      dropPending();
      if (mounted) {
        _showError(
          '“$name” çok büyük (en fazla '
          '${ShareAttachmentPolicy.maxFileBytes >> 20} MB), eklenmedi.',
        );
      }
      return;
    }
    var total = size;
    for (final existing in _attachments) {
      try {
        total += await File(existing).length();
      } on FileSystemException {
        // Zaten silinmiş bir ek toplama katılmaz.
      }
    }
    if (total > ShareAttachmentPolicy.maxTotalBytes) {
      dropPending();
      if (mounted) {
        _showError(
          'Eklerin toplamı en fazla '
          '${ShareAttachmentPolicy.maxTotalBytes >> 20} MB olabilir; '
          '“$name” eklenmedi.',
        );
      }
      return;
    }

    final String stored;
    try {
      stored = await ref
          .read(outgoingAttachmentStoreProvider)
          .persist(path, originalName: name);
    } on Object catch (_) {
      dropPending();
      if (mounted) _showError('“$name” eklenemedi.');
      return;
    }
    if (!mounted || _attachments.contains(stored)) {
      dropPending();
      return;
    }
    _storedBySource[path] = stored;
    setState(() {
      _pendingAttachments.remove(pending);
      _attachments.add(stored);
      _justUploaded.add(stored);
    });
    _onChanged();
    Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() => _justUploaded.remove(stored));
    });
  }

  /// Etiket anında değişir — "..." menüsündeki onay kutusuna dokunur
  /// dokunmaz uygulanır (bkz. `_ComposeMoreMenu`), ayrı bir "Bitti" onayı
  /// yok. Taslak henüz kaydedilmemişse önce kaydedilir.
  Future<void> _toggleLabel(String name) async {
    final adding = !_labels.contains(name);
    setState(() {
      if (adding) {
        _labels.add(name);
      } else {
        _labels.remove(name);
      }
    });
    _onChanged();

    if (_draftId == null || _draftId! <= 0) {
      await _persistDraft();
    }
    final draftId = _draftId;
    if (draftId == null || draftId <= 0) return;

    await ref
        .read(mailRepositoryProvider)
        .setLabel(messageIds: [draftId], labelName: name, add: adding);
  }

  /// Sesli yazma.
  Future<void> _toggleMic() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }

    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (mounted) setState(() => _listening = false);
          }
        },
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        },
      );
    }

    if (!_speechReady) {
      _showError('Mikrofon kullanılamıyor. İzinleri kontrol edin.');
      return;
    }

    // İmleç bir yere konumlanmışsa (veya bir metin seçiliyse) sesli yazma
    // tam oraya eklenir/seçimin yerine geçer — imza dahil geri kalan metin
    // olduğu yerde kalır. İmleç hiç konumlanmamışsa (gövdeye hiç
    // dokunulmadan mikrofona basılmışsa) belgenin sonuna düşülür.
    final selection = _quill.selection;
    _speechInsertIndex = selection.isValid
        ? selection.start
        : _quill.document.length - 1;
    _speechInsertedLength = selection.isValid
        ? selection.end - selection.start
        : 0;
    setState(() => _listening = true);
    _bodyFocus.requestFocus();

    await _speech.listen(
      listenOptions: SpeechListenOptions(
        localeId: 'tr_TR',
        partialResults: true,
        cancelOnError: true,
      ),
      onResult: (result) {
        final spoken = result.recognizedWords;
        if (spoken.isEmpty) return;
        // Kısmi sonuçlar her seferinde o ana kadar tanınan TÜM cümleyi
        // getirir — bu yüzden önceki eklemenin üzerine, aynı noktada
        // yeniden yazılır.
        final before = _quill.document.toPlainText().substring(
          0,
          _speechInsertIndex,
        );
        final needsLeadingSpace =
            before.isNotEmpty &&
            !before.endsWith('\n') &&
            !before.endsWith(' ');
        final insertText = needsLeadingSpace ? ' $spoken' : spoken;
        _quill.replaceText(
          _speechInsertIndex,
          _speechInsertedLength,
          insertText,
          TextSelection.collapsed(
            offset: _speechInsertIndex + insertText.length,
          ),
        );
        _speechInsertedLength = insertText.length;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Üst çubuğun ana metin/ikon rengi — açık temada artık mavi zeminli
    // (bkz. `KaydetTokens.light.appBarBg`), koyu temada değişmedi.
    final onAppBar = Theme.of(context).appBarTheme.foregroundColor ?? t.textPrimary;
    final fromAccountId = _fromAccountId;
    final signatures = fromAccountId == null
        ? const <SignatureRow>[]
        : ref.watch(signaturesForAccountProvider(fromAccountId)).value ??
              const [];
    final allAccounts =
        ref.watch(allAccountsProvider).value ?? const <AccountRow>[];
    final account = fromAccountId == null
        ? null
        : ref.watch(accountByIdProvider(fromAccountId));

    return PopScope(
      canPop: _readyToPop,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _closeScreen();
      },
      child: Scaffold(
        appBar: AppBar(
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(height: 1, thickness: 1, color: t.divider),
          ),
          leading: IconButton(
            icon: const Icon(LucideIcons.x),
            tooltip: 'Kapat',
            onPressed: _closeScreen,
          ),
          title: MenuAnchor(
            animated: true,
            // Yalnızca tek hesap varsa seçilecek başka bir şey yok — popup'ı
            // hiç açma (bkz. `builder` altındaki `InkWell.onTap`).
            menuChildren: [
              for (final acc in allAccounts)
                MenuItemButton(
                  leadingIcon: BrandAvatar(
                    name: acc.displayName,
                    email: acc.email,
                    isSelected: acc.id == fromAccountId,
                    size: 28,
                  ),
                  onPressed: () => setState(() => _fromAccountId = acc.id),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        acc.email,
                        style: AppText.bodyMedium.copyWith(
                          color: t.textPrimary,
                        ),
                      ),
                      if (acc.displayName.trim().isNotEmpty)
                        Text(
                          acc.displayName,
                          style: AppText.labelSmall.copyWith(
                            color: t.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
            builder: (context, controller, child) => InkWell(
              borderRadius: BorderRadius.circular(Radii.sm),
              onTap: allAccounts.length < 2
                  ? null
                  : () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
              child: Row(
                children: [
                  BrandAvatar(
                    name: account?.displayName,
                    email: account?.email,
                    size: 36,
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _titleForMode(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: onAppBar,
                            fontWeight: FontWeight.w600,
                            fontVariations: AppText.semibold,
                            fontSize: 18 * AppText.scale,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                account?.email ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: onAppBar.withValues(alpha: 0.82),
                                  fontSize: 13 * AppText.scale,
                                ),
                              ),
                            ),
                            if (allAccounts.length > 1)
                              Icon(
                                Icons.keyboard_arrow_down,
                                color: onAppBar.withValues(alpha: 0.82),
                                size: 16,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            IconButton(
              icon: _sending
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: onAppBar,
                      ),
                    )
                  : Icon(LucideIcons.sendHorizontal, color: onAppBar),
              tooltip: 'Gönder',
              onPressed: _sending ? null : () => _send(),
            ),
            const SizedBox(width: Space.xs),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                // Kullanıcı gövdeyi kaydırmaya başlar başlamaz klavye
                // kapanır — aşağıdaki alanlar (ekler, imza) görünür olur.
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  _RecipientField(
                    label: 'Kime',
                    controller: _to,
                    focusNode: _toFocus,
                    autofocus: _isBrandNewMessage,
                    accountId: fromAccountId,
                    onChipsChanged: (chips) {
                      _hasRecipientChips.value = chips.any((a) => a.isValid);
                    },
                    trailing: IconButton(
                      icon: Icon(
                        _showCcBcc
                            ? LucideIcons.chevronUp
                            : LucideIcons.chevronDown,
                        size: IconSize.md,
                      ),
                      tooltip: _showCcBcc ? 'Gizle' : 'Bilgi/Gizli ekle',
                      onPressed: () => setState(() => _showCcBcc = !_showCcBcc),
                    ),
                  ),
                  if (_showCcBcc) ...[
                    _RecipientField(
                      label: 'Bilgi',
                      controller: _cc,
                      focusNode: _ccFocus,
                      accountId: fromAccountId,
                    ),
                    _RecipientField(
                      label: 'Gizli',
                      controller: _bcc,
                      focusNode: _bccFocus,
                      accountId: fromAccountId,
                    ),
                  ],
                  _RecipientField(
                    label: 'Konu',
                    controller: _subject,
                    isSubject: true,
                  ),
                  if (_attachments.isNotEmpty || _pendingAttachments.isNotEmpty)
                    _AttachmentList(
                      paths: _attachments,
                      pending: _pendingAttachments,
                      justUploaded: _justUploaded,
                      onRemove: (path) {
                        _storedBySource.removeWhere((_, stored) => stored == path);
                        setState(() => _attachments.remove(path));
                        _onChanged();
                      },
                    ),
                  if (_labels.isNotEmpty) _LabelsRow(names: _labels),
                  Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: DefaultTextStyle(
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge!.copyWith(color: t.textPrimary),
                      child: QuillEditor.basic(
                        key: _editorKey,
                        controller: _quill,
                        focusNode: _bodyFocus,
                        config: const QuillEditorConfig(
                          scrollable: false,
                          expands: false,
                          autoFocus: false,
                          padding: EdgeInsets.zero,
                          placeholder: 'İletinizi buraya yazın…',
                          textCapitalization: TextCapitalization.sentences,
                          minHeight: 220,
                          customStyleBuilder: _composeCustomStyle,
                          embedBuilders: [ComposeImageEmbedBuilder()],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _ComposeToolbar(
              listening: _listening,
              selectedLabels: _labels,
              isFormatBarOpen: _showFormatBar,
              quillController: _quill,
              signatures: signatures,
              onMic: _toggleMic,
              onAttachSource: _handleAttachSource,
              onToggleLabel: _toggleLabel,
              onToggleFormat: () =>
                  setState(() => _showFormatBar = !_showFormatBar),
              onSignatureSelected: (signature) =>
                  _insertSignature(signature),
              // Yeni imza, bu iletinin "Gönderen" hesabına eklenir; liste o
              // hesabın canlı akışından geldiği için hemen menüde görünür.
              onNewSignature: () {
                final accountId = _fromAccountId;
                if (accountId == null) return;
                showNewSignatureSheet(context, ref, accountId: accountId);
              },
              onOpenTemplates: _showQuickTemplates,
            ),
          ],
        ),
      ),
    );
  }

  String _titleForMode() => switch (widget.mode) {
    ComposeMode.reply => 'Yanıtla',
    ComposeMode.replyAll => 'Tümünü yanıtla',
    ComposeMode.forward => 'İlet',
    ComposeMode.newMessage => widget.draftId != null ? 'Taslak' : 'Yeni ileti',
  };
}

/// Satır aralığını editörde giden HTML'dekiyle BİREBİR çizer.
///
/// Quill yalnızca 4 sabit `line-height` değerini tanır ve kendi tablosundaki
/// yüksekliği kullanır: 1.15 → 1.30, 1.5 → 1.55 çiziliyordu — editörde
/// görülen aralık alıcıya giden aralıktan farklıydı. Bu oluşturucu Quill'in
/// tablosunu geçersiz kılar (bkz. [ComposeLineSpacing]).
TextStyle _composeCustomStyle(Attribute attribute) {
  if (attribute.key != Attribute.lineHeight.key) return const TextStyle();
  final spacing = ComposeLineSpacing.fromAttribute(attribute.value);
  return TextStyle(height: spacing?.height);
}

/// Kime/Bilgi/Gizli/Konu satırı. Konu düz metindir; adres satırları
/// [_RecipientChipsField] ile Outlook gibi "avatar + ad" çipleri çizer.
class _RecipientField extends StatelessWidget {
  const _RecipientField({
    required this.label,
    required this.controller,
    this.trailing,
    this.focusNode,
    this.isSubject = false,
    this.autofocus = false,
    this.accountId,
    this.onChipsChanged,
  });

  final String label;
  final TextEditingController controller;
  final Widget? trailing;
  final FocusNode? focusNode;
  final bool isSubject;
  final bool autofocus;

  /// Kişi otomatik tamamlaması hangi hesabın kişi defterinden gelsin — bkz.
  /// `ComposeScreen._fromAccountId`. Yalnızca e-posta alanlarında (Kime/
  /// Bilgi/Gizli) kullanılır, `isSubject: true` iken yok sayılır.
  final int? accountId;
  final ValueChanged<List<EmailAddress>>? onChipsChanged;

  static const _fieldDecoration = InputDecoration(
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    contentPadding: EdgeInsets.symmetric(vertical: Space.md),
    isDense: true,
  );

  @override
  Widget build(BuildContext context) {
    if (!isSubject) {
      return _RecipientChipsField(
        label: label,
        controller: controller,
        focusNode: focusNode!,
        autofocus: autofocus,
        accountId: accountId,
        trailing: trailing,
        onChipsChanged: onChipsChanged,
      );
    }
    final t = context.tokens;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.divider)),
      ),
      padding: const EdgeInsets.only(left: Space.lg, right: Space.sm),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: t.textTertiary,
                fontSize: 12 * AppText.scale,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: TextInputType.text,
              textCapitalization: TextCapitalization.sentences,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontSize: 14.5 * AppText.scale,
                fontWeight: FontWeight.w600,
                fontVariations: AppText.semibold,
              ),
              decoration: _fieldDecoration,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Kime/Bilgi/Gizli alanı: tamamlanmış adresler "avatar + ad" çipi olarak,
/// yazılmakta olan parça ise çiplerin yanındaki satır içi metin alanında
/// durur; yazarken seçili "Gönderen" hesabın kişi defterindeki eşleşenler
/// alanın altında tam genişlikte (avatar + ad + adres) önerilir.
///
/// Gerçeğin kaynağı hâlâ [controller]'ın metnidir (`ad <adres>, adres, …`):
/// taslak, gönderim ve ön-doldurma kodu bu metni okur/yazar. Çipler bu
/// metnin ayrıştırılmış görünümüdür; alan her değişiklikte metni geri yazar,
/// dışarıdan (ön-doldurma, taslak yükleme) yazılan metni ise yeniden
/// ayrıştırıp çiplere çevirir.
///
/// Öneri listesi zaten en son kullanılana göre sıralı geldiğinden (bkz.
/// `AppDatabase.watchContacts`), tek bir harf yazıldığı anda en üstte
/// "en son/en çok kullanılan" eşleşme çıkar.
class _RecipientChipsField extends ConsumerStatefulWidget {
  const _RecipientChipsField({
    required this.label,
    required this.controller,
    required this.focusNode,
    this.autofocus = false,
    this.accountId,
    this.trailing,
    this.onChipsChanged,
  });

  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool autofocus;
  final int? accountId;
  final Widget? trailing;
  final ValueChanged<List<EmailAddress>>? onChipsChanged;

  @override
  ConsumerState<_RecipientChipsField> createState() =>
      _RecipientChipsFieldState();
}

class _RecipientChipsFieldState extends ConsumerState<_RecipientChipsField> {
  static const _maxSuggestions = 8;

  /// Hızlı Kişiler şeridinin en fazla kaç kişi göstereceği — arama
  /// ekranındaki şeritle aynı (bkz. `AppDatabase.watchRecentContacts`).
  static const _maxQuickContacts = 12;
  static final _separators = RegExp(r'[,;\n]');

  /// Yazılmakta olan (henüz çipe dönmemiş) parça.
  final _input = TextEditingController();
  List<EmailAddress> _chips = [];

  /// Kendi yazdığımız değişikliği dış değişiklikten ayırır.
  bool _writing = false;

  /// Öneri katmanı `Overlay`'de çizildiği için alanın genişliğini buradan
  /// öğrenir (bkz. `LayoutBuilder` aşağıda).
  double _fieldWidth = 360;

  @override
  void initState() {
    super.initState();
    _chips = _dedupe(EmailAddress.parseInput(widget.controller.text));
    widget.controller.addListener(_onExternalChange);
    widget.focusNode.addListener(_onFocusChange);
    widget.focusNode.onKeyEvent = _onKeyEvent;
    if (_chips.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _notifyChips();
      });
    }
  }

  @override
  void didUpdateWidget(_RecipientChipsField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onExternalChange);
      widget.controller.addListener(_onExternalChange);
      _chips = _dedupe(EmailAddress.parseInput(widget.controller.text));
      _input.clear();
      _notifyChips();
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode
        ..removeListener(_onFocusChange)
        ..onKeyEvent = null;
      widget.focusNode
        ..addListener(_onFocusChange)
        ..onKeyEvent = _onKeyEvent;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onExternalChange);
    widget.focusNode
      ..removeListener(_onFocusChange)
      ..onKeyEvent = null;
    _input.dispose();
    super.dispose();
  }

  void _notifyChips() {
    widget.onChipsChanged?.call(List.unmodifiable(_chips));
  }

  // ---- Model <-> metin ----

  static List<EmailAddress> _dedupe(List<EmailAddress> list) {
    final seen = <String>{};
    return [
      for (final a in list)
        if (seen.add(a.email.toLowerCase())) a,
    ];
  }

  void _writeBack() {
    final parts = [
      for (final chip in _chips) chip.formatted,
      if (_input.text.trim().isNotEmpty) _input.text.trim(),
    ];
    _writing = true;
    try {
      widget.controller.text = parts.join(', ');
    } finally {
      _writing = false;
    }
  }

  /// Ön-doldurma / taslak yükleme gibi dışarıdan yazılan metin.
  void _onExternalChange() {
    if (_writing || !mounted) return;
    setState(() {
      _chips = _dedupe(EmailAddress.parseInput(widget.controller.text));
      _input.clear();
    });
    _notifyChips();
  }

  // ---- Çip işlemleri ----

  void _addChips(Iterable<EmailAddress> addresses) {
    final next = _dedupe([..._chips, ...addresses]);
    setState(() => _chips = next);
    _writeBack();
    _notifyChips();
  }

  void _removeChip(EmailAddress address) {
    setState(
      () => _chips = [
        for (final c in _chips)
          if (c != address) c,
      ],
    );
    _writeBack();
    _notifyChips();
  }

  /// Yazılmakta olan parça geçerli bir adresse çipe çevirir.
  bool _commitFragment({bool onlyIfValid = true}) {
    final text = _input.text.trim();
    if (text.isEmpty) return false;
    final parsed = EmailAddress.parseInput(text);
    if (onlyIfValid && (parsed.isEmpty || parsed.any((a) => !a.isValid))) {
      return false;
    }
    _input.clear();
    _addChips(parsed);
    return true;
  }

  void _onInputChanged(String value) {
    final sep = value.lastIndexOf(_separators);
    if (sep != -1) {
      // Virgül/noktalı virgül/satır sonu (ya da çok adresli yapıştırma):
      // ayırıcıya kadarki kısım çip olur, sonrası yeni parça olarak kalır.
      final head = value.substring(0, sep);
      final tail = value.substring(sep + 1).trimLeft();
      _input.value = TextEditingValue(
        text: tail,
        selection: TextSelection.collapsed(offset: tail.length),
      );
      _addChips(EmailAddress.parseInput(head));
      return;
    }
    // Boşluk: yazılan şey tam bir adresse çipe çevir (Outlook gibi).
    if (value.endsWith(' ') && EmailAddress.isValidEmail(value)) {
      _commitFragment();
      return;
    }
    _writeBack();
  }

  void _onFocusChange() {
    if (!widget.focusNode.hasFocus) _commitFragment();
  }

  /// Yazma alanının en az istediği genişlik; yerleşim planı da bunu kullanır.
  static const double _inputMinWidth = 96;

  /// "+N"e dokunulunca tüm alıcıları listeler; buradan tek tek silinebilir.
  /// Kapatılınca alan yine en fazla iki satırlık kompakt görünüme döner.
  Future<void> _showAllRecipients() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      sheetAnimationStyle: AnimationStyle(
        duration: context.motion(Motion.base),
        reverseDuration: context.motion(Motion.fast),
        curve: Motion.standard,
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final t = context.tokens;
          final textTheme = Theme.of(context).textTheme;
          if (_chips.isEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) Navigator.of(context).maybePop();
            });
          }
          return SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.75,
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
                            widget.label == 'Kime'
                                ? 'Alıcılar'
                                : '${widget.label} alıcıları',
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
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: Space.lg),
                      children: [
                        for (final chip in List.of(_chips))
                          InkWell(
                            onTap: () => _showDetails(chip),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Space.lg,
                                vertical: Space.xs,
                              ),
                              child: Row(
                                children: [
                                  BrandAvatar(
                                    name: chip.name,
                                    email: chip.email,
                                    size: 28,
                                  ),
                                  const SizedBox(width: Space.md),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (chip.display != chip.email)
                                          Text(
                                            chip.display,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: textTheme.bodyMedium
                                                ?.copyWith(
                                                  color: t.textPrimary,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        Text(
                                          chip.email,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style:
                                              (chip.display != chip.email
                                                      ? textTheme.bodySmall
                                                      : textTheme.bodyMedium)
                                                  ?.copyWith(
                                                    color: chip.isValid
                                                        ? t.textSecondary
                                                        : t.danger,
                                                  ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: Icon(
                                      LucideIcons.x,
                                      size: IconSize.sm,
                                      color: t.textTertiary,
                                    ),
                                    tooltip: 'Alıcıyı kaldır',
                                    onPressed: () {
                                      _removeChip(chip);
                                      setSheetState(() {});
                                    },
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
            ),
          );
        },
      ),
    );
  }

  /// Boş alanda geri tuşu son çipi siler. `TextField` bu tuşu boş metinde
  /// tükettiği için düğümün kendi `onKeyEvent`'i üzerinden yakalanır.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.backspace ||
        _input.text.isNotEmpty ||
        _chips.isEmpty) {
      return KeyEventResult.ignored;
    }
    _removeChip(_chips.last);
    return KeyEventResult.handled;
  }

  void _onEditingComplete() {
    if (_input.text.trim().isEmpty) {
      FocusScope.of(context).nextFocus();
      return;
    }
    _commitFragment();
  }

  /// Çipe dokunma: kişi ayrıntılarını açar. Klavye önce kapatılır ki sheet
  /// klavyeyle yarışmasın (bkz. `_handleAttachSource`'taki aynı gerekçe);
  /// yazılmakta olan geçerli bir parça varsa odak kaybıyla çipe döner
  /// (bkz. [_onFocusChange]).
  Future<void> _showDetails(EmailAddress address) {
    FocusScope.of(context).unfocus();
    return showRecipientDetails(
      context,
      address: address,
      accountId: widget.accountId,
    );
  }

  // ---- Öneriler ----

  /// Hızlı Kişiler şeridi: en son kullanılan kişiler (bkz.
  /// `AppDatabase.watchContacts` sırası), bu alanda zaten çip olanlar hariç —
  /// otomatik tamamlamadaki [_optionsFor] ile aynı kural, böylece bir kişi
  /// aynı alana iki kez eklenemez.
  List<EmailAddress> _quickContacts(List<ContactRow> contacts) {
    final taken = {for (final c in _chips) c.email.toLowerCase()};
    return contacts
        .where((c) => !taken.contains(c.email.toLowerCase()))
        .take(_maxQuickContacts)
        .map(
          (c) => EmailAddress(
            email: c.email,
            name: c.name.isEmpty ? null : c.name,
          ),
        )
        .toList();
  }

  Iterable<ContactRow> _optionsFor(String text, List<ContactRow> contacts) {
    final fragment = foldForSearch(text.trim());
    if (fragment.isEmpty) return const [];
    final taken = {for (final c in _chips) c.email.toLowerCase()};
    return contacts
        .where(
          (c) =>
              !taken.contains(c.email.toLowerCase()) &&
              (foldForSearch(c.email).contains(fragment) ||
                  (c.name.isNotEmpty &&
                      foldForSearch(c.name).contains(fragment))),
        )
        .take(_maxSuggestions);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final id = widget.accountId;
    final contacts = id == null
        ? const <ContactRow>[]
        : ref.watch(contactsForAccountProvider(id)).value ??
              const <ContactRow>[];

    final field = RawAutocomplete<ContactRow>(
      textEditingController: _input,
      focusNode: widget.focusNode,
      // Seçim metni değiştirmez: çip eklenir, parça temizlenir.
      displayStringForOption: (_) => '',
      optionsBuilder: (value) => _optionsFor(value.text, contacts),
      onSelected: (contact) {
        _input.clear();
        _addChips([
          EmailAddress(
            email: contact.email,
            name: contact.name.isEmpty ? null : contact.name,
          ),
        ]);
      },
      optionsViewBuilder: (context, onSelected, options) => _ContactOptionsList(
        options: options,
        onSelected: onSelected,
        width: _fieldWidth,
      ),
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return LayoutBuilder(
          builder: (context, constraints) {
            _fieldWidth = constraints.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: focusNode.requestFocus,
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: t.divider)),
                ),
                padding: const EdgeInsets.only(left: Space.lg, right: Space.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 52,
                      height: 48,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.label,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: t.textTertiary,
                            fontSize: 12 * AppText.scale,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: Space.sm),
                        // Alan en fazla iki satırdır: sığmayan çipler "+N" olur
                        // (bkz. `RecipientChipPlanner`). Sığmayan çip, satırda
                        // yeterli yer kalıyorsa alt satıra atlamak yerine
                        // kısaltılıp yan yana konur.
                        child: LayoutBuilder(
                          builder: (context, box) {
                            final plan = RecipientChipPlanner.plan(
                              naturalWidths: [
                                for (final chip in _chips)
                                  _RecipientChip.naturalWidth(context, chip),
                              ],
                              available: box.maxWidth,
                              spacing: Space.xs,
                              minShrunkWidth: _RecipientChip.minShrunkWidth,
                              plusWidth: (hidden) =>
                                  _RecipientOverflowChip.width(context, hidden),
                              inputMinWidth: _inputMinWidth,
                            );
                            // Gizlenenler EN ESKİ alıcılardır; son eklenen hep
                            // görünür kalır.
                            final hiddenChips = _chips
                                .take(plan.hidden)
                                .toList();
                            final shown = _chips.skip(plan.hidden).toList();
                            return Wrap(
                              spacing: Space.xs,
                              runSpacing: Space.xs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (hiddenChips.isNotEmpty)
                                  _RecipientOverflowChip(
                                    hidden: hiddenChips.length,
                                    hasInvalid: hiddenChips.any(
                                      (a) => !a.isValid,
                                    ),
                                    onTap: _showAllRecipients,
                                  ),
                                // Çip döngüde yakalanır: geri çağrılar dokunma
                                // anında `_chips[i]`ye değil, çizildiği andaki
                                // çipe bağlı kalır (aynı karede silinse bile
                                // aralık hatası olmaz).
                                for (final (i, chip) in shown.indexed)
                                  _RecipientChip(
                                    address: chip,
                                    maxWidth: plan.maxWidths[i],
                                    onTap: () => _showDetails(chip),
                                    onRemove: () => _removeChip(chip),
                                  ),
                                IntrinsicWidth(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      minWidth: _inputMinWidth,
                                    ),
                                    child: TextField(
                                      controller: controller,
                                      focusNode: focusNode,
                                      autofocus: widget.autofocus,
                                      keyboardType: TextInputType.emailAddress,
                                      textInputAction: TextInputAction.next,
                                      onChanged: _onInputChanged,
                                      onEditingComplete: _onEditingComplete,
                                      style: _RecipientChip._textStyle(context),
                                      decoration: _RecipientField
                                          ._fieldDecoration
                                          .copyWith(
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  vertical: Space.sm,
                                                ),
                                          ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    if (widget.trailing != null)
                      SizedBox(height: 48, child: widget.trailing),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        field,
        // Alan odaktayken ve yazılan parça boşken Hızlı Kişiler; yazmaya
        // başlanınca yerini otomatik tamamlama alır. Seçilen kişi bu alana
        // (Kime/Bilgi/Gizli — hangisi odaktaysa) çip olarak eklenir.
        ListenableBuilder(
          listenable: Listenable.merge([_input, widget.focusNode]),
          builder: (context, _) {
            final show = widget.focusNode.hasFocus && _input.text.isEmpty;
            final quick = show
                ? _quickContacts(contacts)
                : const <EmailAddress>[];
            return AnimatedSize(
              duration: context.motion(Motion.base),
              curve: Motion.standard,
              alignment: Alignment.topCenter,
              child: quick.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : QuickContactsStrip(
                      contacts: quick,
                      onSelected: (address) => _addChips([address]),
                    ),
            );
          },
        ),
      ],
    );
  }
}

/// Sığmayan alıcıların yerine geçen "+N" çipi: alıcı çipiyle aynı kabuk
/// (zemin, yarıçap), ama avatarsız ve vurgulu metinle — bir alıcı değil,
/// "hepsini göster" kontrolü olduğu anlaşılır. Gizlenenler arasında geçersiz
/// adres varsa alıcı çipiyle aynı kırmızı çerçeve çıkar.
class _RecipientOverflowChip extends StatelessWidget {
  const _RecipientOverflowChip({
    required this.hidden,
    required this.hasInvalid,
    required this.onTap,
  });

  final int hidden;
  final bool hasInvalid;
  final VoidCallback onTap;

  static const double _padding = Space.sm;

  static TextStyle? _style(BuildContext context) => Theme.of(
    context,
  ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600);

  /// "+N"in gerçek genişliği (yerleşim planı için).
  static double width(BuildContext context, int hidden) {
    final painter = TextPainter(
      text: TextSpan(text: '+$hidden', style: _style(context)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return (w + _padding * 2).ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      button: true,
      label: '$hidden alıcı daha, tümünü göster',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: t.isDark ? t.surfaceElevated : t.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
          side: hasInvalid ? BorderSide(color: t.danger) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: _padding,
              vertical: Space.xs + 2,
            ),
            child: Text(
              '+$hidden',
              style: _style(context)?.copyWith(color: t.accent),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tamamlanmış alıcı: küçük avatar + görünen ad. Geçersiz adres kırmızı
/// çerçeveyle işaretlenir (gönderimde zaten reddedilir).
///
/// İki AYRI dokunma hedefi vardır ve birbirini gölgelemez: gövde (avatar + ad)
/// kişi ayrıntılarını açar ([onTap]), sağdaki "x" alıcıyı siler
/// ([onRemove]). Çipin tamamı tek bir `InkWell` olsaydı "x"e dokunmak da
/// ayrıntıları açardı; bu yüzden "x" gövdenin dışındadır.
class _RecipientChip extends StatelessWidget {
  const _RecipientChip({
    required this.address,
    required this.maxWidth,
    required this.onTap,
    required this.onRemove,
  });

  final EmailAddress address;

  /// Bu çipin alabileceği en geniş ölçü (bkz. `RecipientChipLayout`); adı
  /// buna sığmazsa "…" ile kısalır.
  final double maxWidth;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  static const double _avatarSize = 20;
  static const double _removeIconSize = 14;

  /// Tek başına duran çipin en fazla ne kadar genişleyeceği.
  static const double _maxNaturalWidth = 260;

  /// Kalan yer bundan azsa çip daraltılıp yan yana konmaz, alt satıra geçer:
  /// avatar + "x" + birkaç harf bundan az yerde okunmaz.
  static const double minShrunkWidth = 110;

  /// Metin DIŞINDA kalan yatay ölçü: gövde iç boşluğu + avatar + avatar-ad
  /// boşluğu + "x" alanı + sağ boşluk (bkz. `build`).
  static const double _chrome =
      Space.xs * 2 +
      _avatarSize +
      Space.sm +
      (_removeIconSize + Space.xs * 2) +
      Space.xs;

  static TextStyle? _textStyle(BuildContext context) => Theme.of(
    context,
  ).textTheme.bodyMedium?.copyWith(fontSize: 14.5 * AppText.scale);

  /// Çipin kısaltılmadan istediği genişlik: adın gerçek ölçüsü + [_chrome].
  static double naturalWidth(BuildContext context, EmailAddress address) {
    final painter = TextPainter(
      text: TextSpan(text: address.display, style: _textStyle(context)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return (_chrome + width).ceilToDouble().clamp(0, _maxNaturalWidth);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final valid = address.isValid;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Material(
        color: t.isDark ? t.surfaceElevated : t.surfaceDeep,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
          side: valid ? BorderSide.none : BorderSide(color: t.danger),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Semantics(
                button: true,
                label: '${address.display}, ${address.email}',
                hint: 'Kişi ayrıntılarını aç',
                excludeSemantics: true,
                onTap: onTap,
                child: InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.all(Space.xs),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        BrandAvatar(
                          name: address.name,
                          email: address.email,
                          size: _avatarSize,
                        ),
                        const SizedBox(width: Space.sm),
                        Flexible(
                          child: Text(
                            address.display,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _textStyle(context)?.copyWith(
                              color: valid ? t.textPrimary : t.danger,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              button: true,
              label: 'Alıcıyı kaldır',
              excludeSemantics: true,
              onTap: onRemove,
              child: InkResponse(
                onTap: onRemove,
                radius: 14,
                child: Padding(
                  padding: const EdgeInsets.all(Space.xs),
                  child: Icon(
                    LucideIcons.x,
                    size: _removeIconSize,
                    color: t.textTertiary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: Space.xs),
          ],
        ),
      ),
    );
  }
}

/// Otomatik tamamlama açılır listesi — alanın altında tam genişlikte;
/// her satırda küçük avatar, başlık (ad ya da adres) ve alt satırda adres.
/// Satırlar bilerek sıkı tutulur: liste yazma alanının üstüne biner ve
/// büyük satırlar iki-üç öneride ekranın yarısını kaplıyordu.
class _ContactOptionsList extends StatelessWidget {
  const _ContactOptionsList({
    required this.options,
    required this.onSelected,
    required this.width,
  });

  final Iterable<ContactRow> options;
  final AutocompleteOnSelected<ContactRow> onSelected;
  final double width;

  static const double _avatarSize = 28;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final list = options.toList();
    return Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        color: t.surfaceElevated,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: 336,
            minWidth: width,
            maxWidth: width,
          ),
          child: ListView.separated(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: list.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              thickness: 1,
              indent: Space.lg + _avatarSize + Space.md,
              color: t.divider,
            ),
            itemBuilder: (context, index) {
              final contact = list[index];
              final hasName = contact.name.isNotEmpty;
              return InkWell(
                onTap: () => onSelected(contact),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.lg,
                    vertical: Space.sm,
                  ),
                  child: Row(
                    children: [
                      BrandAvatar(
                        name: contact.name,
                        email: contact.email,
                        size: _avatarSize,
                      ),
                      const SizedBox(width: Space.md),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hasName ? contact.name : contact.email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.bodyMedium.copyWith(
                                color: t.textPrimary,
                              ),
                            ),
                            if (hasName)
                              Text(
                                contact.email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.labelMedium.copyWith(
                                  color: t.textTertiary,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Kalıcı depoya kopyalanmayı bekleyen bir ek — bkz. `_addAttachmentPath`.
class _PendingAttachment {
  const _PendingAttachment(this.path, this.name);
  final String path;
  final String name;
}

/// [path]'ten (yerel dosya) `AttachmentPreviewScreen`in beklediği
/// `AttachmentRow`u üretir. Bu ek henüz gönderilmediği için sunucuda karşılığı
/// yok — `id`/`messageId` yalnızca birer yer tutucu, önizleme ekranı bu
/// alanları kullanmaz (bkz. `localPathOf`: indirme adımı atlanır, dosya zaten
/// yerelde).
AttachmentRow _localAttachmentRow(String path) {
  final fileName = AttachmentFiles.cleanPickedName(
    path.split(RegExp(r'[\\/]')).last,
    sourcePath: path,
  );
  int size;
  try {
    size = File(path).lengthSync();
  } on FileSystemException {
    size = 0;
  }
  return AttachmentRow(
    id: 0,
    messageId: 0,
    partId: '',
    fileName: fileName,
    mimeType: '',
    sizeBytes: size,
    isInline: false,
    localPath: path,
    isOutgoing: true,
  );
}

/// Eklenen dosyaların düzenli kart ızgarası — dosya sayısı/ad uzunluğu ne
/// olursa olsun tutarlı kart boyutu/dolgusu (bkz. `_AttachmentCardShell`) ve
/// ekran genişliğine göre kendiliğinden satır kıran `Wrap` (taşma yok, dış
/// yazma ekranı kaydırmasını bozmaz — burada kendi iç kaydırması YOK).
class _AttachmentList extends StatelessWidget {
  const _AttachmentList({
    required this.paths,
    required this.onRemove,
    this.pending = const [],
    this.justUploaded = const {},
  });

  final List<String> paths;
  final List<_PendingAttachment> pending;
  final Set<String> justUploaded;
  final ValueChanged<String> onRemove;

  /// Dokunulan karttan başlayarak TÜM hazır ekler arasında kaydırılabilir
  /// galeriyi açar (bkz. `AttachmentPreviewScreen`, mail detay ekranındaki
  /// aynı mantık) — `localPathOf` verildiği için indirme adımı atlanır.
  void _openPreview(BuildContext context, int index) {
    context.pushScreen(
      AttachmentPreviewScreen(
        attachments: [for (final path in paths) _localAttachmentRow(path)],
        initialIndex: index,
        localPathOf: (attachment) => attachment.localPath,
      ),
      transitionStyle: KaydetTransitionStyle.horizontalPush,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.divider)),
      ),
      child: Wrap(
        spacing: Space.sm,
        runSpacing: Space.sm,
        children: [
          for (final item in pending) _PendingAttachmentCard(name: item.name),
          for (var i = 0; i < paths.length; i++)
            _AttachmentCard(
              path: paths[i],
              justUploaded: justUploaded.contains(paths[i]),
              onTap: () => _openPreview(context, i),
              onRemove: () => onRemove(paths[i]),
            ),
        ],
      ),
    );
  }
}

/// Tüm ek kartlarının ortak kabuğu — dolgu, kenar yuvarlaklığı, kenarlık ve
/// minimum yükseklik TEK yerden gelir, böylece yükleniyor/hazır durumları
/// arasında görünüm asla kaymaz. `maxWidth`, uzun dosya adının kartı
/// şişirmesini engeller (bkz. `_AttachmentCard`daki `Flexible`+ellipsis) ve
/// `Wrap` ile birlikte ekran genişliğine göre kendiliğinden 1/2/3 sütuna
/// bölünmesini sağlar.
class _AttachmentCardShell extends StatelessWidget {
  const _AttachmentCardShell({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final content = Container(
      constraints: const BoxConstraints(maxWidth: 260, minHeight: 44),
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
      child: child,
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: content,
    );
  }
}

class _PendingAttachmentCard extends StatelessWidget {
  const _PendingAttachmentCard({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return _AttachmentCardShell(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: IconSize.lg,
            height: IconSize.lg,
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: t.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Hazır (kalıcı depoya kopyalanmış) bir ekin kartı — tamamı tıklanabilir
/// (önizlemeyi açar), sağdaki "x" ile kaldırılır. Uzantı + boyut altyazısı
/// (bkz. `AttachmentType.label`/`formatBytes`) mail detay ekranındaki
/// `_AttachmentChip` ile aynı bilgiyi verir.
class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    required this.path,
    required this.justUploaded,
    required this.onTap,
    required this.onRemove,
  });

  final String path;
  final bool justUploaded;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final fileName = AttachmentFiles.cleanPickedName(
      path.split(RegExp(r'[\\/]')).last,
      sourcePath: path,
    );
    int size;
    try {
      size = File(path).lengthSync();
    } on FileSystemException {
      size = 0;
    }
    return _AttachmentCardShell(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          justUploaded
              ? Icon(
                  LucideIcons.checkCircle,
                  size: IconSize.lg,
                  color: t.success,
                )
              : AttachmentTypeIcon(fileName: fileName, size: IconSize.lg),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                Text(
                  '${AttachmentType.label(fileName)} · ${formatBytes(size)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.x, size: IconSize.sm),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            visualDensity: VisualDensity.compact,
            tooltip: 'Kaldır',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Seçilen etiketlerin gövde üzerindeki özeti.
class _LabelsRow extends ConsumerWidget {
  const _LabelsRow({required this.names});

  final Set<String> names;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];
    return Container(
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.sm,
        Space.lg,
        Space.sm,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.divider)),
      ),
      child: Wrap(
        spacing: Space.sm,
        runSpacing: Space.sm,
        children: [
          for (final name in names)
            LabelChip(
              name: name,
              toneIndex:
                  labels
                      .where((l) => l.name == name)
                      .map((l) => l.toneIndex)
                      .firstOrNull ??
                  0,
            ),
        ],
      ),
    );
  }
}

enum _AttachSource { gallery, camera, files }

/// Ek kaynağı seçim popup'ı — eM Client'taki gibi galeri/kamera/(+dosya),
/// artık tam ekranı kaplayan bir alttan panel değil, düğmenin hemen altına
/// açılan küçük bir menü (bkz. bellek: popup'lar modallara tercih edilir).
class _AttachMenuButton extends StatelessWidget {
  const _AttachMenuButton({
    required this.icon,
    required this.tooltip,
    required this.includeFiles,
    required this.onSelected,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final bool includeFiles;
  final ValueChanged<_AttachSource> onSelected;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      animated: true,
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(LucideIcons.images),
          onPressed: () => onSelected(_AttachSource.gallery),
          child: const Text('Galeri'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(LucideIcons.camera),
          onPressed: () => onSelected(_AttachSource.camera),
          child: const Text('Kamera'),
        ),
        if (includeFiles)
          MenuItemButton(
            leadingIcon: const Icon(LucideIcons.folder),
            onPressed: () => onSelected(_AttachSource.files),
            child: const Text('Dosyalar'),
          ),
      ],
      builder: (context, controller, child) => IconButton(
        icon: Icon(icon, size: IconSize.md),
        tooltip: tooltip,
        color: color,
        onPressed: () {
          // Menü klavyenin hemen üstünde/yakınında açılır; klavye açık
          // kalırsa seçenekleri örter. Düğmeye dokunur dokunmaz kapatılır
          // (bkz. `_handleAttachSource`'daki aynı gerekçe).
          FocusScope.of(context).unfocus();
          controller.isOpen ? controller.close() : controller.open();
        },
      ),
    );
  }
}

/// İmza seçim popup'ı — seçilen imza imleç konumuna eklenir (bkz.
/// `_ComposeScreenState._insertSignature`). Yazma açılışında zaten
/// varsayılan imza otomatik eklendiği için bu, kullanıcının isteğe bağlı
/// olarak başka bir imza eklemesi/değiştirmesi içindir.
class _SignatureMenuButton extends StatelessWidget {
  const _SignatureMenuButton({
    required this.signatures,
    required this.onSelected,
    required this.onNew,
    this.color,
  });

  final List<SignatureRow> signatures;
  final ValueChanged<SignatureRow> onSelected;

  /// "+ Yeni imza": doğrudan imza oluşturma penceresini açar.
  final VoidCallback onNew;
  final Color? color;

  static const double _menuWidth = 264;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    // Varsayılan imza en üstte; geri kalanın göreli sırası korunur.
    final ordered = [
      ...signatures.where((s) => s.isDefault),
      ...signatures.where((s) => !s.isDefault),
    ];
    return MenuAnchor(
      animated: true,
      menuChildren: [
        if (ordered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.lg,
              vertical: Space.md,
            ),
            child: Text(
              'Henüz imza eklenmedi',
              style: textTheme.bodyMedium?.copyWith(color: t.textTertiary),
            ),
          ),
        for (final signature in ordered)
          MenuItemButton(
            leadingIcon: Icon(
              signature.imageType == 'remote'
                  ? LucideIcons.image
                  : LucideIcons.penLine,
            ),
            onPressed: () => onSelected(signature),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: _menuWidth,
                maxWidth: _menuWidth,
                minHeight: Dimens.touchTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            signature.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (signature.isDefault) ...[
                          const SizedBox(width: Space.sm),
                          Text(
                            'Varsayılan',
                            style: textTheme.labelSmall?.copyWith(
                              color: t.textTertiary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      signature.body.trim().isNotEmpty
                          ? signature.body.trim()
                          : (signature.imageType == 'remote'
                              ? '🌐 Uzak görsel imza'
                              : ''),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: t.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Divider(height: 1, color: t.divider),
        // Yönetim ekranı yeniden yazılmaz: mevcut Ayarlar → İmzalar açılır.
        // Yazma ekranı yığında kalır (taslak/gövde korunur); imza listesi
        // `signaturesForAccountProvider` akışı olduğu için dönüşte kendiliğinden
        // güncellenir.
        MenuItemButton(
          leadingIcon: const Icon(LucideIcons.plus),
          onPressed: onNew,
          child: const Text('Yeni imza'),
        ),
      ],
      builder: (context, controller, child) => IconButton(
        icon: Icon(LucideIcons.penLine, size: IconSize.md, color: color),
        tooltip: 'İmza ekle',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Yazı boyutu / satır aralığı seçeneklerinin etiketleri. Değerler ve
/// px/çarpan karşılıkları [ComposeFontSize]/[ComposeLineSpacing] modelindedir;
/// arayüz yalnızca bu modelin seçeneklerini sunar.
const _fontSizeLabels = <(String, ComposeFontSize)>[
  ('Küçük', ComposeFontSize.small),
  ('Normal', ComposeFontSize.normal),
  ('Büyük', ComposeFontSize.large),
  ('Çok büyük', ComposeFontSize.extraLarge),
];

const _lineSpacingLabels = <(String, ComposeLineSpacing)>[
  ('Normal', ComposeLineSpacing.normal),
  ('Sıkı (1,0)', ComposeLineSpacing.tight),
  ('1,5 satır', ComposeLineSpacing.oneAndHalf),
  ('Çift satır', ComposeLineSpacing.doubled),
];

/// Araç çubuğunun biçimlendirme moduna geçmiş hâli (bkz. `_ComposeToolbar`)
/// — "Biçimlendir" ikonuna dokunulduğunda ayrı bir satır AÇILMAZ, araç
/// çubuğunun kendi içeriği bununla yer değiştirir (in-place toolbar swap).
/// Soldaki geri oku aynı yuvada kalıp yalnızca kapatmaya yarar; sağındaki
/// seçenekler yatayda kaydırılır.
///
/// Kalın/eğik/altı çizili anında uygulanır; metin/vurgu rengi, yazı boyutu
/// ve satır aralığı için alt sayfalar açılır (eM Client'taki gibi).
class _FormatToolbarRow extends StatelessWidget {
  const _FormatToolbarRow({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final QuillController controller;
  final VoidCallback onClose;

  bool _isActive(Attribute attribute) =>
      controller.getSelectionStyle().attributes.containsKey(attribute.key);

  String? _currentString(String key) {
    final value = controller.getSelectionStyle().attributes[key]?.value;
    return value is String ? value : null;
  }

  ComposeFontSize _currentFontSize() =>
      ComposeFontSize.fromAttribute(
        controller.getSelectionStyle().attributes[Attribute.size.key]?.value,
      ) ??
      ComposeFontSize.normal;

  ComposeLineSpacing _currentLineSpacing() =>
      ComposeLineSpacing.fromAttribute(
        controller
            .getSelectionStyle()
            .attributes[Attribute.lineHeight.key]
            ?.value,
      ) ??
      ComposeLineSpacing.normal;

  void _toggle(Attribute attribute) {
    final active = _isActive(attribute);
    controller.formatSelection(
      active ? Attribute.clone(attribute, null) : attribute,
    );
  }

  void _applyColor(bool background, String? value) {
    final attribute = background ? Attribute.background : Attribute.color;
    controller.formatSelection(Attribute.clone(attribute, value));
  }

  /// Yalnızca kontrollü seviyeler yazılır (bkz. [ComposeFontSize]); serbest
  /// bir `font-size` metni editörü çökertir. Biçim yalnızca seçili metne (ya
  /// da imleçten sonra yazılacak metne) uygulanır — ekranı ölçeklemez.
  void _applySize(ComposeFontSize size) => controller.formatSelection(
    Attribute.clone(Attribute.size, size.attributeValue),
  );

  void _applyLineSpacing(ComposeLineSpacing spacing) => controller
      .formatSelection(LineHeightAttribute(lineHeight: spacing.attributeValue));

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Seçime bağlı göstergeler (renk, boyut, satır aralığı) `AnimatedBuilder`
    // İÇİNDE okunur: bu widget yalnızca üst öğe yeniden kurulunca yenilenir,
    // imleç boşken seçilen biçim ise yalnızca denetleyiciyi bildirir.
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Row(
        children: [
          IconButton(
            icon: Icon(
              LucideIcons.arrowLeft,
              size: IconSize.md,
              color: t.textSecondary,
            ),
            tooltip: 'Biçimlendirmeyi kapat',
            onPressed: onClose,
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FormatButton(
                    icon: LucideIcons.bold,
                    label: 'Kalın',
                    isActive: _isActive(Attribute.bold),
                    onTap: () => _toggle(Attribute.bold),
                  ),
                  _FormatButton(
                    icon: LucideIcons.italic,
                    label: 'Eğik',
                    isActive: _isActive(Attribute.italic),
                    onTap: () => _toggle(Attribute.italic),
                  ),
                  _FormatButton(
                    icon: LucideIcons.underline,
                    label: 'Altı çizili',
                    isActive: _isActive(Attribute.underline),
                    onTap: () => _toggle(Attribute.underline),
                  ),
                  _FormatDivider(color: t.divider),
                  _ColorMenuButton(
                    icon: LucideIcons.palette,
                    label: 'Metin rengi',
                    title: 'METİN RENGİ',
                    colors: ComposePalette.text,
                    current: _currentString(Attribute.color.key),
                    onSelected: (value) => _applyColor(false, value),
                  ),
                  _ColorMenuButton(
                    icon: LucideIcons.paintBucket,
                    label: 'Vurgu rengi',
                    title: 'VURGU RENGİ',
                    colors: ComposePalette.highlight,
                    current: _currentString(Attribute.background.key),
                    onSelected: (value) => _applyColor(true, value),
                  ),
                  _OptionMenuButton<ComposeFontSize>(
                    icon: LucideIcons.caseSensitive,
                    label: 'Yazı boyutu',
                    isActive: _currentFontSize() != ComposeFontSize.normal,
                    options: _fontSizeLabels,
                    current: _currentFontSize(),
                    onSelected: _applySize,
                  ),
                  _OptionMenuButton<ComposeLineSpacing>(
                    icon: LucideIcons.alignVerticalSpaceAround,
                    label: 'Satır aralığı',
                    isActive:
                        _currentLineSpacing() != ComposeLineSpacing.normal,
                    options: _lineSpacingLabels,
                    current: _currentLineSpacing(),
                    onSelected: _applyLineSpacing,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FormatDivider extends StatelessWidget {
  const _FormatDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Space.xs),
    child: SizedBox(height: 24, child: VerticalDivider(color: color, width: 1)),
  );
}

class _FormatButton extends StatelessWidget {
  const _FormatButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.tintColor,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  /// Renk/vurgu düğmelerinde seçili rengin kendisiyle boyanan ikon.
  final Color? tintColor;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(right: Space.xs),
      child: Material(
        color: isActive ? t.accentSubtle : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: onTap,
          child: Semantics(
            button: true,
            selected: isActive,
            label: label,
            child: Padding(
              padding: const EdgeInsets.all(Space.sm),
              child: Icon(
                icon,
                size: IconSize.md,
                color: tintColor ?? (isActive ? t.accent : t.textSecondary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Metin/vurgu rengi seçim sayfası — bir renk paleti + "Yok" seçeneği.
/// Metin/vurgu rengi popup'ı — bir renk paleti + "Yok" seçeneği, düğmenin
/// hemen altına açılır (bkz. bellek: popup'lar modallara tercih edilir).
class _ColorMenuButton extends StatelessWidget {
  const _ColorMenuButton({
    required this.icon,
    required this.label,
    required this.title,
    required this.colors,
    required this.current,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final String title;
  final List<String> colors;
  final String? current;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      animated: true,
      menuChildren: [
        Padding(
          padding: const EdgeInsets.all(Space.sm),
          child: SizedBox(
            width: 220,
            child: Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                _SwatchButton(
                  isSelected: current == null,
                  onSelected: () => onSelected(null),
                  child: Icon(
                    LucideIcons.slash,
                    size: 16,
                    color: context.tokens.textTertiary,
                  ),
                ),
                for (final hex in colors)
                  _SwatchButton(
                    color: ComposePalette.tryParse(hex),
                    isSelected: current?.toLowerCase() == hex.toLowerCase(),
                    onSelected: () => onSelected(hex),
                  ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, child) => _FormatButton(
        icon: icon,
        label: label,
        isActive: current != null,
        tintColor: current != null ? ComposePalette.tryParse(current!) : null,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Tek bir renk karesi — seçilince kendini kapsayan popup'ı kapatır
/// ([MenuController.maybeOf] ile, ayrı bir controller taşımaya gerek kalmaz).
class _SwatchButton extends StatelessWidget {
  const _SwatchButton({
    required this.isSelected,
    required this.onSelected,
    this.color,
    this.child,
  });

  final Color? color;
  final bool isSelected;
  final VoidCallback onSelected;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: color ?? t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
        side: BorderSide(
          color: isSelected ? t.accent : t.divider,
          width: isSelected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: () {
          onSelected();
          MenuController.maybeOf(context)?.close();
        },
        borderRadius: BorderRadius.circular(Radii.sm),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Center(
            child: isSelected && color != null
                ? Icon(
                    LucideIcons.check,
                    size: 16,
                    color: ComposePalette.onSwatch(color!),
                  )
                : child,
          ),
        ),
      ),
    );
  }
}

/// Yazı boyutu / satır aralığı gibi tek seçimli, adlandırılmış listeler için
/// ortak popup — bir düğmenin altına açılan radyo listesi.
class _OptionMenuButton<T> extends StatelessWidget {
  const _OptionMenuButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.options,
    required this.current,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final bool isActive;
  final List<(String, T)> options;
  final T current;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      animated: true,
      menuChildren: [
        for (final (optionLabel, value) in options)
          RadioMenuButton<T>(
            value: value,
            groupValue: current,
            onChanged: (_) => onSelected(value),
            child: Text(optionLabel),
          ),
      ],
      builder: (context, controller, child) => _FormatButton(
        icon: icon,
        label: label,
        isActive: isActive,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// "..." düğmesinin açtığı sabit menü — Gmail'deki gibi doğrudan etiket
/// listesine değil, önce bu menüye düşer. Şimdilik tek girişi var ama
/// ilerideki eklemeler (ör. yapay zekâ, araç çubuğu ayarları) için hazır.
///
/// Etiketler tam ekran bir alttan panel yerine kendi alt menüsünde: her
/// onay kutusu dokunulduğu anda uygulanır (`closeOnActivate: false`, bkz.
/// `mail_list_screen.dart`daki filtre menüsüyle aynı desen) — ayrı bir
/// "Bitti" onayına gerek yok, kullanıcı istediği kadar etiketi art arda
/// açıp kapatabilir.
class _ComposeMoreMenu extends ConsumerWidget {
  const _ComposeMoreMenu({
    required this.selectedLabels,
    required this.onToggleLabel,
  });

  final Set<String> selectedLabels;
  final ValueChanged<String> onToggleLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.tokens;
    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];

    return MenuAnchor(
      animated: true,
      menuChildren: [
        SubmenuButton(
          animated: true,
          leadingIcon: const Icon(LucideIcons.tag),
          menuChildren: [
            if (labels.isEmpty)
              const MenuItemButton(
                onPressed: null,
                child: Text('Henüz etiket yok'),
              )
            else
              for (final label in labels)
                CheckboxMenuButton(
                  value: selectedLabels.contains(label.name),
                  onChanged: (_) => onToggleLabel(label.name),
                  closeOnActivate: false,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.tag,
                        size: IconSize.sm,
                        color: t.toneAt(label.toneIndex).foreground,
                      ),
                      const SizedBox(width: Space.sm),
                      Text(label.name),
                    ],
                  ),
                ),
          ],
          child: const Text('Etiketler'),
        ),
      ],
      builder: (context, controller, child) => IconButton(
        icon: Icon(
          LucideIcons.moreHorizontal,
          size: IconSize.md,
          color: selectedLabels.isNotEmpty ? t.accent : t.textSecondary,
        ),
        tooltip: 'Diğer',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

class _ComposeToolbar extends StatelessWidget {
  const _ComposeToolbar({
    required this.listening,
    required this.selectedLabels,
    required this.isFormatBarOpen,
    required this.quillController,
    required this.signatures,
    required this.onMic,
    required this.onAttachSource,
    required this.onToggleLabel,
    required this.onToggleFormat,
    required this.onSignatureSelected,
    required this.onNewSignature,
    required this.onOpenTemplates,
  });

  final bool listening;
  final Set<String> selectedLabels;
  final bool isFormatBarOpen;
  final QuillController quillController;
  final List<SignatureRow> signatures;
  final VoidCallback onMic;
  final ValueChanged<_AttachSource> onAttachSource;
  final ValueChanged<String> onToggleLabel;
  final VoidCallback onToggleFormat;
  final ValueChanged<SignatureRow> onSignatureSelected;
  final VoidCallback onNewSignature;
  final VoidCallback onOpenTemplates;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: t.surfaceElevated,
        border: Border(top: BorderSide(color: t.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.xs,
            vertical: Space.xs,
          ),
          // "Biçimlendir" ikonuna dokunmak ayrı bir satır AÇMAZ — araç
          // çubuğunun kendisi aynı yerde biçim seçenekleriyle yer değiştirir
          // (in-place toolbar swap). İki satır da aynı yükseklikte
          // (`Dimens.touchTarget`) olduğu için geçişte satır zıplamaz.
          child: SizedBox(
            height: Dimens.touchTarget,
            child: ClipRect(
              child: AnimatedSwitcher(
                duration: context.motion(Motion.base),
                switchInCurve: Motion.standard,
                switchOutCurve: Motion.standard,
                transitionBuilder: (child, animation) => SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.06, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: isFormatBarOpen
                    ? _FormatToolbarRow(
                        key: const ValueKey('format'),
                        controller: quillController,
                        onClose: onToggleFormat,
                      )
                    : _MainToolbarRow(
                        key: const ValueKey('main'),
                        listening: listening,
                        selectedLabels: selectedLabels,
                        signatures: signatures,
                        onMic: onMic,
                        onAttachSource: onAttachSource,
                        onToggleLabel: onToggleLabel,
                        onToggleFormat: onToggleFormat,
                        onSignatureSelected: onSignatureSelected,
                        onNewSignature: onNewSignature,
                        onOpenTemplates: onOpenTemplates,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MainToolbarRow extends StatelessWidget {
  const _MainToolbarRow({
    super.key,
    required this.listening,
    required this.selectedLabels,
    required this.signatures,
    required this.onMic,
    required this.onAttachSource,
    required this.onToggleLabel,
    required this.onToggleFormat,
    required this.onSignatureSelected,
    required this.onNewSignature,
    required this.onOpenTemplates,
  });

  final bool listening;
  final Set<String> selectedLabels;
  final List<SignatureRow> signatures;
  final VoidCallback onMic;
  final ValueChanged<_AttachSource> onAttachSource;
  final ValueChanged<String> onToggleLabel;
  final VoidCallback onToggleFormat;
  final ValueChanged<SignatureRow> onSignatureSelected;
  final VoidCallback onNewSignature;
  final VoidCallback onOpenTemplates;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      children: [
        _AttachMenuButton(
          icon: LucideIcons.paperclip,
          tooltip: 'Dosya ekle',
          includeFiles: true,
          onSelected: onAttachSource,
          color: t.textSecondary,
        ),
        _AttachMenuButton(
          icon: LucideIcons.image,
          tooltip: 'Görsel ekle',
          includeFiles: false,
          onSelected: onAttachSource,
          color: t.textSecondary,
        ),
        IconButton(
          icon: Icon(
            LucideIcons.removeFormatting,
            size: IconSize.md,
            color: t.textSecondary,
          ),
          tooltip: 'Biçimlendir',
          onPressed: onToggleFormat,
        ),
        // Yazma açılışında zaten varsayılan imza otomatik eklendiği için bu,
        // kullanıcının isteğe bağlı olarak başka bir imza eklemesi/
        // değiştirmesi içindir (bkz. `_ComposeScreenState._insertSignature`).
        _SignatureMenuButton(
          signatures: signatures,
          onSelected: onSignatureSelected,
          onNew: onNewSignature,
          color: t.textSecondary,
        ),
        IconButton(
          icon: Icon(
            LucideIcons.layoutTemplate,
            size: IconSize.md,
            color: t.textSecondary,
          ),
          tooltip: 'Hazır Şablonlar',
          onPressed: onOpenTemplates,
        ),
        _ComposeMoreMenu(
          selectedLabels: selectedLabels,
          onToggleLabel: onToggleLabel,
        ),
        IconButton(
          icon: Icon(
            LucideIcons.mic,
            size: IconSize.md,
            color: listening ? t.danger : t.textSecondary,
          ),
          tooltip: listening ? 'Dinleniyor…' : 'Sesli yaz',
          onPressed: onMic,
        ),
        const Spacer(),
        if (listening)
          Padding(
            padding: const EdgeInsets.only(right: Space.md),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: t.danger,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: Space.sm),
                Text(
                  'Kaydediliyor',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: t.danger),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
