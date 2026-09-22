import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart' show Delta;
import 'package:flutter_quill_delta_from_html/flutter_quill_delta_from_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../../app/providers.dart';
import '../../../core/date_format.dart';
import '../../../core/turkish.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/use_cases/text_extraction.dart';
import '../../../domain/use_cases/threading.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_notice.dart';
import '../../core/widgets/kaydet_widgets.dart';

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
  const ComposeSendQueued(this.messageId);

  final int messageId;
}

/// İleti yazma ekranı.
class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({
    super.key,
    this.draftId,
    this.replyToId,
    this.mode = ComposeMode.newMessage,
    this.initialTo,
  });

  /// Var olan taslağı düzenlemek için.
  final int? draftId;

  /// Yanıtlanan/iletilen ileti.
  final int? replyToId;

  final ComposeMode mode;

  /// Kişiler sekmesinden "yaz" ile açıldığında Kime alanına önceden
  /// doldurulacak adres (bkz. `ContactsScreen`).
  final String? initialTo;

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
  final _toFocus = FocusNode();
  final _ccFocus = FocusNode();
  final _bccFocus = FocusNode();
  bool _toFocusRequested = false;

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
  final Set<String> _labels = {};

  Timer? _autosave;

  @override
  void initState() {
    super.initState();
    _draftId = widget.draftId;
    _replyToMessageId = widget.replyToId;
    // `_prefill` taslak/yanıt ise gerçek sahibiyle değiştirecek (aşağı bkz.);
    // yeni bir iletide bu, ilk karede gösterilecek tek değerdir.
    _fromAccountId = ref.read(accountIdProvider);
    _quill = QuillController.basic();
    _quill.addListener(_onChanged);
    for (final controller in [_to, _cc, _bcc, _subject]) {
      controller.addListener(_onChanged);
    }
    scheduleMicrotask(_prefill);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Autofocus tek başına klavyeyi tetiklemiyor: `PageTransitionsTheme`
    // (bkz. `AppTheme._build`) Android'de fade-through geçişi kullanıyor ve
    // odak, geçiş animasyonu daha bitmeden platforma iletiliyor — bu yüzden
    // sistem klavyeyi görmezden geliyor. Çözüm: geçiş bitene kadar bekleyip
    // odağı ve klavyeyi elle iste.
    if (!_toFocusRequested && widget.mode == ComposeMode.newMessage) {
      _toFocusRequested = true;
      final animation = ModalRoute.of(context)?.animation;
      if (animation == null || animation.isCompleted) {
        _focusToFieldAndShowKeyboard();
      } else {
        void listener(AnimationStatus status) {
          if (status != AnimationStatus.completed) return;
          animation.removeStatusListener(listener);
          _focusToFieldAndShowKeyboard();
        }

        animation.addStatusListener(listener);
      }
    }
  }

  void _focusToFieldAndShowKeyboard() {
    if (!mounted) return;
    FocusScope.of(context).requestFocus(_toFocus);
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  @override
  void dispose() {
    _autosave?.cancel();
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
        _attachments.addAll(
          existing
              .where((a) => a.isOutgoing && a.localPath != null)
              .map((a) => a.localPath!),
        );
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
        final selfEmail = ref.read(accountByIdProvider(row.accountId))?.email;
        _applyReply(row, body, selfEmail);
      }
    } else {
      if (widget.initialTo != null) _to.text = widget.initialTo!;
      _setPlainBody(_defaultSignatureBody);
    }

    if (!mounted) return;
    setState(() => _initialised = true);
  }

  /// Kaydedilmiş gövdeyi düzenleyiciye yükler.
  ///
  /// HTML varsa biçimlendirmeyi korumak için önce o denenir; ayrıştırma
  /// başarısız olursa (ör. beklenmeyen bir etiket) düz metne düşülür —
  /// metin hiçbir zaman kaybolmaz, yalnızca biçim kaybolabilir.
  void _loadBody(String? html, String? plainText) {
    if (html != null && html.trim().isNotEmpty) {
      try {
        final delta = HtmlToDelta().convert(html);
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
    final signature = _defaultSignatureBody;

    final quotedSource =
        body?.plainText ??
        (body?.html != null ? TextExtraction.htmlToPlain(body!.html!) : '');
    final quoteHeader =
        '\n\n${formatDetailDate(row.dateUtc)} tarihinde '
        '${from.display} <${from.email}> yazdı:\n';

    switch (widget.mode) {
      case ComposeMode.reply:
        _to.text = from.formatted;
        _subject.text = _prefixSubject(row.subject, 'Yanıt');
        _setPlainBody(
          '$signature$quoteHeader${TextExtraction.quote(quotedSource)}',
        );

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
        _setPlainBody(
          '$signature$quoteHeader${TextExtraction.quote(quotedSource)}',
        );

      case ComposeMode.forward:
        _subject.text = _prefixSubject(row.subject, 'İlet');
        _setPlainBody(
          '$signature\n\n'
          '---------- İletilen ileti ----------\n'
          'Kimden: ${from.formatted}\n'
          'Tarih: ${formatDetailDate(row.dateUtc)}\n'
          'Konu: ${row.subject}\n'
          'Kime: ${to.map((a) => a.formatted).join(', ')}\n\n'
          '$quotedSource',
        );

      case ComposeMode.newMessage:
        _setPlainBody(signature);
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

  /// Zengin metni gönderim/kaydetme için HTML'e çevirir; içerik boşsa
  /// `null` döner (düz taslak olarak kalır).
  String? get _bodyHtml {
    if (_bodyPlainText.isEmpty) return null;
    return _deltaToHtml(_quill.document.toDelta());
  }

  bool get _hasContent =>
      _to.text.trim().isNotEmpty ||
      _cc.text.trim().isNotEmpty ||
      _bcc.text.trim().isNotEmpty ||
      _subject.text.trim().isNotEmpty ||
      _attachments.isNotEmpty ||
      _bodyDiffersFromSignature;

  bool get _bodyDiffersFromSignature {
    final signature = _defaultSignatureBody;
    return _bodyPlainText != signature.trim() && _bodyPlainText.isNotEmpty;
  }

  /// [_fromAccountId] için varsayılan imza — GENEL aktif hesabınkini değil,
  /// bu iletinin gönderileceği hesabınkini kullanır (bkz. [_fromAccountId]).
  String get _defaultSignatureBody {
    final accountId = _fromAccountId;
    if (accountId == null) return '';
    return ref.read(defaultSignatureForAccountProvider(accountId))?.body ??
        '';
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

    if (_subject.text.trim().isEmpty) {
      final proceed = await _confirmNoSubject();
      if (proceed != true) return;
    }

    setState(() => _sending = true);
    _autosave?.cancel();

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
    );
    if (!mounted) return;

    // Negatif kimlik ileti hiç kaydedilemedi demektir (klasörler henüz
    // eşitlenmemiş). Ekran kapatılıp "gönderiliyor" denirse ileti sessizce
    // kaybolurdu; kullanıcı yazdıklarıyla ekranda kalır ve yeniden dener.
    if (messageId < 0) {
      setState(() => _sending = false);
      _showError('İleti gönderilemedi. Lütfen birkaç saniye sonra tekrar deneyin.');
      return;
    }

    // Kuyruk hemen işlenmeye çalışılır; başarısız olursa arka planda devam.
    unawaited(repository.processQueue(accountId));

    // Sonucu (gönderildi / gönderilemedi) kullanıcıya ekranı açan taraf
    // bildirir — bu ekran kapanınca ağaçtan çıkar (bkz. `SendFeedback`).
    Navigator.of(context).pop<ComposeOutcome>(ComposeSendQueued(messageId));
  }

  void _showError(String message) {
    KaydetNotice.show(
      Overlay.of(context, rootOverlay: true),
      message: message,
    );
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
    Navigator.of(context).pop<ComposeOutcome>(
      draftId == null ? null : ComposeDraftSaved(draftId),
    );
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
        await _pickFromImagePicker(ImageSource.gallery);
      case _AttachSource.camera:
        await _pickFromImagePicker(ImageSource.camera);
      case _AttachSource.files:
        await _pickFilesFromDisk();
    }
  }

  /// Seçili metnin (varsa) yerine, yoksa imleç konumuna metni ekler — sesli
  /// yazmayla aynı yerleştirme deseni (bkz. `_startListening`).
  void _insertSignature(String body) {
    if (body.isEmpty) return;
    final selection = _quill.selection;
    final index = selection.isValid
        ? selection.start
        : _quill.document.length - 1;
    final length = selection.isValid ? selection.end - selection.start : 0;
    _quill.replaceText(
      index,
      length,
      body,
      TextSelection.collapsed(offset: index + body.length),
    );
  }

  Future<void> _pickFromImagePicker(ImageSource source) async {
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: source, imageQuality: 90);
    } on Object catch (_) {
      if (!mounted) return;
      _showError(
        source == ImageSource.camera
            ? 'Kameraya erişilemedi.'
            : 'Galeriye erişilemedi.',
      );
      return;
    }
    if (picked == null) return;
    _addAttachmentPath(picked.path);
  }

  Future<void> _pickFilesFromDisk() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    for (final file in files) {
      final path = file.path;
      if (path != null) _addAttachmentPath(path);
    }
  }

  void _addAttachmentPath(String path) {
    if (_attachments.contains(path)) return;
    setState(() => _attachments.add(path));
    _onChanged();
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
                  : () =>
                        controller.isOpen ? controller.close() : controller.open(),
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
                            color: t.textPrimary,
                            fontWeight: FontWeight.w600,
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
                                  color: t.textSecondary,
                                  fontSize: 13 * AppText.scale,
                                ),
                              ),
                            ),
                            if (allAccounts.length > 1)
                              Icon(
                                Icons.keyboard_arrow_down,
                                color: t.textSecondary,
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
                        color: t.accent,
                      ),
                    )
                  : Icon(LucideIcons.sendHorizontal, color: t.textPrimary),
              tooltip: 'Gönder',
              onPressed: _sending ? null : _send,
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
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  _RecipientField(
                    label: 'Kime',
                    controller: _to,
                    focusNode: _toFocus,
                    accountId: fromAccountId,
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
                  if (_attachments.isNotEmpty)
                    _AttachmentList(
                      paths: _attachments,
                      onRemove: (path) {
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
                        controller: _quill,
                        focusNode: _bodyFocus,
                        config: const QuillEditorConfig(
                          scrollable: false,
                          expands: false,
                          padding: EdgeInsets.zero,
                          placeholder: 'İletinizi buraya yazın…',
                          textCapitalization: TextCapitalization.sentences,
                          minHeight: 220,
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
                  _insertSignature(signature.body),
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

/// Quill Delta'yı gönderim için HTML'e çevirir.
///
/// KAYDET kalın/italik/altı çizili + metin/vurgu rengi + yazı boyutu ve
/// belge geneli satır aralığını destekler; bu yüzden tam bir Delta→HTML
/// kütüphanesi yerine bu dar kapsamlı, bağımsız dönüştürücü yeterlidir.
/// Aynı biçim [HtmlToDelta] tarafından geri okunabilir (bkz. `_loadBody`),
/// böylece taslak yeniden açıldığında biçimlendirme korunur. Satır aralığı
/// tek bir belge genelindeki değerdir (ilk bulunan `line-height`
/// kullanılır) — Quill'de gerçek satır bazlı ayrıştırma bu basit
/// dönüştürücünün kapsamı dışında bırakıldı.
String _deltaToHtml(Delta delta) {
  final buffer = StringBuffer();
  double? lineHeight;
  for (final op in delta.toList()) {
    final attrs = op.attributes ?? const <String, dynamic>{};
    final rawLineHeight = attrs['line-height'];
    if (lineHeight == null && rawLineHeight is num) {
      lineHeight = rawLineHeight.toDouble();
    }

    final data = op.data;
    if (data is! String) continue; // Gömülü içerik (ör. görsel) desteklenmiyor.
    final lines = data.split('\n');
    for (var i = 0; i < lines.length; i++) {
      var segment = _escapeHtml(lines[i]);
      if (segment.isNotEmpty) {
        final styles = <String>[];
        final color = attrs['color'];
        final background = attrs['background'];
        final size = attrs['size'];
        if (color is String) styles.add('color:$color');
        if (background is String) styles.add('background-color:$background');
        if (size is String) styles.add('font-size:$size');
        if (styles.isNotEmpty) {
          segment = '<span style="${styles.join(';')}">$segment</span>';
        }
        if (attrs['bold'] == true) segment = '<b>$segment</b>';
        if (attrs['italic'] == true) segment = '<i>$segment</i>';
        if (attrs['underline'] == true) segment = '<u>$segment</u>';
        buffer.write(segment);
      }
      if (i != lines.length - 1) buffer.write('<br>');
    }
  }

  final body = buffer.toString();
  if (lineHeight == null) return body;
  return '<div style="line-height:$lineHeight">$body</div>';
}

String _escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

class _RecipientField extends StatelessWidget {
  const _RecipientField({
    required this.label,
    required this.controller,
    this.trailing,
    this.focusNode,
    this.isSubject = false,
    this.accountId,
  });

  final String label;
  final TextEditingController controller;
  final Widget? trailing;
  final FocusNode? focusNode;
  final bool isSubject;

  /// Kişi otomatik tamamlaması hangi hesabın kişi defterinden gelsin — bkz.
  /// `ComposeScreen._fromAccountId`. Yalnızca e-posta alanlarında (Kime/
  /// Bilgi/Gizli) kullanılır, `isSubject: true` iken yok sayılır.
  final int? accountId;

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
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: t.textTertiary),
            ),
          ),
          Expanded(child: isSubject ? _plainField(context) : _emailField()),
          ?trailing,
        ],
      ),
    );
  }

  Widget _plainField(BuildContext context) => TextField(
    controller: controller,
    focusNode: focusNode,
    keyboardType: TextInputType.text,
    textCapitalization: TextCapitalization.sentences,
    style: Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    decoration: _fieldDecoration,
  );

  /// Kime/Bilgi/Gizli — kişi defterinden otomatik tamamlama. Alan birden
  /// çok virgülle ayrılmış adres tutabildiği için `Autocomplete`'in seçim
  /// davranışı elle yönetilir: yalnızca metnin SON parçası (son virgülden
  /// sonrası) eşleştirilir/değiştirilir, öncesindeki tamamlanmış adreslere
  /// dokunulmaz (bkz. [_ContactAutocomplete._lastFragment]).
  Widget _emailField() => _ContactAutocomplete(
    controller: controller,
    focusNode: focusNode!,
    decoration: _fieldDecoration,
    accountId: accountId,
  );
}

/// [_RecipientField]'ın Kime/Bilgi/Gizli alanlarını sarar: kullanıcı
/// yazarken seçili "Gönderen" hesabın kişi defterindeki eşleşenleri küçük bir
/// açılır listede önerir. Liste zaten en son kullanılana göre sıralı
/// geldiğinden (bkz. `AppDatabase.watchContacts`), tek bir harf yazıldığı
/// anda en üstte "en son/en çok kullanılan" eşleşme çıkar — ayrı bir "Son
/// Kullanılanlar" görünümüne gerek bırakmadan aynı amaca hizmet eder.
class _ContactAutocomplete extends ConsumerWidget {
  const _ContactAutocomplete({
    required this.controller,
    required this.focusNode,
    required this.decoration,
    this.accountId,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final InputDecoration decoration;
  final int? accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = accountId;
    final contacts = id == null
        ? const <ContactRow>[]
        : ref.watch(contactsForAccountProvider(id)).value ??
              const <ContactRow>[];

    return Autocomplete<ContactRow>(
      textEditingController: controller,
      focusNode: focusNode,
      displayStringForOption: (contact) => EmailAddress(
        email: contact.email,
        name: contact.name.isEmpty ? null : contact.name,
      ).formatted,
      optionsBuilder: (value) => _optionsFor(value.text, contacts),
      onSelected: (contact) => _applySuggestion(controller, contact),
      optionsViewBuilder: (context, onSelected, options) =>
          _ContactOptionsList(options: options, onSelected: onSelected),
      fieldViewBuilder:
          (context, fieldController, fieldFocusNode, onFieldSubmitted) =>
              TextField(
                controller: fieldController,
                focusNode: fieldFocusNode,
                keyboardType: TextInputType.emailAddress,
                style: Theme.of(context).textTheme.bodyMedium,
                decoration: decoration,
              ),
    );
  }

  static Iterable<ContactRow> _optionsFor(
    String text,
    List<ContactRow> contacts,
  ) {
    final fragment = foldForSearch(_lastFragment(text));
    if (fragment.isEmpty) return const [];
    return contacts
        .where(
          (c) =>
              foldForSearch(c.email).contains(fragment) ||
              (c.name.isNotEmpty && foldForSearch(c.name).contains(fragment)),
        )
        .take(5);
  }

  static void _applySuggestion(
    TextEditingController controller,
    ContactRow contact,
  ) {
    final text = controller.text;
    final sepIndex = _lastSeparatorIndex(text);
    final prefix = sepIndex == -1 ? '' : '${text.substring(0, sepIndex + 1)} ';
    final formatted = EmailAddress(
      email: contact.email,
      name: contact.name.isEmpty ? null : contact.name,
    ).formatted;
    final newText = '$prefix$formatted, ';
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }

  /// "ali@x.com, meh" -> "meh" (son virgül/noktalı virgülden sonrası).
  static String _lastFragment(String text) {
    final idx = _lastSeparatorIndex(text);
    return (idx == -1 ? text : text.substring(idx + 1)).trim();
  }

  static int _lastSeparatorIndex(String text) {
    for (var i = text.length - 1; i >= 0; i--) {
      if (text[i] == ',' || text[i] == ';') return i;
    }
    return -1;
  }
}

/// Otomatik tamamlama açılır listesi — her kişi avatarı + ad + e-posta.
class _ContactOptionsList extends StatelessWidget {
  const _ContactOptionsList({required this.options, required this.onSelected});

  final Iterable<ContactRow> options;
  final AutocompleteOnSelected<ContactRow> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final list = options.toList();
    return Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        color: t.surfaceElevated,
        borderRadius: BorderRadius.circular(Radii.md),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240, maxWidth: 360),
          child: ListView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: list.length,
            itemBuilder: (context, index) {
              final contact = list[index];
              return ListTile(
                dense: true,
                leading: BrandAvatar(
                  name: contact.name,
                  email: contact.email,
                  size: 28,
                ),
                title: Text(
                  contact.name.isEmpty ? contact.email : contact.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: contact.name.isEmpty
                    ? null
                    : Text(
                        contact.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                onTap: () => onSelected(contact),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AttachmentList extends StatelessWidget {
  const _AttachmentList({required this.paths, required this.onRemove});

  final List<String> paths;
  final ValueChanged<String> onRemove;

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
          for (final path in paths)
            Chip(
              avatar: Icon(LucideIcons.paperclip, size: 14, color: t.accent),
              label: Text(
                path.split(RegExp(r'[\\/]')).last,
                style: Theme.of(context).textTheme.labelSmall,
              ),
              deleteIcon: const Icon(LucideIcons.x, size: 14),
              onDeleted: () => onRemove(path),
              backgroundColor: t.surface,
              side: BorderSide(color: t.divider),
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
    this.color,
  });

  final List<SignatureRow> signatures;
  final ValueChanged<SignatureRow> onSelected;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      animated: true,
      menuChildren: [
        for (final signature in signatures)
          MenuItemButton(
            leadingIcon: const Icon(LucideIcons.penLine),
            onPressed: () => onSelected(signature),
            child: Text(signature.name),
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

const _textColors = <String>[
  '#EF4444', // kırmızı
  '#F97316', // turuncu
  '#F5C518', // altın
  '#22C55E', // yeşil
  '#14B8A6', // turkuaz
  '#3B82F6', // mavi
  '#8B5CF6', // mor
  '#EC4899', // pembe
  '#9CA3AF', // gri
];

const _highlightColors = <String>[
  '#FEF08A', // sarı
  '#FED7AA', // turuncu
  '#BBF7D0', // yeşil
  '#BFDBFE', // mavi
  '#E9D5FF', // mor
  '#FBCFE8', // pembe
];

const _fontSizes = <(String, String?)>[
  ('Küçük', '12px'),
  ('Normal', null),
  ('Büyük', '18px'),
  ('Çok büyük', '24px'),
];

const _lineHeights = <(String, double?)>[
  ('Normal', null),
  ('Sıkı (1.15)', 1.15),
  ('1,5 satır', 1.5),
  ('Çift satır', 2),
];

Color _parseHexColor(String hex) =>
    Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));

Color _contrastingIconColor(Color background) =>
    background.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

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

  double? _currentLineHeight() {
    final value = controller
        .getSelectionStyle()
        .attributes[Attribute.lineHeight.key]
        ?.value;
    return value is num ? value.toDouble() : null;
  }

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

  void _applySize(String? value) =>
      controller.formatSelection(Attribute.clone(Attribute.size, value));

  void _applyLineHeight(double? value) =>
      controller.formatSelection(LineHeightAttribute(lineHeight: value));

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textColor = _currentString(Attribute.color.key);
    final backgroundColor = _currentString(Attribute.background.key);
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
                    colors: _textColors,
                    current: textColor,
                    onSelected: (value) => _applyColor(false, value),
                  ),
                  _ColorMenuButton(
                    icon: LucideIcons.paintBucket,
                    label: 'Vurgu rengi',
                    title: 'VURGU RENGİ',
                    colors: _highlightColors,
                    current: backgroundColor,
                    onSelected: (value) => _applyColor(true, value),
                  ),
                  _OptionMenuButton<String?>(
                    icon: LucideIcons.caseSensitive,
                    label: 'Yazı boyutu',
                    isActive: _currentString(Attribute.size.key) != null,
                    options: _fontSizes,
                    current: _currentString(Attribute.size.key),
                    onSelected: _applySize,
                  ),
                  _OptionMenuButton<double?>(
                    icon: LucideIcons.alignVerticalSpaceAround,
                    label: 'Satır aralığı',
                    isActive: _isActive(Attribute.lineHeight),
                    options: _lineHeights,
                    current: _currentLineHeight(),
                    onSelected: _applyLineHeight,
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
                    color: _parseHexColor(hex),
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
        tintColor: current != null ? _parseHexColor(current!) : null,
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
                    color: _contrastingIconColor(color!),
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
  });

  final bool listening;
  final Set<String> selectedLabels;
  final List<SignatureRow> signatures;
  final VoidCallback onMic;
  final ValueChanged<_AttachSource> onAttachSource;
  final ValueChanged<String> onToggleLabel;
  final VoidCallback onToggleFormat;
  final ValueChanged<SignatureRow> onSignatureSelected;

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
        if (signatures.isNotEmpty)
          _SignatureMenuButton(
            signatures: signatures,
            onSelected: onSignatureSelected,
            color: t.textSecondary,
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
