import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/search_providers.dart';
import '../../../core/date_format.dart';
import '../../../domain/models/search_filters.dart';
import '../../../domain/use_cases/folder_mapping.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import 'search_filter_sheets.dart';

/// Arama filtre çipleri: Ekli · Dosyalar · Tarih · Klasörler · Gönderen ·
/// Alıcı (web istemcisindeki `SearchFilterChips`; "Dosyalar" mobile özgü).
///
/// Tek satır, yatay kaydırılır. Seçilen değer çipin üstünde okunur
/// (`Klasörler: Gelen Kutusu`, `Tarih: Son 7 gün`, `Gönderen: ada@x.com`) ve
/// her etkin çipin kendi × düğmesi yalnızca o filtreyi geri alır. "Ekli"
/// dokununca açılıp kapanır; diğerleri bir alt sayfa açar ve seçim yapılınca
/// aramaya anında uygulanır (bkz. [searchFiltersProvider]).
class SearchFilterChips extends ConsumerWidget {
  const SearchFilterChips({super.key, this.now});

  /// Yalnızca testlerde: "Tarih" etiketinin göreli günlerini sabitler.
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(searchFiltersProvider);
    final notifier = ref.read(searchFiltersProvider.notifier);
    final today = now ?? DateTime.now();

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        children: [
          _FilterChip(
            icon: LucideIcons.paperclip,
            label: 'Ekli',
            active: filters.withAttachmentsOnly,
            onTap: () => notifier.apply(
              filters.copyWith(
                withAttachmentsOnly: !filters.withAttachmentsOnly,
              ),
            ),
          ),
          // Ek (dosya) listesi: sonuçlar ileti yerine ekler olur. Web'de yok;
          // mobilde ayrı bir "Dosyalar" sekmesinin yerini alır.
          _FilterChip(
            icon: LucideIcons.files,
            label: 'Dosyalar',
            active: filters.filesOnly,
            onTap: () =>
                notifier.apply(filters.copyWith(filesOnly: !filters.filesOnly)),
          ),
          _FilterChip(
            icon: LucideIcons.calendarDays,
            label: filters.hasDate
                ? 'Tarih: ${describeSearchDateFilter(filters, today)}'
                : 'Tarih',
            active: filters.hasDate,
            onTap: () => showSearchDateSheet(context),
            onClear: () => notifier.apply(
              filters.copyWith(dateFrom: () => null, dateTo: () => null),
            ),
          ),
          _FilterChip(
            icon: LucideIcons.folder,
            label: filters.folder == null
                ? 'Klasörler'
                : 'Klasörler: ${searchFolderLabel(filters.folder!)}',
            active: filters.folder != null,
            onTap: () => showSearchFolderSheet(context),
            onClear: () => notifier.apply(filters.copyWith(folder: () => null)),
          ),
          _FilterChip(
            icon: LucideIcons.user,
            label: filters.sender == null
                ? 'Gönderen'
                : 'Gönderen: ${filters.sender}',
            active: filters.sender != null,
            onTap: () =>
                showSearchPeopleSheet(context, SearchPeopleKind.sender),
            onClear: () => notifier.apply(filters.copyWith(sender: () => null)),
          ),
          _FilterChip(
            icon: LucideIcons.user,
            label: filters.recipient == null
                ? 'Alıcı'
                : 'Alıcı: ${filters.recipient}',
            active: filters.recipient != null,
            onTap: () =>
                showSearchPeopleSheet(context, SearchPeopleKind.recipient),
            onClear: () =>
                notifier.apply(filters.copyWith(recipient: () => null)),
          ),
          if (filters.isActive)
            Padding(
              padding: const EdgeInsets.only(left: Space.xs),
              child: TextButton(
                onPressed: notifier.clear,
                child: const Text('Filtreleri temizle'),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Tarih" çipinin metni: hızlı aralığın adı ya da seçilen günler (web'deki
/// `describeDateFilter`).
String describeSearchDateFilter(SearchFilters filters, DateTime now) {
  final preset = filters.activePreset(now);
  if (preset != null) return preset.label;
  final from = filters.dateFrom;
  final to = filters.dateTo;
  if (from != null && to != null) {
    return from == to
        ? formatShortDay(from, now: now)
        : '${formatShortDay(from, now: now)} – ${formatShortDay(to, now: now)}';
  }
  if (from != null) return '${formatShortDay(from, now: now)} ve sonrası';
  return '${formatShortDay(to!, now: now)} ve öncesi';
}

/// Klasör seçeneğinin kullanıcıya görünen adı.
String searchFolderLabel(SearchFolder folder) =>
    FolderMapping.displayName(folder.use, folder.customName ?? '');

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.onClear,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  /// Etkin çipin × düğmesi; `null` ise çipin kendisi aç/kapa görevi görür.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final foreground = active ? t.accent : t.textSecondary;
    final showClear = active && onClear != null;

    return Padding(
      padding: const EdgeInsets.only(right: Space.sm),
      child: Semantics(
        button: true,
        selected: active,
        child: Material(
          color: active ? t.accentSubtle : t.surfaceElevated,
          shape: StadiumBorder(
            side: BorderSide(color: active ? t.accent : t.border),
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.only(
                left: Space.md,
                right: showClear ? Space.xs : Space.md,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: IconSize.sm, color: foreground),
                  const SizedBox(width: Space.xs),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 190),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.labelMedium.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (showClear)
                    InkResponse(
                      onTap: onClear,
                      radius: 16,
                      child: Padding(
                        padding: const EdgeInsets.all(Space.xs),
                        child: Icon(
                          LucideIcons.x,
                          size: IconSize.sm,
                          color: foreground,
                          semanticLabel: '$label filtresini kaldır',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
