import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../core/turkish.dart';
import '../../../data/services/quick_templates_store.dart';
import '../../../domain/models/quick_template.dart';
import '../../../domain/use_cases/text_extraction.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

final RegExp _htmlTagPattern = RegExp(r'<[a-zA-Z/][^>]*>');
final RegExp _whitespaceRun = RegExp(r'\s+');

String _previewText(String content) {
  final plain = _htmlTagPattern.hasMatch(content)
      ? TextExtraction.htmlToPlain(content)
      : content;
  return plain.replaceAll(_whitespaceRun, ' ').trim();
}

/// Şablonlar alt sayfası: hazır yanıt şablonlarını arama, ekleme, düzenleme,
/// silme ve varsayılana sıfırlama. Etiketler sayfasıyla aynı tasarım dilini
/// kullanır; şablonlar hesaba özgüdür ve web ile eşitlenir.
class TemplatesSettingsScreen extends ConsumerStatefulWidget {
  const TemplatesSettingsScreen({super.key});

  @override
  ConsumerState<TemplatesSettingsScreen> createState() =>
      _TemplatesSettingsScreenState();
}

class _TemplatesSettingsScreenState
    extends ConsumerState<TemplatesSettingsScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() => _query = _search.text.trim()));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final templates = ref.watch(quickTemplatesProvider);
    final q = foldForSearch(_query);
    final filtered = _query.isEmpty
        ? templates
        : templates
              .where(
                (x) =>
                    foldForSearch(x.title).contains(q) ||
                    foldForSearch(x.content).contains(q),
              )
              .toList();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Şablonlar'),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(LucideIcons.ellipsisVertical, color: t.onAccentFill),
            tooltip: 'Diğer',
            onSelected: (value) {
              if (value == 'reset') _reset();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'reset',
                child: Text('Varsayılanlara sıfırla'),
              ),
            ],
          ),
          IconButton(
            icon: Icon(
              LucideIcons.plus,
              size: IconSize.md,
              color: t.onAccentFill,
            ),
            tooltip: 'Şablon ekle',
            style: IconButton.styleFrom(
              backgroundColor: t.onAccentFill.withValues(alpha: 0.16),
            ),
            onPressed: () => _edit(),
          ),
          const SizedBox(width: Space.md),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.huge),
        children: [
          _Hero(count: templates.length),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.sm,
              Space.lg,
              Space.sm,
            ),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: 'Şablonlarda ara…',
                filled: true,
                fillColor: t.surfaceElevated,
                isDense: true,
                prefixIcon: Icon(
                  LucideIcons.search,
                  size: IconSize.md,
                  color: t.textTertiary,
                ),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(LucideIcons.x, size: IconSize.sm),
                        onPressed: _search.clear,
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.full),
                  borderSide: BorderSide(color: t.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.full),
                  borderSide: BorderSide(color: t.divider),
                ),
              ),
            ),
          ),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.xl),
              child: EmptyState(
                icon: LucideIcons.fileText,
                title: _query.isEmpty
                    ? 'Henüz şablon yok'
                    : 'Eşleşen şablon bulunamadı',
                description: _query.isEmpty
                    ? 'Sık yazdığınız yanıtları şablon olarak kaydedin ve '
                          'tek dokunuşla iletiye ekleyin.'
                    : '"$_query" ile eşleşen şablon yok.',
                action: _query.isEmpty
                    ? FilledButton.icon(
                        onPressed: () => _edit(),
                        icon: const Icon(LucideIcons.plus, size: IconSize.sm),
                        label: const Text('Yeni şablon'),
                      )
                    : null,
              ),
            )
          else
            for (var i = 0; i < filtered.length; i++)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  Space.xs,
                  Space.lg,
                  Space.xs,
                ),
                child: _TemplateCard(
                  key: ValueKey(filtered[i].id),
                  template: filtered[i],
                  toneIndex: i,
                  onTap: () => _edit(filtered[i]),
                  onDelete: () => _delete(filtered[i]),
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _edit([QuickTemplate? template]) async {
    final result = await showModalBottomSheet<QuickTemplate>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // Sheet kendi kulpunu çiziyor; tema kulpu ikinci kez çizilmesin.
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (_) => _TemplateEditorSheet(template: template),
    );
    if (result == null) return;
    await ref.read(quickTemplatesProvider.notifier).addOrUpdate(result);
  }

  Future<void> _delete(QuickTemplate template) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Şablonu sil',
      message: '"${template.title}" şablonunu silmek istiyor musunuz?',
      confirmLabel: 'Sil',
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    await ref.read(quickTemplatesProvider.notifier).remove(template.id);
  }

  Future<void> _reset() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Varsayılanlara sıfırla',
      message:
          'Tüm şablonlarınız silinip yerleşik şablonlar geri yüklenecek. '
          'Devam etmek istiyor musunuz?',
      confirmLabel: 'Sıfırla',
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    await ref.read(quickTemplatesProvider.notifier).reset();
  }
}

/// Üstteki özet kartı: şablon sayısı ve kısa açıklama.
class _Hero extends StatelessWidget {
  const _Hero({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.sm),
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.xl),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            t.accent.withValues(alpha: 0.18),
            t.accent.withValues(alpha: 0.05),
          ],
        ),
        border: Border.all(color: t.accent.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: t.accent,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Icon(
              LucideIcons.zap,
              color: t.onAccentFill,
              size: IconSize.md,
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count == 0 ? 'Hazır yanıtlar' : '$count hazır yanıt',
                  style: text.titleMedium?.copyWith(
                    color: t.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Yeni ileti yazarken tek dokunuşla ekleyin.',
                  style: text.labelSmall?.copyWith(color: t.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    super.key,
    required this.template,
    required this.toneIndex,
    required this.onTap,
    required this.onDelete,
  });

  final QuickTemplate template;
  final int toneIndex;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final tone = t.toneAt(toneIndex);
    return Material(
      color: t.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: t.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.md,
            Space.md,
            Space.xs,
            Space.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: tone.background,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Icon(
                  LucideIcons.fileText,
                  size: IconSize.md,
                  color: tone.foreground,
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            template.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium?.copyWith(
                              color: t.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (template.isBuiltIn) ...[
                          const SizedBox(width: Space.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Space.sm,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: t.accentSubtle,
                              borderRadius: BorderRadius.circular(Radii.full),
                            ),
                            child: Text(
                              'Yerleşik',
                              style: text.labelSmall?.copyWith(
                                color: t.accent,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: Space.xs),
                    Text(
                      _previewText(template.content),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelMedium?.copyWith(
                        color: t.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  LucideIcons.trash2,
                  size: IconSize.sm,
                  color: t.danger,
                ),
                tooltip: 'Şablonu sil',
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Yeni şablon / düzenleme alt sayfası. Kaydedilince [QuickTemplate] döner.
class _TemplateEditorSheet extends StatefulWidget {
  const _TemplateEditorSheet({this.template});

  final QuickTemplate? template;

  @override
  State<_TemplateEditorSheet> createState() => _TemplateEditorSheetState();
}

class _TemplateEditorSheetState extends State<_TemplateEditorSheet> {
  late final _title = TextEditingController(text: widget.template?.title);
  late final _content = TextEditingController(text: widget.template?.content);

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
    _content.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  bool get _valid =>
      _title.text.trim().isNotEmpty && _content.text.trim().isNotEmpty;

  void _save() {
    if (!_valid) return;
    final old = widget.template;
    Navigator.of(context).pop(
      QuickTemplate(
        id: old?.id ?? 'custom-${DateTime.now().millisecondsSinceEpoch}',
        title: _title.text.trim(),
        content: _content.text.trim(),
        isBuiltIn: old?.isBuiltIn ?? false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final isNew = widget.template == null;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    InputDecoration deco(String label, String hint, {bool multiline = false}) =>
        InputDecoration(
          labelText: label,
          hintText: hint,
          alignLabelWithHint: multiline,
          filled: true,
          fillColor: t.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.md),
            borderSide: BorderSide.none,
          ),
        );

    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: Container(
        decoration: BoxDecoration(
          color: t.surfaceElevated,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Radii.xl),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: t.accentSubtle,
                        borderRadius: BorderRadius.circular(Radii.md),
                      ),
                      child: Icon(
                        isNew ? LucideIcons.plus : LucideIcons.pencil,
                        size: IconSize.md,
                        color: t.accent,
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Text(
                        isNew ? 'Yeni şablon' : 'Şablonu düzenle',
                        style: text.titleMedium?.copyWith(
                          color: t.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.md),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _title,
                        autofocus: isNew,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.next,
                        decoration: deco('Başlık', 'Örn: Toplantı onayı'),
                      ),
                      const SizedBox(height: Space.md),
                      TextField(
                        controller: _content,
                        minLines: 6,
                        maxLines: 12,
                        textAlignVertical: TextAlignVertical.top,
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        decoration: deco(
                          'İçerik',
                          'İletiye eklenecek metni yazın…',
                          multiline: true,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: Space.xs),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Text(
                            '${_content.text.length} karakter',
                            style: text.labelSmall?.copyWith(
                              color: t.textTertiary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  Space.md,
                  Space.lg,
                  Space.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Vazgeç'),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: FilledButton(
                        onPressed: _valid ? _save : null,
                        child: const Text('Kaydet'),
                      ),
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
