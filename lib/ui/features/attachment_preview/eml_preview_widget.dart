import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/date_format.dart';
import '../../../data/database/app_database.dart';
import '../../../data/services/eml_parser_service.dart';
import '../../../domain/models/eml_models.dart';
import '../../../domain/use_cases/attachment_type.dart';
import '../../core/actions/attachment_actions.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/attachment_icon.dart';
import '../../core/widgets/kaydet_notice.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../mail_detail/mail_html_document.dart';
import 'attachment_preview_screen.dart';

const int _maxEmlNestingDepth = 5;

class ParsedEmlAttachment {
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final Uint8List bytes;
  final bool isInline;
  final String? contentId;
  final bool isNestedEml;
  final ParsedEmlData? nestedData;

  const ParsedEmlAttachment({
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.bytes,
    required this.isInline,
    this.contentId,
    required this.isNestedEml,
    this.nestedData,
  });

  factory ParsedEmlAttachment.fromDomain(EmlAttachment att) {
    return ParsedEmlAttachment(
      fileName: att.fileName,
      mimeType: att.mimeType,
      sizeBytes: att.sizeBytes,
      bytes: att.bytes,
      isInline: att.isInline,
      contentId: att.contentId,
      isNestedEml: att.isNestedEml,
      nestedData: att.nestedMessage != null
          ? ParsedEmlData.fromDomain(att.nestedMessage!)
          : null,
    );
  }
}

class ParsedEmlData {
  final String subject;
  final ({String name, String email}) from;
  final List<({String name, String email})> to;
  final List<({String name, String email})> cc;
  final List<({String name, String email})> bcc;
  final ({String name, String email})? replyTo;
  final String? messageId;
  final DateTime date;
  final String? htmlBody;
  final String? textBody;
  final List<ParsedEmlAttachment> attachments;
  final String rawSource;

  const ParsedEmlData({
    required this.subject,
    required this.from,
    required this.to,
    required this.cc,
    required this.bcc,
    this.replyTo,
    this.messageId,
    required this.date,
    this.htmlBody,
    this.textBody,
    required this.attachments,
    this.rawSource = '',
  });

  factory ParsedEmlData.fromDomain(EmlMessage msg) {
    return ParsedEmlData(
      subject: msg.subject,
      from: (name: msg.from.name ?? msg.from.email, email: msg.from.email),
      to: msg.to.map((a) => (name: a.name ?? a.email, email: a.email)).toList(),
      cc: msg.cc.map((a) => (name: a.name ?? a.email, email: a.email)).toList(),
      bcc: msg.bcc.map((a) => (name: a.name ?? a.email, email: a.email)).toList(),
      replyTo: msg.replyTo != null
          ? (name: msg.replyTo!.name ?? msg.replyTo!.email, email: msg.replyTo!.email)
          : null,
      messageId: msg.messageId,
      date: msg.date,
      htmlBody: msg.htmlBody,
      textBody: msg.textBody,
      attachments: msg.attachments.map(ParsedEmlAttachment.fromDomain).toList(),
      rawSource: msg.rawSource,
    );
  }
}

abstract final class EmlParser {
  static ParsedEmlData parseBytes(Uint8List bytes) {
    final msg = EmlParserService.parseBytes(bytes);
    return ParsedEmlData.fromDomain(msg);
  }

  static ParsedEmlData parseText(String rawText) {
    final msg = EmlParserService.parseText(rawText);
    return ParsedEmlData.fromDomain(msg);
  }

  static Future<ParsedEmlData> parseFileInIsolate(String path) async {
    final msg = await EmlParserService.parseFileInIsolate(path);
    return ParsedEmlData.fromDomain(msg);
  }
}

/// .eml (RFC 822) e-posta dosyalarını uygulama içinde tam donanımlı
/// mail görüntüleme ekranı olarak açan ve önizleyen bileşen.
class EmlPreviewWidget extends StatefulWidget {
  const EmlPreviewWidget({
    super.key,
    required this.path,
    required this.attachment,
    this.depth = 0,
    this.initialData,
  });

  final String path;
  final AttachmentRow attachment;
  final int depth;
  final ParsedEmlData? initialData;

  @override
  State<EmlPreviewWidget> createState() => _EmlPreviewWidgetState();
}

class _EmlPreviewWidgetState extends State<EmlPreviewWidget> {
  ParsedEmlData? _data;
  bool _loading = true;
  Object? _error;
  bool _expandedDetails = false;
  WebViewController? _webViewController;

  @override
  void initState() {
    super.initState();
    if (widget.initialData != null) {
      _data = widget.initialData;
      _loading = false;
    } else {
      _loadEml();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_data != null && _webViewController == null) {
      _initWebView(_data!, context.tokens);
    }
  }

  Future<void> _loadEml() async {
    try {
      final file = File(widget.path);
      if (!await file.exists()) {
        throw Exception('Dosya bulunamadı.');
      }

      final parsed = await EmlParser.parseFileInIsolate(widget.path);

      if (mounted) {
        setState(() {
          _data = parsed;
          _loading = false;
        });
        _initWebView(parsed, context.tokens);
      }
    } catch (e, st) {
      debugPrint('[EML Parser] Hata: $e\n$st');
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _retryLoad() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _loadEml();
  }

  Future<void> _initWebView(ParsedEmlData data, KaydetTokens tokens) async {
    String contentHtml;
    if (data.htmlBody != null && data.htmlBody!.trim().isNotEmpty) {
      contentHtml = data.htmlBody!;
    } else if (data.textBody != null && data.textBody!.trim().isNotEmpty) {
      contentHtml = MailHtmlDocument.fromPlainText(data.textBody!);
    } else {
      contentHtml =
          '<div style="color:${tokens.isDark ? '#94A3B8' : '#64748B'};padding:16px;">Bu iletinin metin içeriği yok.</div>';
    }

    String script = '';
    try {
      script = await MailHtmlDocument.renderScript;
    } catch (_) {}

    final (preparedHtml, supportsDark) =
        MailHtmlDocument.prepare(contentHtml, dark: tokens.isDark);

    final fullHtml = MailHtmlDocument.build(
      body: preparedHtml,
      tokens: tokens,
      emailSupportsDark: supportsDark,
      script: script,
      documentId: DateTime.now().millisecondsSinceEpoch,
    );

    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..loadHtmlString(fullHtml);

      if (mounted) {
        setState(() {
          _webViewController = controller;
        });
      }
    } catch (e) {
      debugPrint('[EML Preview] WebViewController kurulamadı: $e');
    }
  }

  Future<void> _openInnerAttachment(ParsedEmlAttachment att) async {
    if (att.isNestedEml) {
      if (widget.depth >= _maxEmlNestingDepth) {
        final overlay = Overlay.of(context, rootOverlay: true);
        if (overlay.mounted) {
          KaydetNotice.show(
            overlay,
            message:
                'Maksimum iç içe ileti derinliğine ($_maxEmlNestingDepth) ulaşıldı.',
          );
        }
        return;
      }

      try {
        final tempDir = await Directory.systemTemp.createTemp('eml_nested_');
        final tempFile = File('${tempDir.path}/${att.fileName}');
        await tempFile.writeAsBytes(att.bytes);

        if (!mounted) return;
        final row = AttachmentRow(
          id: -1,
          messageId: -1,
          partId: 'nested_${widget.depth + 1}',
          fileName: att.fileName,
          mimeType: 'message/rfc822',
          sizeBytes: att.sizeBytes,
          isInline: false,
          localPath: tempFile.path,
          isOutgoing: false,
        );

        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AttachmentPreviewScreen(
              attachments: [row],
              initialIndex: 0,
              localPathOf: (_) => tempFile.path,
            ),
          ),
        );
      } catch (e) {
        debugPrint('[EML Parser] İç içe EML açılamadı: $e');
      }
      return;
    }

    try {
      final tempDir = await Directory.systemTemp.createTemp('eml_inner_');
      final tempFile = File('${tempDir.path}/${att.fileName}');
      await tempFile.writeAsBytes(att.bytes);

      if (!mounted) return;
      final row = AttachmentRow(
        id: -1,
        messageId: -1,
        partId: 'inner',
        fileName: att.fileName,
        mimeType: att.mimeType,
        sizeBytes: att.sizeBytes,
        isInline: false,
        localPath: tempFile.path,
        isOutgoing: false,
      );

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AttachmentPreviewScreen(
            attachments: [row],
            initialIndex: 0,
            localPathOf: (_) => tempFile.path,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[EML Parser] Ek açılamadı: $e');
    }
  }

  Future<void> _saveInnerAttachment(ParsedEmlAttachment att) async {
    try {
      final tempDir = await Directory.systemTemp.createTemp('eml_download_');
      final tempFile = File('${tempDir.path}/${att.fileName}');
      await tempFile.writeAsBytes(att.bytes);

      if (!mounted) return;
      await saveAttachmentToDevice(
        context,
        localPath: tempFile.path,
        fileName: att.fileName,
      );
    } catch (e) {
      debugPrint('[EML Parser] Ek kaydedilemedi: $e');
    }
  }

  Future<void> _showRawSourceModal() async {
    final t = context.tokens;
    String raw = _data?.rawSource ?? '';
    if (raw.isEmpty) {
      try {
        raw = await File(widget.path).readAsString();
      } catch (_) {
        raw = 'Ham kaynak okunamadı.';
      }
    }

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.surfaceElevated,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(Space.md),
              child: Row(
                children: [
                  const Icon(LucideIcons.code, size: 18),
                  const SizedBox(width: Space.sm),
                  Text(
                    'EML Kaynak Kodu',
                    style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(LucideIcons.x, size: 18),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.all(Space.md),
                child: SelectableText(
                  raw,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: t.accent),
            ),
            const SizedBox(height: Space.md),
            Text(
              'İleti yükleniyor…',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: t.textSecondary),
            ),
          ],
        ),
      );
    }

    if (_error != null || _data == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              EmptyState(
                icon: LucideIcons.fileWarning,
                title: 'Bu mail dosyası önizlenemiyor',
                description:
                    'Dosya bozuk olabilir veya geçerli bir e-posta biçiminde değil. Bu EML dosyası önizlenemiyor.',
              ),
              const SizedBox(height: Space.lg),
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(LucideIcons.rotateCcw, size: 16),
                    label: const Text('Tekrar Dene'),
                    onPressed: _retryLoad,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(LucideIcons.externalLink, size: 16),
                    label: const Text('Dışarıda Aç'),
                    onPressed: () => openAttachmentExternally(
                      context,
                      localPath: widget.path,
                      mimeType: 'message/rfc822',
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(LucideIcons.code, size: 16),
                    label: const Text('Kaynağı Görüntüle'),
                    onPressed: _showRawSourceModal,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final data = _data!;
    final recipientsSummary = data.to.isNotEmpty
        ? data.to.map((a) => a.name).join(', ')
        : 'Belirtilmedi';

    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // EML Başlık & Bilgi Çubuğu
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: Space.sm,
              ),
              decoration: BoxDecoration(
                color: t.surface,
                border: Border(bottom: BorderSide(color: t.divider)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // EML Badge Bar
                  Row(
                    children: [
                      Icon(LucideIcons.mail, size: 14, color: t.accent),
                      const SizedBox(width: Space.xs),
                      Expanded(
                        child: Text(
                          widget.depth > 0
                              ? 'İç İçe İleti — Seviye ${widget.depth + 1}'
                              : 'İletilen E-posta — ${widget.attachment.fileName.replaceAll(RegExp(r'\.eml$', caseSensitive: false), '')}',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: t.accent,
                                fontWeight: FontWeight.w600,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(LucideIcons.code, size: 14),
                        tooltip: 'Kaynak kodunu göster',
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        padding: EdgeInsets.zero,
                        onPressed: _showRawSourceModal,
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.xs),

                  // Konu
                  Text(
                    data.subject,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: t.textPrimary,
                        ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: Space.sm),

                  // Gönderen & Tarih
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Avatar
                      CircleAvatar(
                        radius: 18,
                        backgroundColor:
                            t.toneAt(data.from.name.hashCode.abs() % 14).background,
                        child: Text(
                          data.from.name.isNotEmpty
                              ? data.from.name.substring(0, 1).toUpperCase()
                              : '?',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color:
                                t.toneAt(data.from.name.hashCode.abs() % 14).foreground,
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.sm),

                      // İsim & Kime
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    data.from.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: t.textPrimary,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (data.from.email.isNotEmpty &&
                                    data.from.email != data.from.name) ...[
                                  const SizedBox(width: Space.xs),
                                  Flexible(
                                    child: Text(
                                      '<${data.from.email}>',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: t.textTertiary,
                                          ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Kime: $recipientsSummary',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: t.textSecondary,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                InkWell(
                                  onTap: () => setState(
                                      () => _expandedDetails = !_expandedDetails),
                                  child: Padding(
                                    padding:
                                        const EdgeInsets.symmetric(horizontal: Space.xs),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'Ayrıntılar',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: t.accent,
                                              ),
                                        ),
                                        Icon(
                                          _expandedDetails
                                              ? LucideIcons.chevronUp
                                              : LucideIcons.chevronDown,
                                          size: 12,
                                          color: t.accent,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: Space.sm),

                      // Tarih
                      Text(
                        formatDetailDate(data.date),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: t.textTertiary,
                            ),
                      ),
                    ],
                  ),

                  // Genişletilebilir Ayrıntılar
                  if (_expandedDetails) ...[
                    const SizedBox(height: Space.sm),
                    Container(
                      padding: const EdgeInsets.all(Space.sm),
                      decoration: BoxDecoration(
                        color: t.surfaceElevated,
                        borderRadius: BorderRadius.circular(Radii.xs),
                        border: Border.all(color: t.divider),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildDetailRow(
                            context,
                            'Kimden:',
                            '${data.from.name} <${data.from.email}>',
                          ),
                          _buildDetailRow(
                            context,
                            'Kime:',
                            data.to.map((a) => '${a.name} <${a.email}>').join(', '),
                          ),
                          if (data.cc.isNotEmpty)
                            _buildDetailRow(
                              context,
                              'Bilgi (CC):',
                              data.cc.map((a) => '${a.name} <${a.email}>').join(', '),
                            ),
                          if (data.bcc.isNotEmpty)
                            _buildDetailRow(
                              context,
                              'Gizli (BCC):',
                              data.bcc.map((a) => '${a.name} <${a.email}>').join(', '),
                            ),
                          if (data.replyTo != null)
                            _buildDetailRow(
                              context,
                              'Yanıtla:',
                              '${data.replyTo!.name} <${data.replyTo!.email}>',
                            ),
                          if (data.messageId != null)
                            _buildDetailRow(
                              context,
                              'İleti Kimliği:',
                              data.messageId!,
                            ),
                          _buildDetailRow(
                            context,
                            'Tarih:',
                            formatDetailDate(data.date),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // Ekler Bölümü
                  if (data.attachments.isNotEmpty) ...[
                    const SizedBox(height: Space.sm),
                    Row(
                      children: [
                        Icon(LucideIcons.paperclip, size: 14, color: t.textSecondary),
                        const SizedBox(width: Space.xs),
                        Text(
                          'Ekler (${data.attachments.length})',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: t.textPrimary,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.xs),
                    SizedBox(
                      height: 48,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: data.attachments.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(width: Space.sm),
                        itemBuilder: (context, index) {
                          final att = data.attachments[index];
                          final attKind = AttachmentType.resolve(
                            mimeType: att.mimeType,
                            fileName: att.fileName,
                          );
                          return Container(
                            decoration: BoxDecoration(
                              color: t.surfaceElevated,
                              borderRadius: BorderRadius.circular(Radii.xs),
                              border: Border.all(color: t.divider),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                InkWell(
                                  onTap: () => _openInnerAttachment(att),
                                  borderRadius: const BorderRadius.horizontal(
                                    left: Radius.circular(Radii.xs),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: Space.sm,
                                      vertical: Space.xs,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        AttachmentTypeIcon(
                                          kind: attKind,
                                          fileName: att.fileName,
                                          mimeType: att.mimeType,
                                          size: 16,
                                        ),
                                        const SizedBox(width: Space.xs),
                                        ConstrainedBox(
                                          constraints:
                                              const BoxConstraints(maxWidth: 150),
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                att.isNestedEml
                                                    ? att.fileName.replaceAll(
                                                        RegExp(r'\.eml$',
                                                            caseSensitive:
                                                                false),
                                                        '')
                                                    : att.fileName,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color: t.textPrimary,
                                                    ),
                                              ),
                                              Text(
                                                formatBytes(att.sizeBytes),
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      fontSize: 10,
                                                      color: t.textTertiary,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(LucideIcons.download, size: 14),
                                  padding: const EdgeInsets.all(Space.xs),
                                  constraints: const BoxConstraints(
                                    minWidth: 28,
                                    minHeight: 28,
                                  ),
                                  tooltip: 'Bu eki indir',
                                  onPressed: () => _saveInnerAttachment(att),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Mail Gövdesi (WebView veya Metin)
            Expanded(
              child: _webViewController != null
                  ? WebViewWidget(controller: _webViewController!)
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(Space.md),
                      child: SelectableText(
                        data.textBody ?? 'Bu iletinin metin içeriği yok.',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: t.textPrimary),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDetailRow(BuildContext context, String label, String value) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: t.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: t.textPrimary,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
