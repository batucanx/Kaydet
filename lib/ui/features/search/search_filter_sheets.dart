import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/search_providers.dart';
import '../../../core/date_format.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/search_filters.dart';
import '../../core/actions/message_actions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import 'search_filter_chips.dart';

/// Filtre alt sayfalarının ortak açılışı: açılış/kapanış hızı `Motion`
/// token'larıyla, görünüm uygulama temasının `bottomSheetTheme`inden gelir.
Future<void> _showFilterSheet(BuildContext context, WidgetBuilder builder) {
  // Klavye açıksa (arama kutusu odakta) sayfa kapanınca geri gelmesin.
  FocusScope.of(context).unfocus();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    sheetAnimationStyle: AnimationStyle(
      duration: context.motion(Motion.base),
      reverseDuration: context.motion(Motion.fast),
      curve: Motion.standard,
    ),
    builder: builder,
  );
}

/// Alt sayfaların ortak çerçevesi: başlık + içerik, klavye payı ve ekranın
/// en çok %75'i kadar yükseklik.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.child, this.actions});

  final String title;
  final Widget child;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.xs,
                Space.sm,
                Space.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  ...?actions,
                ],
              ),
            ),
            Flexible(child: child),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------- tarih

/// "Tarih" alt sayfası: hızlı aralıklar (bir dokunuşta uygulanır) ve elle
/// seçilen başlangıç/bitiş günü ("Bul" ile uygulanır — bitiş günü de
/// seçilebilsin diye). Web'deki tarih açılır penceresiyle aynı kurallar.
Future<void> showSearchDateSheet(BuildContext context, {DateTime? now}) =>
    _showFilterSheet(context, (_) => SearchDateSheet(now: now));

class SearchDateSheet extends ConsumerStatefulWidget {
  const SearchDateSheet({super.key, this.now});

  final DateTime? now;

  @override
  ConsumerState<SearchDateSheet> createState() => _SearchDateSheetState();
}

class _SearchDateSheetState extends ConsumerState<SearchDateSheet> {
  /// Yalnızca tarih alanları kullanılır; ters uç kuralı [SearchFilters]'ta.
  late SearchFilters _draft;
  late final DateTime _now = widget.now ?? DateTime.now();

  /// Postalar 1990'dan eski olamaz; daha eski yıl bir yazım hatasıdır.
  static final _firstDay = DateTime(1990);

  @override
  void initState() {
    super.initState();
    _draft = ref.read(searchFiltersProvider);
  }

  void _apply(SearchFilters dates) {
    final notifier = ref.read(searchFiltersProvider.notifier);
    notifier.apply(
      ref
          .read(searchFiltersProvider)
          .copyWith(dateFrom: () => dates.dateFrom, dateTo: () => dates.dateTo),
    );
    Navigator.of(context).pop();
  }

  void _pickPreset(SearchDatePreset preset) {
    // Etkin hızlı aralığa yeniden dokunmak onu kaldırır.
    final next = _draft.activePreset(_now) == preset
        ? _draft.copyWith(dateFrom: () => null, dateTo: () => null)
        : _draft.withPreset(preset, _now);
    _apply(next);
  }

  Future<void> _pickDay({required bool from}) async {
    final today = searchDay(_now);
    final current = from ? _draft.dateFrom : _draft.dateTo;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? today,
      firstDate: _firstDay,
      lastDate: today,
      helpText: from ? 'Başlangıç günü' : 'Bitiş günü',
    );
    if (picked == null || !mounted) return;
    setState(
      () => _draft = from
          ? _draft.withDateFrom(picked)
          : _draft.withDateTo(picked),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final applied = ref.watch(searchFiltersProvider);
    final changed =
        _draft.dateFrom != applied.dateFrom || _draft.dateTo != applied.dateTo;
    final activePreset = _draft.activePreset(_now);

    return _SheetFrame(
      title: 'Tarih',
      actions: [
        if (_draft.hasDate)
          TextButton(
            onPressed: () => setState(
              () => _draft = _draft.copyWith(
                dateFrom: () => null,
                dateTo: () => null,
              ),
            ),
            child: const Text('Temizle'),
          ),
      ],
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [
                for (final preset in SearchDatePreset.values)
                  ChoiceChip(
                    label: Text(preset.label),
                    selected: activePreset == preset,
                    showCheckmark: false,
                    onSelected: (_) => _pickPreset(preset),
                  ),
              ],
            ),
            const SizedBox(height: Space.lg),
            Row(
              children: [
                Expanded(
                  child: _DayField(
                    label: 'Başlangıç',
                    value: _draft.dateFrom,
                    onTap: () => _pickDay(from: true),
                    onClear: () =>
                        setState(() => _draft = _draft.withDateFrom(null)),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: _DayField(
                    label: 'Bitiş',
                    value: _draft.dateTo,
                    onTap: () => _pickDay(from: false),
                    onClear: () =>
                        setState(() => _draft = _draft.withDateTo(null)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Yalnızca başlangıç seçerseniz o günden sonrası, yalnızca bitiş '
              'seçerseniz o günden öncesi aranır.',
              style: AppText.labelSmall.copyWith(color: t.textTertiary),
            ),
            const SizedBox(height: Space.lg),
            FilledButton(
              onPressed: _draft.hasDate && changed
                  ? () => _apply(_draft)
                  : null,
              child: const Text('Bul'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayField extends StatelessWidget {
  const _DayField({
    required this.label,
    required this.value,
    required this.onTap,
    required this.onClear,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final day = value;
    return Semantics(
      button: true,
      label: day == null
          ? '$label günü seç'
          : '$label günü ${formatDayNumeric(day)}',
      excludeSemantics: true,
      child: Material(
        color: t.surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(color: t.border),
        ),
        child: InkWell(
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.md,
              Space.sm,
              Space.xs,
              Space.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: AppText.labelSmall.copyWith(
                          color: t.textTertiary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        day == null ? 'gg.aa.yyyy' : formatDayNumeric(day),
                        style: AppText.bodyMedium.copyWith(
                          color: day == null ? t.textTertiary : t.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (day == null)
                  Padding(
                    padding: const EdgeInsets.all(Space.sm),
                    child: Icon(
                      LucideIcons.calendarDays,
                      size: IconSize.sm,
                      color: t.textSecondary,
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(LucideIcons.x, size: IconSize.sm),
                    tooltip: '$label gününü kaldır',
                    visualDensity: VisualDensity.compact,
                    onPressed: onClear,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ klasör

/// "Klasörler" alt sayfası: tek seçimli liste; seçim anında uygulanır ve sayfa
/// kapanır (web'deki `FolderPicker` gibi).
Future<void> showSearchFolderSheet(BuildContext context) =>
    _showFilterSheet(context, (_) => const SearchFolderSheet());

class SearchFolderSheet extends ConsumerWidget {
  const SearchFolderSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options =
        ref.watch(searchFolderOptionsProvider).value ?? const <SearchFolder>[];
    final filters = ref.watch(searchFiltersProvider);
    final selected = filters.folder;

    void pick(SearchFolder? folder) {
      ref
          .read(searchFiltersProvider.notifier)
          .apply(filters.copyWith(folder: () => folder));
      Navigator.of(context).pop();
    }

    return _SheetFrame(
      title: 'Klasörler',
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: Space.lg),
        children: [
          _OptionTile(
            icon: LucideIcons.folders,
            label: 'Tüm Klasörler',
            selected: selected == null,
            onTap: () => pick(null),
          ),
          for (final option in options)
            _OptionTile(
              icon: folderIcon(option.use),
              label: searchFolderLabel(option),
              selected: selected == option,
              onTap: () => pick(option),
            ),
        ],
      ),
    );
  }
}

/// Seçili satır vurgu renginde ve onay işaretiyle gösterilir (rengin tek
/// başına anlam taşımaması için).
class _OptionTile extends StatelessWidget {
  const _OptionTile({
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
  Widget build(BuildContext context) => ListTile(
    selected: selected,
    leading: Icon(icon),
    title: Text(label),
    trailing: selected
        ? const Icon(LucideIcons.check, size: IconSize.md)
        : null,
    onTap: onTap,
  );
}

// ------------------------------------------------------------------- kişi

/// "Gönderen" ve "Alıcı" çiplerinin kişi seçicisi.
enum SearchPeopleKind {
  sender('Gönderen'),
  recipient('Alıcı');

  const SearchPeopleKind(this.title);

  final String title;
}

/// "Gönderen" / "Alıcı" alt sayfası: üstte bir alan (kişileri daraltmak için
/// yazın ya da tam bir adres yazıp onaylayın), altında kişiler; seçili olan
/// onay işaretli. Bir çip için tek kişi seçilir: başka birine dokunmak
/// seçimi değiştirir, seçiliye dokunmak geri alır. Seçim anında uygulanır.
Future<void> showSearchPeopleSheet(
  BuildContext context,
  SearchPeopleKind kind,
) => _showFilterSheet(context, (_) => SearchPeopleSheet(kind: kind));

class SearchPeopleSheet extends ConsumerStatefulWidget {
  const SearchPeopleSheet({super.key, required this.kind});

  final SearchPeopleKind kind;

  @override
  ConsumerState<SearchPeopleSheet> createState() => _SearchPeopleSheetState();
}

class _SearchPeopleSheetState extends ConsumerState<SearchPeopleSheet> {
  final _controller = TextEditingController();
  String _text = '';

  static final _address = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? get _selected {
    final filters = ref.read(searchFiltersProvider);
    return widget.kind == SearchPeopleKind.sender
        ? filters.sender
        : filters.recipient;
  }

  void _toggle(String email) {
    final filters = ref.read(searchFiltersProvider);
    final next = _selected == email ? null : email;
    ref
        .read(searchFiltersProvider.notifier)
        .apply(
          widget.kind == SearchPeopleKind.sender
              ? filters.copyWith(sender: () => next)
              : filters.copyWith(recipient: () => next),
        );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final query = _text.trim();
    final needle = query.toLowerCase();
    final chosen = ref.watch(
      searchFiltersProvider.select(
        (f) => widget.kind == SearchPeopleKind.sender ? f.sender : f.recipient,
      ),
    );
    final contacts =
        ref.watch(searchPeopleProvider(query)).value ?? const <ContactRow>[];

    // Seçili kişi üstte durur (kolay geri alınır), ardından eşleşen kişiler;
    // "Tüm Hesaplar" kapsamında aynı adres birden fazla hesapta olabilir.
    final rows = <({String email, String name})>[];
    final seen = <String>{};
    void add(String email, String name) {
      final key = email.toLowerCase();
      if (seen.add(key)) rows.add((email: key, name: name));
    }

    if (chosen != null) {
      final known = contacts.where((c) => c.email.toLowerCase() == chosen);
      final name = known.isEmpty ? '' : known.first.name;
      if (needle.isEmpty ||
          chosen.contains(needle) ||
          name.toLowerCase().contains(needle)) {
        add(chosen, name);
      }
    }
    for (final contact in contacts) {
      add(contact.email, contact.name);
    }
    final typed = _address.hasMatch(query) && !seen.contains(needle)
        ? needle
        : null;
    if (typed != null) add(typed, '');

    return _SheetFrame(
      title: widget.kind.title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
            child: TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                hintText: 'Ad veya e-posta yazın',
                prefixIcon: Icon(LucideIcons.search, size: IconSize.md),
              ),
              onChanged: (value) => setState(() => _text = value),
              onSubmitted: (value) {
                final address = value.trim().toLowerCase();
                if (_address.hasMatch(address)) {
                  _toggle(address);
                } else if (rows.isNotEmpty) {
                  _toggle(rows.first.email);
                }
              },
            ),
          ),
          Flexible(
            child: rows.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(Space.xl),
                    child: Text(
                      'Eşleşen kişi yok. Tam bir e-posta adresi yazarak da '
                      'seçebilirsiniz.',
                      textAlign: TextAlign.center,
                      style: AppText.bodyMedium.copyWith(
                        color: t.textSecondary,
                      ),
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.only(bottom: Space.lg),
                    children: [
                      for (final person in rows)
                        ListTile(
                          selected: person.email == chosen,
                          leading: BrandAvatar(
                            name: person.name,
                            email: person.email,
                            size: 36,
                          ),
                          title: Text(
                            person.name.isEmpty ? person.email : person.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: person.name.isEmpty
                              ? null
                              : Text(
                                  person.email,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: person.email == chosen
                              ? const Icon(LucideIcons.check, size: IconSize.md)
                              : null,
                          onTap: () => _toggle(person.email),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
