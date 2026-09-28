import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/turkish.dart';
import '../../../data/services/quick_templates_store.dart';
import '../../../domain/models/quick_template.dart';
import '../../../domain/use_cases/text_extraction.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';

final RegExp _htmlTagPattern = RegExp(r'<[a-zA-Z/][^>]*>');
final RegExp _whitespaceRun = RegExp(r'\s+');

/// Kart önizlemesi için şablon içeriğini tek satıra normalize eder.
///
/// Yerleşik şablonlar paragrafları `\n\n` ile ayırır; `Text` widget'ı bunu
/// zorla satır sonu sayar, bu yüzden ham içerik `maxLines` ile birlikte
/// kullanılırsa (ör. "Merhaba,\n\n...") ilk satırdan sonraki boş satır
/// kotayı tüketip gerçek içerik hiç görünmeden kesilir. Satır sonları boşluğa
/// çevrilip metin doğal olarak sarmaya bırakılır.
String _templatePreviewText(String content) {
  final plain =
      _htmlTagPattern.hasMatch(content) ? TextExtraction.htmlToPlain(content) : content;
  return plain.replaceAll(_whitespaceRun, ' ').trim();
}

/// Kullanıcının hazır yanıt ve şablonları seçebileceği, yeni şablon
/// ekleyebileceği veya yönetebileceği alt sayfa (modal bottom sheet).
class QuickTemplatesSheet extends ConsumerStatefulWidget {
  const QuickTemplatesSheet({
    super.key,
    required this.onSelect,
  });

  /// Bir şablon seçildiğinde çağrılır; metni gövdeye yerleştirir.
  final ValueChanged<String> onSelect;

  static Future<void> show(
    BuildContext context, {
    required ValueChanged<String> onSelect,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QuickTemplatesSheet(onSelect: onSelect),
    );
  }

  @override
  ConsumerState<QuickTemplatesSheet> createState() =>
      _QuickTemplatesSheetState();
}

class _QuickTemplatesSheetState extends ConsumerState<QuickTemplatesSheet> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final templates = ref.watch(quickTemplatesProvider);

    final filtered = _query.isEmpty
        ? templates
        : templates.where((template) {
            final q = foldForSearch(_query);
            final title = foldForSearch(template.title);
            final content = foldForSearch(template.content);
            return title.contains(q) || content.contains(q);
          }).toList();

    final maxHeight = MediaQuery.sizeOf(context).height * 0.78;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: t.surfaceElevated,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.lg),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Sürükleme tutamacı
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: Space.sm),
                decoration: BoxDecoration(
                  color: t.textTertiary.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(Radii.full),
                ),
              ),
            ),
            // Başlık ve Yeni Ekle düğmesi
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.lg,
                vertical: Space.xs,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hazır Şablonlar & Yanıtlar',
                          style: AppText.titleMedium.copyWith(
                            color: t.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Sık kullandığınız metinleri tek dokunuşla ekleyin',
                          style: AppText.bodyMedium.copyWith(
                            fontSize: 12,
                            color: t.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => _openEditorDialog(context),
                    icon: Icon(LucideIcons.plus, size: 16),
                    label: const Text('Yeni'),
                    style: TextButton.styleFrom(
                      foregroundColor: t.accent,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),
            // Arama çubuğu
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.lg,
                vertical: Space.sm,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: t.surface,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: TextField(
                  controller: _searchController,
                  style: AppText.bodyMedium.copyWith(color: t.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Şablonlarda ara…',
                    hintStyle: AppText.bodyMedium.copyWith(
                      color: t.textTertiary,
                    ),
                    prefixIcon: Icon(
                      LucideIcons.search,
                      size: 18,
                      color: t.textTertiary,
                    ),
                    suffixIcon: _query.isNotEmpty
                        ? IconButton(
                            icon: Icon(LucideIcons.x, size: 16),
                            onPressed: _searchController.clear,
                          )
                        : null,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: Space.md,
                      vertical: Space.sm,
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            // Şablon listesi
            Flexible(
              child: filtered.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(Space.xl),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              LucideIcons.fileQuestion,
                              size: 44,
                              color: t.textTertiary.withValues(alpha: 0.6),
                            ),
                            const SizedBox(height: Space.md),
                            Text(
                              _query.isEmpty
                                  ? 'Henüz bir şablon bulunmuyor.'
                                  : '"$_query" ile eşleşen şablon bulunamadı.',
                              style: AppText.bodyMedium.copyWith(
                                color: t.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.lg,
                        vertical: Space.sm,
                      ),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: Space.xs),
                      itemBuilder: (context, index) {
                        final template = filtered[index];
                        return _TemplateCard(
                          template: template,
                          onSelect: () {
                            widget.onSelect(template.content);
                            Navigator.of(context).pop();
                          },
                          // Yerleşik şablonlar da artık düzenlenebilir VE
                          // silinebilir — kullanıcı hepsini kullanmak
                          // istemeyebilir (bkz. `_openEditorDialog`'daki
                          // `isBuiltIn` korunumu, düzenlerken rozet kalır).
                          onEdit: () =>
                              _openEditorDialog(context, template: template),
                          onDelete: () => ref
                              .read(quickTemplatesProvider.notifier)
                              .remove(template.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditorDialog(
    BuildContext context, {
    QuickTemplate? template,
  }) async {
    final titleController = TextEditingController(text: template?.title ?? '');
    final contentController =
        TextEditingController(text: template?.content ?? '');

    final isNew = template == null;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        final t = dialogCtx.tokens;
        // Varsayılan `AlertDialog` içeriğe göre büzülüyordu (dar + kısa) —
        // uzun bir şablon metni yazarken rahatsız ediciydi ve alttaki
        // `actions` satırı da dengesiz duruyordu. Bunun yerine geniş,
        // klavyeye duyarlı bir `Dialog` kurulur: başlık ve butonlar SABİT,
        // yalnızca ortadaki form alanı (özellikle içerik kutusu) genişler.
        // `backgroundColor`/`shape` özellikle verilmez — `Theme.dialogTheme`
        // (bkz. `app_theme.dart`) üzerinden zaten aynı tasarım dilini alır.
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.xxl,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // `Dialog` klavye açıldığında kendi `insetPadding`'ini
              // otomatik büyütüp yukarı kayar (bkz. Flutter'ın `Dialog`
              // implementasyonu) — bu yüzden burada ayrıca `viewInsets`
              // hesaplamaya gerek yok; `constraints.maxHeight` o an
              // gerçekten kullanılabilir alanı zaten yansıtır.
              final width = constraints.maxWidth < 520
                  ? constraints.maxWidth
                  : 520.0;
              return ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: width,
                  maxHeight: constraints.maxHeight,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Space.xl,
                        Space.xl,
                        Space.xl,
                        Space.md,
                      ),
                      child: Text(
                        isNew ? 'Yeni Şablon Ekle' : 'Şablonu Düzenle',
                        style: AppText.titleMedium.copyWith(
                          fontWeight: FontWeight.w700,
                          color: t.textPrimary,
                        ),
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                          Space.xl,
                          0,
                          Space.xl,
                          Space.lg,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(
                              controller: titleController,
                              autofocus: isNew,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                labelText: 'Şablon Başlığı',
                                hintText: 'Örn: Toplantı Onayı',
                                filled: true,
                                fillColor: t.surface,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(
                                    Radii.sm,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: Space.md),
                            // Asıl esneyen alan burası: modalın büyümesinin
                            // asıl amacı uzun şablon metnini rahat
                            // yazdırmak, o yüzden başlangıç yüksekliği de
                            // (`minLines`) cömert tutulur.
                            TextField(
                              controller: contentController,
                              minLines: 10,
                              maxLines: null,
                              textAlignVertical: TextAlignVertical.top,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                labelText: 'Şablon İçeriği',
                                hintText: 'İletiye eklenecek metni yazın…',
                                alignLabelWithHint: true,
                                filled: true,
                                fillColor: t.surface,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(
                                    Radii.sm,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Divider(height: 1, color: t.divider),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          Space.lg,
                          Space.md,
                          Space.lg,
                          Space.md,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                onPressed: () =>
                                    Navigator.of(dialogCtx).pop(false),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: Space.md,
                                  ),
                                ),
                                child: const Text('Vazgeç'),
                              ),
                            ),
                            const SizedBox(width: Space.md),
                            Expanded(
                              child: FilledButton(
                                onPressed: () {
                                  if (titleController.text.trim().isEmpty ||
                                      contentController.text.trim().isEmpty) {
                                    return;
                                  }
                                  Navigator.of(dialogCtx).pop(true);
                                },
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: Space.md,
                                  ),
                                ),
                                child: const Text('Kaydet'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    if (saved == true) {
      final updated = QuickTemplate(
        id: template?.id ?? 'custom-${DateTime.now().millisecondsSinceEpoch}',
        title: titleController.text.trim(),
        content: contentController.text.trim(),
        // Düzenlenen şablon yerleşikse `isBuiltIn` korunur — aksi hâlde
        // düzenleme onu sıradan (silinebilir) bir şablona düşürürdü.
        isBuiltIn: template?.isBuiltIn ?? false,
      );
      await ref.read(quickTemplatesProvider.notifier).addOrUpdate(updated);
    }
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    required this.template,
    required this.onSelect,
    this.onEdit,
    this.onDelete,
  });

  final QuickTemplate template;
  final VoidCallback onSelect;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Material(
      color: t.surface,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(Radii.md),
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(Space.xs),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Icon(
                  LucideIcons.fileText,
                  size: 18,
                  color: t.accent,
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            template.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.bodyMedium.copyWith(
                              fontWeight: FontWeight.w700,
                              color: t.textPrimary,
                            ),
                          ),
                        ),
                        if (template.isBuiltIn)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Space.xs,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: t.divider,
                              borderRadius: BorderRadius.circular(Radii.xs),
                            ),
                            child: Text(
                              'Yerleşik',
                              style: AppText.labelSmall.copyWith(
                                color: t.textTertiary,
                                fontSize: 10,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: Space.xs),
                    Text(
                      _templatePreviewText(template.content),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyMedium.copyWith(
                        fontSize: 12,
                        color: t.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.sm),
              // Ekle butonu
              IconButton(
                icon: Icon(LucideIcons.cornerDownLeft, size: 18),
                tooltip: 'İletiye Ekle',
                color: t.accent,
                onPressed: onSelect,
              ),
              // Yerleşik şablonlar da düzenlenebilir VE silinebilir —
              // kullanıcı gelen tüm hazır şablonları kullanmak
              // istemeyebilir; "Yerleşik" rozeti yalnızca uygulamayla
              // birlikte geldiğini belirtir, kısıtlama getirmez.
              PopupMenuButton<String>(
                icon: Icon(
                  LucideIcons.moreVertical,
                  size: 16,
                  color: t.textTertiary,
                ),
                onSelected: (value) {
                  if (value == 'edit') onEdit?.call();
                  if (value == 'delete') onDelete?.call();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(LucideIcons.pencil, size: 15),
                        const SizedBox(width: Space.sm),
                        const Text('Düzenle'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(LucideIcons.trash2, size: 15, color: t.danger),
                        const SizedBox(width: Space.sm),
                        Text('Sil', style: TextStyle(color: t.danger)),
                      ],
                    ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
