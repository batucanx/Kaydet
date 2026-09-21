import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/search_providers.dart';
import '../../../domain/models/search_filters.dart';
import '../../../domain/use_cases/folder_mapping.dart';
import '../../core/actions/message_actions.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Arama "Filtreler" sayfası (Outlook'un filtre sayfası gibi): ekli iletiler,
/// silinmiş öğeler ve klasör seçimi.
///
/// Seçimler yerel bir taslakta tutulur ve yalnızca "Uygula" ile
/// [searchFiltersProvider]'a yazılır; geri tuşu değişikliklerden vazgeçer.
///
/// Klasör listesi tek seçimlidir ve bir açılır menü değil bir liste: birden
/// fazla anahtar + uzun bir liste + onay düğmesi içeren, bir popup'a
/// sığmayan çok alanlı bir form.
class SearchFiltersScreen extends ConsumerStatefulWidget {
  const SearchFiltersScreen({super.key});

  @override
  ConsumerState<SearchFiltersScreen> createState() =>
      _SearchFiltersScreenState();
}

class _SearchFiltersScreenState extends ConsumerState<SearchFiltersScreen> {
  late SearchFilters _draft;

  @override
  void initState() {
    super.initState();
    _draft = ref.read(searchFiltersProvider);
  }

  void _setWithAttachmentsOnly(bool value) =>
      setState(() => _draft = _draft.copyWith(withAttachmentsOnly: value));

  void _setIncludeDeleted(bool value) =>
      setState(() => _draft = _draft.copyWith(includeDeleted: value));

  void _selectFolder(SearchFolder? folder) =>
      setState(() => _draft = _draft.copyWith(folder: () => folder));

  void _apply() {
    ref.read(searchFiltersProvider.notifier).apply(_draft);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final options =
        ref.watch(searchFolderOptionsProvider).value ?? const <SearchFolder>[];
    final folder = _draft.folder;
    // "Silinmiş öğeleri dahil et" yalnızca tüm klasörlerde aranırken anlamlı:
    // belirli bir klasör seçiliyken zaten yalnızca o klasör aranır.
    final canIncludeDeleted = folder == null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Filtreler'),
        actions: [
          TextButton(onPressed: _apply, child: const Text('Uygula')),
          const SizedBox(width: Space.xs),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: Space.sm, bottom: Space.huge),
        children: [
          SettingsGroup(
            children: [
              SettingsTile(
                icon: LucideIcons.paperclip,
                title: 'Ekleri Var',
                onTap: () =>
                    _setWithAttachmentsOnly(!_draft.withAttachmentsOnly),
                trailing: Switch(
                  value: _draft.withAttachmentsOnly,
                  onChanged: _setWithAttachmentsOnly,
                ),
              ),
              // Uygulama teması devre dışı bir `Switch`i soluklaştırmıyor;
              // etkisiz olduğu hâlde açık/etkin görünmesin diye satır kısılır.
              Opacity(
                opacity: canIncludeDeleted ? 1 : 0.5,
                child: SettingsTile(
                  icon: LucideIcons.trash2,
                  title: 'Silinmiş Öğeleri Dahil Et',
                  subtitle: canIncludeDeleted
                      ? null
                      : 'Yalnızca tüm klasörlerde aranırken geçerli',
                  onTap: canIncludeDeleted
                      ? () => _setIncludeDeleted(!_draft.includeDeleted)
                      : null,
                  trailing: Switch(
                    value: _draft.includeDeleted,
                    onChanged: canIncludeDeleted ? _setIncludeDeleted : null,
                  ),
                ),
              ),
            ],
          ),
          const SectionHeader('KLASÖR'),
          _FolderOption(
            icon: LucideIcons.folders,
            label: 'Tüm Klasörler',
            selected: folder == null,
            onTap: () => _selectFolder(null),
          ),
          for (final option in options)
            _FolderOption(
              icon: folderIcon(option.use),
              label: FolderMapping.displayName(
                option.use,
                option.customName ?? '',
              ),
              selected: folder == option,
              onTap: () => _selectFolder(option),
            ),
        ],
      ),
    );
  }
}

/// Klasör listesinde tek satır. Seçili satır vurgu renginde ve onay
/// işaretiyle gösterilir (rengin tek başına anlam taşımaması için).
class _FolderOption extends StatelessWidget {
  const _FolderOption({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      leading: Icon(icon),
      title: Text(label),
      trailing: selected
          ? const Icon(LucideIcons.check, size: IconSize.md)
          : null,
      onTap: onTap,
    );
  }
}
