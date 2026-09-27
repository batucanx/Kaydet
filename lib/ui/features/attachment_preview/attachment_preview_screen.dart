import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdfx/pdfx.dart';
import 'package:video_player/video_player.dart';

import '../../../app/providers.dart';
import '../../../core/date_format.dart';
import '../../../core/result.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/use_cases/attachment_type.dart';
import '../../core/actions/attachment_actions.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/attachment_icon.dart';
import '../../core/widgets/kaydet_widgets.dart';
import 'docx_viewer.dart';
import 'pdf_preview_widget.dart';
import 'spreadsheet_viewer.dart';

/// Bir ekin tam ekran önizlemesi.
///
/// `_AttachmentChip`e (bkz. `mail_detail_screen.dart`) dokunmanın YENİ
/// varsayılan davranışı: dosyayı doğrudan işletim sistemine (Files/başka bir
/// uygulama) göndermek yerine bu ekranı açmak. Kullanıcı buradan isterse
/// üst çubuktaki "⋮" menüsüyle (bkz. `attachmentMenuItems`) başka bir
/// uygulamada açabilir, kaydedebilir, paylaşabilir ya da kopyasını gönderir.
///
/// İndirme/önbellek denetimi ekranın kendisinde yapılır — `MailRepository.
/// downloadAttachment` zaten "yerelde varsa indirme" davranışına sahiptir
/// (bkz. o metodun belgesi); burada yalnızca sonucu bekleyip duruma göre
/// yükleniyor/hata/önizleme gösterilir.
class AttachmentPreviewScreen extends ConsumerStatefulWidget {
  const AttachmentPreviewScreen({super.key, required this.attachment});

  final AttachmentRow attachment;

  @override
  ConsumerState<AttachmentPreviewScreen> createState() =>
      _AttachmentPreviewScreenState();
}

class _AttachmentPreviewScreenState
    extends ConsumerState<AttachmentPreviewScreen> {
  late Future<Result<String>> _localPath;

  @override
  void initState() {
    super.initState();
    _localPath = _resolve();
  }

  Future<Result<String>> _resolve() {
    return ref
        .read(mailRepositoryProvider)
        .downloadAttachment(widget.attachment.id);
  }

  void _retry() => setState(() => _localPath = _resolve());

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final kind = AttachmentType.resolve(
      mimeType: widget.attachment.mimeType,
      fileName: widget.attachment.fileName,
    );

    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        title: Text(
          widget.attachment.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          FutureBuilder<Result<String>>(
            future: _localPath,
            builder: (context, snapshot) {
              final path = snapshot.data?.valueOrNull;
              if (path == null) return const SizedBox.shrink();
              return MenuAnchor(
                animated: true,
                menuChildren: attachmentMenuItems(
                  context,
                  ref,
                  attachment: widget.attachment,
                  localPath: path,
                  kind: kind,
                ),
                builder: (context, controller, child) => IconButton(
                  icon: const Icon(LucideIcons.ellipsisVertical),
                  tooltip: 'Diğer',
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<Result<String>>(
          future: _localPath,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return _DownloadingView(fileName: widget.attachment.fileName);
            }
            return snapshot.data!.fold(
              (path) => _PreviewBody(
                kind: kind,
                path: path,
                attachment: widget.attachment,
              ),
              (failure) => Center(
                child: EmptyState(
                  icon: LucideIcons.cloudOff,
                  title: 'Ek indirilemedi',
                  description: failure.userMessage,
                  action: OutlinedButton(
                    onPressed: _retry,
                    child: const Text('Yeniden dene'),
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

class _DownloadingView extends StatelessWidget {
  const _DownloadingView({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: t.accent),
          const SizedBox(height: Space.lg),
          Text(
            'İndiriliyor…',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: t.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({
    required this.kind,
    required this.path,
    required this.attachment,
  });

  final AttachmentKind kind;
  final String path;
  final AttachmentRow attachment;

  @override
  Widget build(BuildContext context) {
    return switch (kind) {
      AttachmentKind.pdf => PdfPreviewWidget(path: path),
      AttachmentKind.image => _ImagePreview(path: path),
      AttachmentKind.text => _TextPreview(path: path),
      AttachmentKind.audio => _AudioPreview(path: path),
      AttachmentKind.video => _VideoPreview(path: path),
      AttachmentKind.document => _buildDocumentPreview(path, attachment),
      AttachmentKind.spreadsheet => _buildSpreadsheetPreview(path, attachment),
      AttachmentKind.presentation ||
      AttachmentKind.archive ||
      AttachmentKind.executable ||
      AttachmentKind.unknown => _UnsupportedPreview(
        kind: kind,
        path: path,
        attachment: attachment,
      ),
    };
  }

  Widget _buildDocumentPreview(String path, AttachmentRow attachment) {
    final ext =
        (attachment.fileName.contains('.')
                ? attachment.fileName.split('.').last
                : '')
            .toLowerCase()
            .trim();
    if (_isWordDocument(path, ext, attachment.mimeType)) {
      return DocxPreviewWidget(path: path, attachment: attachment);
    }
    return _UnsupportedPreview(
      kind: AttachmentKind.document,
      path: path,
      attachment: attachment,
      isLegacyOffice: ext == 'doc',
    );
  }

  Widget _buildSpreadsheetPreview(String path, AttachmentRow attachment) {
    final ext =
        (attachment.fileName.contains('.')
                ? attachment.fileName.split('.').last
                : '')
            .toLowerCase()
            .trim();
    if (_isSpreadsheetDocument(path, ext, attachment.mimeType)) {
      return SpreadsheetPreviewWidget(path: path, attachment: attachment);
    }
    return _UnsupportedPreview(
      kind: AttachmentKind.spreadsheet,
      path: path,
      attachment: attachment,
      isLegacyOffice: ext == 'xls',
    );
  }

  static bool _isWordDocument(String path, String ext, String mimeType) {
    if (ext == 'docx' ||
        ext == 'doc' ||
        ext == 'rtf' ||
        ext == 'dot' ||
        ext == 'dotx') {
      return true;
    }
    final mime = mimeType.toLowerCase();
    if (mime.contains('word') ||
        mime.contains('officedocument.wordprocessingml') ||
        mime.contains('msword') ||
        mime.contains('rtf')) {
      return true;
    }
    try {
      final file = File(path);
      if (file.existsSync()) {
        final length = file.lengthSync();
        if (length >= 5) {
          final raf = file.openSync(mode: FileMode.read);
          final header = raf.readSync(16);
          raf.closeSync();
          // PK\x03\x04
          if (header[0] == 0x50 &&
              header[1] == 0x4B &&
              header[2] == 0x03 &&
              header[3] == 0x04) {
            return true;
          }
          // OLE2 \xD0\xCF\x11\xE0
          if (header[0] == 0xD0 &&
              header[1] == 0xCF &&
              header[2] == 0x11 &&
              header[3] == 0xE0) {
            return true;
          }
          // {\rtf
          if (header[0] == 0x7B &&
              header[1] == 0x5C &&
              header[2] == 0x72 &&
              header[3] == 0x74 &&
              header[4] == 0x66) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  static bool _isSpreadsheetDocument(String path, String ext, String mimeType) {
    if (ext == 'xlsx' ||
        ext == 'xls' ||
        ext == 'csv' ||
        ext == 'tsv' ||
        ext == 'ods') {
      return true;
    }
    final mime = mimeType.toLowerCase();
    if (mime.contains('sheet') ||
        mime.contains('excel') ||
        mime.contains('csv') ||
        mime.contains('spreadsheet')) {
      return true;
    }
    try {
      final file = File(path);
      if (file.existsSync()) {
        final length = file.lengthSync();
        if (length >= 4) {
          final raf = file.openSync(mode: FileMode.read);
          final header = raf.readSync(16);
          raf.closeSync();
          if (header[0] == 0x50 &&
              header[1] == 0x4B &&
              header[2] == 0x03 &&
              header[3] == 0x04) {
            return true;
          }
          if (header[0] == 0xD0 &&
              header[1] == 0xCF &&
              header[2] == 0x11 &&
              header[3] == 0xE0) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }
}


// ---------------------------------------------------------------- GÖRSEL

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return PhotoView(
      imageProvider: FileImage(File(path)),
      backgroundDecoration: BoxDecoration(color: t.surfaceDeep),
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 4,
      loadingBuilder: (context, _) =>
          Center(child: CircularProgressIndicator(color: t.accent)),
      errorBuilder: (context, error, stackTrace) => Center(
        child: EmptyState(
          icon: LucideIcons.fileWarning,
          title: 'Görsel açılamadı',
          description: 'Dosya bozuk olabilir.',
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- METİN

/// Metin/kaynak dosyaları ham metin olarak gösterilir — HTML/XML/SVG bir
/// `WebView`de RENDER edilmez (bkz. `AttachmentType` belgesi: script çalıştırma
/// riski).
class _TextPreview extends StatefulWidget {
  const _TextPreview({required this.path});

  final String path;

  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  /// Çok büyük metin dosyalarını tek seferde belleğe/ekrana basmamak için
  /// önizleme bu boyutla sınırlanır.
  static const int _maxPreviewBytes = 2 * 1024 * 1024;

  late final Future<_TextPreviewData> _future = _read();

  Future<_TextPreviewData> _read() async {
    final file = File(widget.path);
    final length = await file.length();
    final truncated = length > _maxPreviewBytes;
    final bytes = truncated
        ? await file.openRead(0, _maxPreviewBytes).expand((c) => c).toList()
        : await file.readAsBytes();
    final content = utf8.decode(bytes, allowMalformed: true);
    return _TextPreviewData(content: content, truncated: truncated);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return FutureBuilder<_TextPreviewData>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Center(child: CircularProgressIndicator(color: t.accent));
        }
        if (snapshot.hasError) {
          return Center(
            child: EmptyState(
              icon: LucideIcons.fileWarning,
              title: 'Dosya okunamadı',
            ),
          );
        }
        final data = snapshot.data!;
        return Column(
          children: [
            if (data.truncated)
              StatusBanner(
                message: 'Dosya çok büyük; önizleme kısaltıldı.',
                icon: LucideIcons.triangleAlert,
                color: t.warning,
              ),
            Expanded(
              child: Scrollbar(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(Space.lg),
                  child: SelectableText(
                    data.content,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TextPreviewData {
  const _TextPreviewData({required this.content, required this.truncated});
  final String content;
  final bool truncated;
}

// -------------------------------------------------------------------- SES

class _AudioPreview extends StatefulWidget {
  const _AudioPreview({required this.path});

  final String path;

  @override
  State<_AudioPreview> createState() => _AudioPreviewState();
}

class _AudioPreviewState extends State<_AudioPreview> {
  final AudioPlayer _player = AudioPlayer();
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _state = state);
    });
    _player.onPositionChanged.listen((position) {
      if (mounted) setState(() => _position = position);
    });
    _player.onDurationChanged.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });
    _player.setSourceDeviceFile(widget.path);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_state == PlayerState.playing) {
      await _player.pause();
    } else {
      await _player.play(DeviceFileSource(widget.path));
    }
  }

  String _time(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final durationMs = _duration.inMilliseconds;
    final progress = durationMs == 0
        ? 0.0
        : (_position.inMilliseconds / durationMs).clamp(0.0, 1.0);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.fileAudio,
              size: 64,
              color: t.toneAt(12).foreground,
            ),
            const SizedBox(height: Space.xxl),
            Slider(
              value: progress,
              onChanged: durationMs == 0
                  ? null
                  : (value) => unawaited(
                      _player.seek(
                        Duration(milliseconds: (value * durationMs).round()),
                      ),
                    ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _time(_position),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                Text(
                  _time(_duration),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: Space.lg),
            IconButton.filled(
              iconSize: IconSize.xl,
              icon: Icon(
                _state == PlayerState.playing
                    ? LucideIcons.pause
                    : LucideIcons.play,
              ),
              onPressed: _toggle,
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ VİDEO

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({required this.path});

  final String path;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  late final VideoPlayerController _controller = VideoPlayerController.file(
    File(widget.path),
  );
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller
        .initialize()
        .then((_) {
          if (mounted) setState(() {});
        })
        .catchError((error) {
          if (mounted) setState(() => _error = error);
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (_error != null) {
      return Center(
        child: EmptyState(
          icon: LucideIcons.fileWarning,
          title: 'Video açılamadı',
          description: 'Dosya bozuk olabilir.',
        ),
      );
    }
    if (!_controller.value.isInitialized) {
      return Center(child: CircularProgressIndicator(color: t.accent));
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AspectRatio(
            aspectRatio: _controller.value.aspectRatio,
            child: GestureDetector(
              onTap: () => setState(() {
                unawaited(
                  _controller.value.isPlaying
                      ? _controller.pause()
                      : _controller.play(),
                );
              }),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  VideoPlayer(_controller),
                  if (!_controller.value.isPlaying)
                    Icon(LucideIcons.play, size: 56, color: t.onAccentFill),
                ],
              ),
            ),
          ),
          VideoProgressIndicator(_controller, allowScrubbing: true),
        ],
      ),
    );
  }
}

// ------------------------------------------------------- DİĞER/DESTEKSİZ

/// Word/Excel/PowerPoint/arşiv/tanınmayan/yürütülebilir dosyalar: sahte bir
/// önizleme üretilmez (bkz. bellek: bozuk bir önizleme yerine kontrollü bir
/// deneyim). Yalnızca dosya bilgisi ve güvenli işlemler (başka uygulamada aç/
/// kaydet/paylaş — bkz. `AttachmentPreviewScreen` üst çubuğu) sunulur.
class _UnsupportedPreview extends StatelessWidget {
  const _UnsupportedPreview({
    required this.kind,
    required this.path,
    required this.attachment,
    this.isLegacyOffice = false,
  });

  final AttachmentKind kind;
  final String path;
  final AttachmentRow attachment;
  final bool isLegacyOffice;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AttachmentTypeIcon(
              kind: kind,
              fileName: attachment.fileName,
              mimeType: attachment.mimeType,
              size: 64,
            ),
            const SizedBox(height: Space.lg),
            Text(
              attachment.fileName,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Space.xs),
            Text(
              '${AttachmentType.label(attachment.fileName)} · '
              '${formatBytes(attachment.sizeBytes)}',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: t.textTertiary),
            ),
            const SizedBox(height: Space.xl),
            if (kind == AttachmentKind.executable)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.lg),
                child: StatusBanner(
                  message:
                      'Bu dosya çalıştırılabilir bir uygulama olabilir. '
                      'Yalnızca güvendiğiniz gönderenlerden açın.',
                  icon: LucideIcons.shieldAlert,
                  color: t.danger,
                ),
              )
            else if (isLegacyOffice)
              Text(
                'Eski Office biçimleri (.doc, .xls) uygulama içinde doğrudan önizlenemiyor.\n'
                'Görüntülemek için lütfen başka bir uygulamada açın.',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: t.textSecondary),
              )
            else
              Text(
                'Bu dosya türü uygulama içinde önizlenemiyor.',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: t.textSecondary),
              ),
            const SizedBox(height: Space.xl),
            FilledButton.icon(
              onPressed: () => openAttachmentExternally(
                context,
                localPath: path,
                mimeType: attachment.mimeType,
              ),
              icon: const Icon(LucideIcons.externalLink),
              label: Text(
                'Başka bir uygulamada aç',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
