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
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/use_cases/text_extraction.dart';
import '../../../domain/use_cases/threading.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Yazma ekranının açılış biçimi.
enum ComposeMode { newMessage, reply, replyAll, forward }

/// İleti yazma ekranı.
class ComposeScreen extends ConsumerStatefulWidget {
  const ComposeScreen({
    super.key,
    this.draftId,
    this.replyToId,
    this.mode = ComposeMode.newMessage,
  });

  /// Var olan taslağı düzenlemek için.
  final int? draftId;

  /// Yanıtlanan/iletilen ileti.
  final int? replyToId;

  final ComposeMode mode;

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
  bool _toFocusRequested = false;

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
  String? _inReplyTo;
  String? _references;
  final List<String> _attachments = [];
  final Set<String> _labels = {};

  Timer? _autosave;

  @override
  void initState() {
    super.initState();
    _draftId = widget.draftId;
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

  Future<void> _prefill() async {
    final account = ref.read(activeAccountProvider).value;

    if (widget.draftId != null) {
      final row = await ref.read(messageProvider(widget.draftId!).future);
      final body = await ref.read(messageBodyProvider(widget.draftId!).future);
      if (row != null) {
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
        _inReplyTo = row.inReplyTo;
        _references = row.referencesRaw;
        _showCcBcc = _cc.text.isNotEmpty || _bcc.text.isNotEmpty;
        final existing = await ref.read(
          attachmentsProvider(widget.draftId!).future,
        );
        _attachments.addAll(
          existing
              .where((a) => a.isOutgoing && a.localPath != null)
              .map((a) => a.localPath!),
        );
        _labels.addAll(_decodeLabels(row.labelsJson));
      }
    } else if (widget.replyToId != null) {
      final row = await ref.read(messageProvider(widget.replyToId!).future);
      final body = await ref.read(
        messageBodyProvider(widget.replyToId!).future,
      );
      if (row != null) {
        _applyReply(row, body, account?.email);
      }
    } else {
      _setPlainBody(account?.signature ?? '');
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
    final account = ref.read(activeAccountProvider).value;
    final signature = account?.signature ?? '';

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
    final signature = ref.read(activeAccountProvider).value?.signature ?? '';
    return _bodyPlainText != signature.trim() && _bodyPlainText.isNotEmpty;
  }

  Future<void> _persistDraft() async {
    final accountId = ref.read(accountIdProvider);
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
          replyToMessageId: widget.replyToId,
          inReplyTo: _inReplyTo,
          references: _references,
        );
    if (id > 0) _draftId = id;
  }

  Future<void> _send() async {
    final accountId = ref.read(accountIdProvider);
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

    await ref
        .read(mailRepositoryProvider)
        .queueSend(
          accountId: accountId,
          draftId: _draftId,
          to: _to.text,
          cc: _cc.text,
          bcc: _bcc.text,
          subject: _subject.text,
          body: _bodyPlainText,
          html: _bodyHtml,
          attachmentPaths: _attachments,
          replyToMessageId: widget.replyToId,
          inReplyTo: _inReplyTo,
          references: _references,
        );

    // Kuyruk hemen işlenmeye çalışılır; başarısız olursa arka planda devam.
    unawaited(ref.read(mailRepositoryProvider).processQueue(accountId));

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('İleti gönderiliyor…')));
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
  /// kaydedilir ve kaydedilen taslağın id'si `Navigator.pop` sonucu olarak
  /// çağıran ekrana döndürülür — o ekran altta "İleti Taslaklara
  /// kaydedildi" bildirimini, yanında bir "Sil" eylemiyle gösterir (bkz.
  /// `showDraftSavedSnackBar`). İçerik yoksa kaydetmeden `null` döner.
  Future<int?> _saveDraftOnExit() async {
    if (!_hasContent) return null;
    _autosave?.cancel();
    await _persistDraft();
    return _draftId;
  }

  /// Kaynak seçimi: Galeri / Kamera (+ Dosya isteğe bağlı) gösterir ve
  /// seçileni eklentiler listesine ekler.
  Future<void> _showAttachSheet({required bool includeFiles}) async {
    // Klavye açıkken galeri/kamera/dosya seçici gibi harici bir sistem
    // ekranı açılırken pencere odağı Flutter'dan uzaklaşıyor; hâlâ bağlı
    // bir metin girişi varsa bu geçiş sırasında yazılım klavyesi (özellikle
    // Samsung klavyesi) anlık olarak yeniden tetikleniyor. Seçiciyi açmadan
    // önce odağı kaldırmak bu titremeyi engeller.
    FocusScope.of(context).unfocus();
    final source = await showModalBottomSheet<_AttachSource>(
      context: context,
      showDragHandle: true,
      builder: (_) => _AttachSourceSheet(includeFiles: includeFiles),
    );
    if (source == null) return;

    switch (source) {
      case _AttachSource.gallery:
        await _pickFromImagePicker(ImageSource.gallery);
      case _AttachSource.camera:
        await _pickFromImagePicker(ImageSource.camera);
      case _AttachSource.files:
        await _pickFilesFromDisk();
    }
  }

  Future<void> _pickAttachment() => _showAttachSheet(includeFiles: true);

  Future<void> _pickImage() => _showAttachSheet(includeFiles: false);

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

  /// Etiket seçimi: taslak henüz yoksa önce kaydedilir, sonra fark alınan
  /// etiketler ilgili iletiye uygulanır/kaldırılır.
  Future<void> _pickLabels() async {
    final labels = ref.read(labelsProvider).value ?? const <LabelRow>[];
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      builder: (_) =>
          _LabelPickerSheet(labels: labels, initiallySelected: _labels),
    );
    if (picked == null) return;

    final added = picked.difference(_labels);
    final removed = _labels.difference(picked);
    if (added.isEmpty && removed.isEmpty) return;

    setState(() {
      _labels
        ..clear()
        ..addAll(picked);
    });
    _onChanged();

    if (_draftId == null || _draftId! <= 0) {
      await _persistDraft();
    }
    final draftId = _draftId;
    if (draftId == null || draftId <= 0) return;

    final repository = ref.read(mailRepositoryProvider);
    for (final name in added) {
      await repository.setLabel(
        messageIds: [draftId],
        labelName: name,
        add: true,
      );
    }
    for (final name in removed) {
      await repository.setLabel(
        messageIds: [draftId],
        labelName: name,
        add: false,
      );
    }
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final draftId = await _saveDraftOnExit();
        if (context.mounted) Navigator.of(context).pop(draftId);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(LucideIcons.x),
            tooltip: 'Kapat',
            onPressed: () async {
              final draftId = await _saveDraftOnExit();
              if (context.mounted) Navigator.of(context).pop(draftId);
            },
          ),
          title: Text(_titleForMode()),
          actions: [
            IconButton(
              icon: const Icon(LucideIcons.paperclip),
              tooltip: 'Dosya ekle',
              onPressed: _pickAttachment,
            ),
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
                  : const Icon(LucideIcons.sendHorizontal),
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
                children: [
                  _RecipientField(
                    label: 'Kime',
                    controller: _to,
                    focusNode: _toFocus,
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
                    _RecipientField(label: 'Bilgi', controller: _cc),
                    _RecipientField(label: 'Gizli', controller: _bcc),
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
            if (_showFormatBar) _FormatBar(controller: _quill),
            _ComposeToolbar(
              listening: _listening,
              hasLabels: _labels.isNotEmpty,
              isFormatBarOpen: _showFormatBar,
              onMic: _toggleMic,
              onAttach: _pickAttachment,
              onImage: _pickImage,
              onLabels: _pickLabels,
              onToggleFormat: () =>
                  setState(() => _showFormatBar = !_showFormatBar),
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
  });

  final String label;
  final TextEditingController controller;
  final Widget? trailing;
  final FocusNode? focusNode;
  final bool isSubject;

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
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              keyboardType: isSubject
                  ? TextInputType.text
                  : TextInputType.emailAddress,
              textCapitalization: isSubject
                  ? TextCapitalization.sentences
                  : TextCapitalization.none,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: isSubject ? FontWeight.w600 : FontWeight.w400,
              ),
              decoration: const InputDecoration(
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: Space.md),
                isDense: true,
              ),
            ),
          ),
          ?trailing,
        ],
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

/// Ek kaynağı seçim sayfası — eM Client'taki gibi galeri/kamera/dosya.
class _AttachSourceSheet extends StatelessWidget {
  const _AttachSourceSheet({required this.includeFiles});

  final bool includeFiles;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionHeader(includeFiles ? 'EKLE' : 'GÖRSEL EKLE'),
          ListTile(
            leading: Icon(LucideIcons.images, color: t.textSecondary),
            title: const Text('Galeri'),
            onTap: () => Navigator.of(context).pop(_AttachSource.gallery),
          ),
          ListTile(
            leading: Icon(LucideIcons.camera, color: t.textSecondary),
            title: const Text('Kamera'),
            onTap: () => Navigator.of(context).pop(_AttachSource.camera),
          ),
          if (includeFiles)
            ListTile(
              leading: Icon(LucideIcons.folder, color: t.textSecondary),
              title: const Text('Dosyalar'),
              onTap: () => Navigator.of(context).pop(_AttachSource.files),
            ),
          const SizedBox(height: Space.sm),
        ],
      ),
    );
  }
}

/// Çoklu seçimli etiket seçici — sadece var olan hesap etiketleri arasından.
class _LabelPickerSheet extends StatefulWidget {
  const _LabelPickerSheet({
    required this.labels,
    required this.initiallySelected,
  });

  final List<LabelRow> labels;
  final Set<String> initiallySelected;

  @override
  State<_LabelPickerSheet> createState() => _LabelPickerSheetState();
}

class _LabelPickerSheetState extends State<_LabelPickerSheet> {
  late final Set<String> _selected = {...widget.initiallySelected};

  void _toggle(String name) => setState(() {
    if (!_selected.remove(name)) _selected.add(name);
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SectionHeader('ETİKETLER'),
              if (widget.labels.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(Space.xxl),
                  child: Text(
                    'Henüz etiket yok. Ayarlar\'dan ekleyebilirsiniz.',
                  ),
                ),
              for (final label in widget.labels)
                _LabelPickerRow(
                  label: label,
                  isSelected: _selected.contains(label.name),
                  onTap: () => _toggle(label.name),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  Space.md,
                  Space.lg,
                  Space.sm,
                ),
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: const Text('Bitti'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Etiket satırı — Gmail'in etiket menüsündeki gibi renkli anahat ikonu +
/// ad; seçiliyken sağda onay işareti. Onay kutusu yerine tüm satır
/// dokunulabilir, daha büyük ve daha rahat bir hedef verir.
class _LabelPickerRow extends StatelessWidget {
  const _LabelPickerRow({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final LabelRow label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tone = t.toneAt(label.toneIndex);
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: Dimens.touchTarget),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        color: isSelected ? t.accentSubtle : Colors.transparent,
        child: Row(
          children: [
            Icon(LucideIcons.tag, size: IconSize.md, color: tone.foreground),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                label.name,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (isSelected)
              Icon(LucideIcons.check, size: IconSize.sm, color: t.accent),
          ],
        ),
      ),
    );
  }
}

/// Bir seçim sayfasında "vazgeçildi" (`null`) ile "açıkça temizlendi"
/// arasındaki farkı işaretlemek için kullanılan tekil değer. İkisi de
/// `Navigator.pop` ile `null` dönerse, sayfayı dokunmadan kapatmak yanlışça
/// mevcut rengi/boyutu sıfırlar.
const Object _clearChoice = Object();

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

/// "A" düğmesiyle açılıp kapanan biçimlendirme çubuğu.
///
/// Kalın/eğik/altı çizili anında uygulanır; metin/vurgu rengi, yazı boyutu
/// ve satır aralığı için alt sayfalar açılır (eM Client'taki gibi).
class _FormatBar extends StatelessWidget {
  const _FormatBar({required this.controller});

  final QuillController controller;

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

  Future<void> _pickColor(
    BuildContext context, {
    required bool background,
  }) async {
    final attribute = background ? Attribute.background : Attribute.color;
    final result = await showModalBottomSheet<Object?>(
      context: context,
      showDragHandle: true,
      builder: (_) => _ColorPickerSheet(
        title: background ? 'VURGU RENGİ' : 'METİN RENGİ',
        colors: background ? _highlightColors : _textColors,
        current: _currentString(attribute.key),
      ),
    );
    if (result == null) return;
    final value = identical(result, _clearChoice) ? null : result as String;
    controller.formatSelection(Attribute.clone(attribute, value));
  }

  Future<void> _pickSize(BuildContext context) async {
    final result = await showModalBottomSheet<Object?>(
      context: context,
      showDragHandle: true,
      builder: (_) => _OptionPickerSheet<String?>(
        title: 'YAZI BOYUTU',
        options: _fontSizes,
        current: _currentString(Attribute.size.key),
      ),
    );
    if (result == null) return;
    final value = identical(result, _clearChoice) ? null : result as String;
    controller.formatSelection(Attribute.clone(Attribute.size, value));
  }

  Future<void> _pickLineHeight(BuildContext context) async {
    final result = await showModalBottomSheet<Object?>(
      context: context,
      showDragHandle: true,
      builder: (_) => _OptionPickerSheet<double?>(
        title: 'SATIR ARALIĞI',
        options: _lineHeights,
        current: _currentLineHeight(),
      ),
    );
    if (result == null) return;
    final value = identical(result, _clearChoice) ? null : result as double;
    controller.formatSelection(LineHeightAttribute(lineHeight: value));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final textColor = _currentString(Attribute.color.key);
    final backgroundColor = _currentString(Attribute.background.key);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Container(
        decoration: BoxDecoration(
          color: t.surface,
          border: Border(top: BorderSide(color: t.divider)),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.xs,
        ),
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
              _FormatButton(
                icon: LucideIcons.palette,
                label: 'Metin rengi',
                isActive: textColor != null,
                tintColor: textColor != null ? _parseHexColor(textColor) : null,
                onTap: () => _pickColor(context, background: false),
              ),
              _FormatButton(
                icon: LucideIcons.paintBucket,
                label: 'Vurgu rengi',
                isActive: backgroundColor != null,
                tintColor: backgroundColor != null
                    ? _parseHexColor(backgroundColor)
                    : null,
                onTap: () => _pickColor(context, background: true),
              ),
              _FormatButton(
                icon: LucideIcons.caseSensitive,
                label: 'Yazı boyutu',
                isActive: _currentString(Attribute.size.key) != null,
                onTap: () => _pickSize(context),
              ),
              _FormatButton(
                icon: LucideIcons.alignVerticalSpaceAround,
                label: 'Satır aralığı',
                isActive: _isActive(Attribute.lineHeight),
                onTap: () => _pickLineHeight(context),
              ),
            ],
          ),
        ),
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
class _ColorPickerSheet extends StatelessWidget {
  const _ColorPickerSheet({
    required this.title,
    required this.colors,
    required this.current,
  });

  final String title;
  final List<String> colors;
  final String? current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionHeader(title),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.lg,
              vertical: Space.sm,
            ),
            child: Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                _SwatchButton(
                  isSelected: current == null,
                  onTap: () => Navigator.of(context).pop<Object?>(_clearChoice),
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
                    onTap: () => Navigator.of(context).pop<Object?>(hex),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Space.sm),
        ],
      ),
    );
  }
}

class _SwatchButton extends StatelessWidget {
  const _SwatchButton({
    required this.isSelected,
    required this.onTap,
    this.color,
    this.child,
  });

  final Color? color;
  final bool isSelected;
  final VoidCallback onTap;
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
        onTap: onTap,
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
/// ortak seçim sayfası.
class _OptionPickerSheet<T> extends StatelessWidget {
  const _OptionPickerSheet({
    required this.title,
    required this.options,
    required this.current,
  });

  final String title;
  final List<(String, T)> options;
  final T current;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionHeader(title),
          for (final (label, value) in options)
            ListTile(
              title: Text(label),
              trailing: current == value
                  ? Icon(LucideIcons.check, color: t.accent)
                  : null,
              onTap: () =>
                  Navigator.of(context).pop<Object?>(value ?? _clearChoice),
            ),
          const SizedBox(height: Space.sm),
        ],
      ),
    );
  }
}

enum _MoreMenuAction { labels }

/// "..." düğmesinin açtığı sabit menü — Gmail'deki gibi doğrudan etiket
/// listesine değil, önce bu menüye düşer. Şimdilik tek girişi var ama
/// ilerideki eklemeler (ör. yapay zekâ, araç çubuğu ayarları) için hazır.
class _ComposeMoreMenu extends StatelessWidget {
  const _ComposeMoreMenu({required this.hasLabels, required this.onLabels});

  final bool hasLabels;
  final VoidCallback onLabels;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return PopupMenuButton<_MoreMenuAction>(
      tooltip: 'Diğer',
      color: t.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: t.divider),
      ),
      icon: Icon(
        LucideIcons.moreHorizontal,
        size: IconSize.md,
        color: hasLabels ? t.accent : t.textSecondary,
      ),
      onSelected: (action) {
        switch (action) {
          case _MoreMenuAction.labels:
            onLabels();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _MoreMenuAction.labels,
          child: Row(
            children: [
              Icon(LucideIcons.tag, size: IconSize.sm, color: t.textSecondary),
              const SizedBox(width: Space.md),
              const Text('Etiketler'),
            ],
          ),
        ),
      ],
    );
  }
}

class _ComposeToolbar extends StatelessWidget {
  const _ComposeToolbar({
    required this.listening,
    required this.hasLabels,
    required this.isFormatBarOpen,
    required this.onMic,
    required this.onAttach,
    required this.onImage,
    required this.onLabels,
    required this.onToggleFormat,
  });

  final bool listening;
  final bool hasLabels;
  final bool isFormatBarOpen;
  final VoidCallback onMic;
  final VoidCallback onAttach;
  final VoidCallback onImage;
  final VoidCallback onLabels;
  final VoidCallback onToggleFormat;

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
          child: Row(
            children: [
              IconButton(
                icon: const Icon(LucideIcons.paperclip, size: IconSize.md),
                tooltip: 'Dosya ekle',
                onPressed: onAttach,
                color: t.textSecondary,
              ),
              IconButton(
                icon: const Icon(LucideIcons.image, size: IconSize.md),
                tooltip: 'Görsel ekle',
                onPressed: onImage,
                color: t.textSecondary,
              ),
              IconButton(
                // Diğer ikonlarla birebir aynı kutuda (IconSize.md) ortalanır
                // — aksi hâlde bir `Text`, `Icon`'un metrikleriyle hizalanmaz
                // ve satırdaki tek başına hafif kaymış/küçük görünür.
                icon: SizedBox(
                  width: IconSize.md,
                  height: IconSize.md,
                  child: Center(
                    child: Text(
                      'A',
                      style: TextStyle(
                        fontFamily: AppText.family,
                        fontSize: 19,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        color: isFormatBarOpen ? t.accent : t.textSecondary,
                      ),
                    ),
                  ),
                ),
                tooltip: 'Biçimlendir',
                onPressed: onToggleFormat,
              ),
              _ComposeMoreMenu(hasLabels: hasLabels, onLabels: onLabels),
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
          ),
        ),
      ),
    );
  }
}
