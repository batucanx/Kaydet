import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../data/database/app_database.dart';
import '../../../data/services/signature_image_service.dart';
import '../../core/theme/tokens.dart';

/// Yeni imza oluşturma veya mevcut imzayı düzenleme alt sayfası.
///
/// Metin, galeriden görsel (PNG/JPG/WebP) veya remote image URL desteği sunar.
/// Canlı önizleme, boyut ayarı (küçük/orta/büyük) ve konum ayarı (üst/alt) içerir.
Future<void> showNewSignatureSheet(
  BuildContext context,
  WidgetRef ref, {
  required int accountId,
  SignatureRow? existingSignature,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Sayfa zemini, köşeleri ve sürükleme kulpunu kendisi çizer; temanın
    // (`bottomSheetTheme`) kulpu ve zemini ikinci kez çizilmesin.
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    builder: (context) => _NewSignatureSheet(
      accountId: accountId,
      existingSignature: existingSignature,
    ),
  );
}

class _NewSignatureSheet extends ConsumerStatefulWidget {
  const _NewSignatureSheet({
    required this.accountId,
    this.existingSignature,
  });

  final int accountId;
  final SignatureRow? existingSignature;

  @override
  ConsumerState<_NewSignatureSheet> createState() => _NewSignatureSheetState();
}

class _NewSignatureSheetState extends ConsumerState<_NewSignatureSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _bodyController;
  late final TextEditingController _urlController;
  final FocusNode _nameFocus = FocusNode();
  final GlobalKey _nameKey = GlobalKey();
  bool _nameError = false;

  // Görsel durumu
  String _imageType = 'none'; // 'none', 'local', 'remote'
  String? _localImagePath;
  String? _remoteImageUrl;
  int _imageWidth = 200; // Varsayılan orta boy (200px)
  String _imagePosition = 'bottom'; // 'top', 'bottom'
  bool _isDefault = false;

  bool _isSaving = false;
  bool _isValidatingUrl = false;
  String? _urlValidationMessage;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingSignature;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _bodyController = TextEditingController(text: existing?.body ?? '');
    _urlController = TextEditingController(text: existing?.remoteImageUrl ?? '');

    if (existing != null) {
      _imageType = existing.imageType;
      _localImagePath = existing.localImagePath;
      _remoteImageUrl = existing.remoteImageUrl;
      _imageWidth = existing.imageWidth;
      _imagePosition = existing.imagePosition;
      _isDefault = existing.isDefault;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bodyController.dispose();
    _urlController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  bool get _isEditing => widget.existingSignature != null;

  Future<void> _pickImageFromGallery() async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );

      if (pickedFile == null) return;

      final savedPath = await SignatureImageService.processAndSaveLocalImage(
        sourcePath: pickedFile.path,
        accountId: widget.accountId,
      );

      if (!mounted) return;

      setState(() {
        _imageType = 'local';
        _localImagePath = savedPath;
        _remoteImageUrl = null;
        _urlController.clear();
        _urlValidationMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Görsel seçilirken hata oluştu: $e')),
      );
    }
  }

  Future<void> _applyRemoteUrl() async {
    final rawUrl = _urlController.text.trim();
    if (rawUrl.isEmpty) return;

    if (!SignatureImageService.isValidImageUrlFormat(rawUrl)) {
      setState(() {
        _urlValidationMessage = 'Geçerli bir HTTP veya HTTPS görsel URL\'si giriniz.';
      });
      return;
    }

    setState(() {
      _isValidatingUrl = true;
      _urlValidationMessage = null;
    });

    final validation = await SignatureImageService.validateRemoteImageUrl(rawUrl);

    if (!mounted) return;

    setState(() {
      _isValidatingUrl = false;
      if (validation.isValid) {
        _imageType = 'remote';
        _remoteImageUrl = rawUrl;
        _localImagePath = null;
        _urlValidationMessage = null;
      } else {
        _urlValidationMessage = validation.error ?? 'Görsel indirilemedi veya formatı desteklenmiyor.';
      }
    });
  }

  void _removeImage() {
    setState(() {
      _imageType = 'none';
      _localImagePath = null;
      _remoteImageUrl = null;
      _urlController.clear();
      _urlValidationMessage = null;
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = true);
      final ctx = _nameKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          alignment: 0.1,
        );
      }
      _nameFocus.requestFocus();
      return;
    }

    setState(() => _isSaving = true);

    try {
      final repo = ref.read(accountRepositoryProvider);

      if (_isEditing) {
        await repo.updateSignatureContent(
          signatureId: widget.existingSignature!.id,
          name: name,
          body: _bodyController.text,
          imageType: _imageType,
          localImagePath: _localImagePath,
          remoteImageUrl: _remoteImageUrl,
          imageWidth: _imageWidth,
          imagePosition: _imagePosition,
        );

        if (_isDefault && !widget.existingSignature!.isDefault) {
          await repo.setDefaultSignature(
            widget.accountId,
            widget.existingSignature!.id,
          );
        }
      } else {
        await repo.createSignature(
          accountId: widget.accountId,
          name: name,
          body: _bodyController.text,
          isDefault: _isDefault,
          imageType: _imageType,
          localImagePath: _localImagePath,
          remoteImageUrl: _remoteImageUrl,
          imageWidth: _imageWidth,
          imagePosition: _imagePosition,
        );
      }

      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('İmza kaydedilirken hata: $e')),
        );
      }
    }
  }

  Future<void> _delete() async {
    if (!_isEditing) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('İmzayı Sil'),
        content: const Text('Bu imzayı silmek istediğinizden emin misiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Sil',
              style: TextStyle(color: context.tokens.danger),
            ),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      setState(() => _isSaving = true);
      await ref
          .read(accountRepositoryProvider)
          .deleteSignature(widget.existingSignature!.id);
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final insets = MediaQuery.of(context).viewInsets;

    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.9,
        ),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Radii.lg),
          ),
        ),
        child: Column(
          children: [
            // Sürükleme kulpu (drag handle)
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: Space.sm, bottom: Space.xs),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: t.divider,
                  borderRadius: BorderRadius.circular(Radii.full),
                ),
              ),
            ),

            // Üst Bar
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: Space.xs,
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(LucideIcons.x, size: IconSize.md),
                    tooltip: 'Kapat',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: Space.xs),
                  Expanded(
                    child: Text(
                      _isEditing ? 'İmzayı Düzenle' : 'Yeni İmza',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  if (_isEditing)
                    IconButton(
                      icon: Icon(
                        LucideIcons.trash2,
                        size: IconSize.md,
                        color: t.danger,
                      ),
                      tooltip: 'İmzayı Sil',
                      onPressed: _isSaving ? null : _delete,
                    ),
                  FilledButton(
                    onPressed: _isSaving ? null : _save,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: Space.md),
                      minimumSize: const Size(0, 36),
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Kaydet'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Form İçeriği
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(Space.md),
                children: [
                  // İmza Adı
                  TextField(
                    key: _nameKey,
                    controller: _nameController,
                    focusNode: _nameFocus,
                    onChanged: (_) {
                      if (_nameError) setState(() => _nameError = false);
                    },
                    decoration: InputDecoration(
                      labelText: 'İmza Adı',
                      hintText: 'Örn: Kurumsal, Kişisel',
                      prefixIcon: const Icon(LucideIcons.tag, size: 18),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.sm),
                        borderSide: _nameError
                            ? BorderSide(color: t.danger, width: 1.5)
                            : const BorderSide(),
                      ),
                      enabledBorder: _nameError
                          ? OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Radii.sm),
                              borderSide: BorderSide(color: t.danger, width: 1.5),
                            )
                          : null,
                      focusedBorder: _nameError
                          ? OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Radii.sm),
                              borderSide: BorderSide(color: t.danger, width: 2),
                            )
                          : null,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: Space.md),

                  // İmza Metni
                  TextField(
                    controller: _bodyController,
                    maxLines: 4,
                    minLines: 2,
                    decoration: InputDecoration(
                      labelText: 'İmza Metni',
                      hintText: 'Ad Soyad\nÜnvan / Şirket\nTelefon vb.',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.sm),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: Space.lg),

                  // Görsel Yönetimi Bölümü
                  Text(
                    'İMZA GÖRSELİ',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: t.textSecondary,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                  ),
                  const SizedBox(height: Space.xs),

                  _buildImageSelectorCard(context),

                  if (_imageType != 'none') ...[
                    const SizedBox(height: Space.md),
                    _buildImageControlRow(context),
                  ],

                  const SizedBox(height: Space.lg),

                  // Canlı Önizleme Kartı
                  Text(
                    'ÖNİZLEME',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: t.textSecondary,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                  ),
                  const SizedBox(height: Space.xs),
                  _buildPreviewCard(context),

                  const SizedBox(height: Space.lg),

                  // Varsayılan İmza Switch
                  SwitchListTile(
                    title: const Text('Varsayılan imza olarak kullan'),
                    subtitle: Text(
                      'Yeni maillerde bu hesap için otomatik seçilir',
                      style: TextStyle(color: t.textTertiary, fontSize: 12),
                    ),
                    value: _isDefault,
                    onChanged: (val) => setState(() => _isDefault = val),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: Space.xl),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSelectorCard(BuildContext context) {
    final t = context.tokens;

    if (_imageType != 'none') {
      return Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: t.border),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: t.surfaceDeep,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: t.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: _imageType == 'local' && _localImagePath != null
                  ? Image.file(
                      File(_localImagePath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Icon(
                        LucideIcons.imageOff,
                        color: t.textTertiary,
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: _remoteImageUrl ?? '',
                      fit: BoxFit.cover,
                      placeholder: (_, _) => const Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      errorWidget: (_, _, _) => Icon(
                        LucideIcons.imageOff,
                        color: t.textTertiary,
                      ),
                    ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _imageType == 'local' ? 'Galeriden Görsel' : 'Uzak Görsel URL',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _imageType == 'local'
                        ? 'Cihazdan optimize edilmiş görsel'
                        : (_remoteImageUrl ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.textTertiary, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(LucideIcons.trash2, size: 18, color: t.danger),
              tooltip: 'Görseli kaldır',
              onPressed: _removeImage,
            ),
          ],
        ),
      );
    }

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
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(LucideIcons.image, size: 16),
                  label: const Text('Galeriden Seç'),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                  ),
                  onPressed: _pickImageFromGallery,
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Row(
            children: [
              Expanded(
                child: Divider(color: t.divider),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                child: Text(
                  'VEYA URL İLE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: t.textTertiary,
                  ),
                ),
              ),
              Expanded(
                child: Divider(color: t.divider),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    hintText: 'https://site.com/imza.png',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: Space.sm,
                      vertical: Space.sm,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                  ),
                  keyboardType: TextInputType.url,
                  onSubmitted: (_) => _applyRemoteUrl(),
                ),
              ),
              const SizedBox(width: Space.xs),
              ElevatedButton(
                onPressed: _isValidatingUrl ? null : _applyRemoteUrl,
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                  minimumSize: const Size(40, 36),
                ),
                child: _isValidatingUrl
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(LucideIcons.check, size: 16),
              ),
            ],
          ),
          if (_urlValidationMessage != null) ...[
            const SizedBox(height: Space.xs),
            Text(
              _urlValidationMessage!,
              style: TextStyle(color: t.danger, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildImageControlRow(BuildContext context) {
    final t = context.tokens;

    return Container(
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: t.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'Genişlik:',
                style: TextStyle(fontSize: 12, color: t.textSecondary),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 120,
                      label: Text('Küçük', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment(
                      value: 200,
                      label: Text('Orta', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment(
                      value: 320,
                      label: Text('Büyük', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                  selected: {_imageWidth},
                  onSelectionChanged: (set) {
                    setState(() => _imageWidth = set.first);
                  },
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.selected)
                          ? t.accentSubtle
                          : t.surfaceDeep,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Row(
            children: [
              Text(
                'Konum:',
                style: TextStyle(fontSize: 12, color: t.textSecondary),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'top',
                      label: Text('Görsel Üstte', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment(
                      value: 'bottom',
                      label: Text('Görsel Altta', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                  selected: {_imagePosition},
                  onSelectionChanged: (set) {
                    setState(() => _imagePosition = set.first);
                  },
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.selected)
                          ? t.accentSubtle
                          : t.surfaceDeep,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard(BuildContext context) {
    final t = context.tokens;
    final text = _bodyController.text.trim();
    final hasImage = _imageType != 'none';

    if (text.isEmpty && !hasImage) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: t.surfaceDeep,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: t.border),
        ),
        child: Center(
          child: Text(
            'İmza metni veya görsel eklediğinizde önizleme burada görünecektir.',
            style: TextStyle(color: t.textTertiary, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    Widget? imageWidget;
    if (hasImage) {
      if (_imageType == 'local' && _localImagePath != null) {
        imageWidget = Image.file(
          File(_localImagePath!),
          width: _imageWidth.toDouble(),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _brokenImagePlaceholder(context),
        );
      } else if (_imageType == 'remote' && _remoteImageUrl != null) {
        imageWidget = CachedNetworkImage(
          imageUrl: _remoteImageUrl!,
          width: _imageWidth.toDouble(),
          fit: BoxFit.contain,
          placeholder: (_, _) => Container(
            width: _imageWidth.toDouble(),
            height: 60,
            decoration: BoxDecoration(
              color: t.surfaceDeep,
              borderRadius: BorderRadius.circular(Radii.xs),
            ),
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          errorWidget: (_, _, _) => _brokenImagePlaceholder(context),
        );
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (imageWidget != null && _imagePosition == 'top') ...[
            imageWidget,
            const SizedBox(height: Space.xs),
          ],
          if (text.isNotEmpty)
            Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.4,
                  ),
            ),
          if (imageWidget != null && _imagePosition == 'bottom') ...[
            const SizedBox(height: Space.xs),
            imageWidget,
          ],
        ],
      ),
    );
  }

  Widget _brokenImagePlaceholder(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: _imageWidth.toDouble(),
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: t.surfaceDeep,
        borderRadius: BorderRadius.circular(Radii.xs),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.imageOff, size: 16, color: t.danger),
          const SizedBox(width: Space.xs),
          Text(
            'Görsel yüklenemedi',
            style: TextStyle(color: t.danger, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
