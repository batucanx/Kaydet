import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/filter_providers.dart';
import '../../../app/providers.dart';
import '../../../data/database/app_database.dart';
import '../../../data/repositories/mail_filter_repository.dart';
import '../../../domain/models/mail_filter.dart';
import '../../../domain/models/mail_models.dart' show EmailAddress, SpecialUse;
import '../../../domain/use_cases/filter_rules.dart';
import '../../../domain/use_cases/settings_document.dart'
    show isSettingsMailbox;
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_notice.dart';
import 'filter_text.dart';
import 'filters_settings_screen.dart' show filterFolderLabel;

class _CondRow {
  _CondRow(this.key, this.condition)
    : value = TextEditingController(text: condition.value);
  final int key;
  FilterCondition condition;
  final TextEditingController value;
}

class _ActRow {
  _ActRow(this.key, FilterAction action)
    : type = action.type,
      folderId = (action.folderId ?? 0) > 0 ? action.folderId : null,
      labelId = (action.labelId ?? 0) > 0 ? action.labelId : null,
      email = TextEditingController(text: action.email ?? '');
  final int key;
  FilterActionType type;
  int? folderId;
  int? labelId;
  final TextEditingController email;

  FilterAction toAction() => switch (type) {
    FilterActionType.move => FilterAction.move(folderId ?? 0),
    FilterActionType.label => FilterAction.label(labelId ?? 0),
    FilterActionType.forward => FilterAction.forward(email.text),
    _ => FilterAction.blank(type),
  };
}

/// Filtre düzenleyici: ad → koşullar (HEPSİ / HERHANGİ BİRİ) → işlemler → anahtarlar, ve seçili bir iletide "Filtreyi test et".
/// Doğrulama mesajları ve kuralları web düzenleyicisiyle aynıdır (bkz. `validateFilterForSave`).
class FilterEditorScreen extends ConsumerStatefulWidget {
  const FilterEditorScreen({super.key, this.initial});

  /// `null` yeni filtre oluşturur.
  final MailFilter? initial;

  @override
  ConsumerState<FilterEditorScreen> createState() => _FilterEditorScreenState();
}

class _FilterEditorScreenState extends ConsumerState<FilterEditorScreen> {
  late final TextEditingController _name;
  late FilterMatchMode _mode;
  late final List<_CondRow> _conditions;
  late final List<_ActRow> _actions;
  late bool _stop;
  int _keys = 0;

  /// Alan yolu (`conditions.0.value`, `actions.1`, `actions.1.email`) → mesaj.
  Map<String, String> _errors = const {};
  String? _formError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final f = widget.initial;
    _name = TextEditingController(text: f?.name ?? '');
    _mode = f?.matchMode ?? FilterMatchMode.all;
    _stop = f?.stopProcessing ?? false;
    _conditions = [
      for (final c in f?.conditions ?? [blankCondition(fieldChoices.first)])
        _CondRow(_keys++, c),
    ];
    _actions = [
      for (final a in f?.actions ?? [FilterAction.blank(FilterActionType.move)])
        _ActRow(_keys++, a),
    ];
  }

  @override
  void dispose() {
    _name.dispose();
    for (final c in _conditions) {
      c.value.dispose();
    }
    for (final a in _actions) {
      a.email.dispose();
    }
    super.dispose();
  }

  FilterDefinition _definition() => FilterDefinition(
    name: _name.text.trim(),
    enabled: widget.initial?.enabled ?? true,
    matchMode: _mode,
    conditions: [
      for (final c in _conditions)
        c.condition.hasValue
            ? c.condition.copyWith(value: c.value.text)
            : c.condition,
    ],
    actions: [for (final a in _actions) a.toAction()],
    stopProcessing: _stop,
  );

  Set<String> _ownAddresses() {
    final own = normalizeMailAddress(
      ref.read(activeAccountProvider).value?.email,
    );
    return own == null ? const {} : {own};
  }

  /// Düzenleyicinin kendi (erken) denetimi: web düzenleyicisiyle aynı sıra ve cümleler.
  Map<String, String> _problems() {
    final found = <String, String>{};
    for (var i = 0; i < _conditions.length; i++) {
      final c = _conditions[i];
      if (c.condition.hasValue && c.value.text.trim().isEmpty) {
        found['conditions.$i.value'] = 'Bir değer girin.';
      }
    }
    for (var i = 0; i < _actions.length; i++) {
      final a = _actions[i];
      if (a.type == FilterActionType.move && a.folderId == null) {
        found['actions.$i'] = 'Bir klasör seçin.';
      }
      if (a.type == FilterActionType.label && a.labelId == null) {
        found['actions.$i'] = 'Bir etiket seçin.';
      }
      if (a.type == FilterActionType.forward &&
          !EmailAddress.isValidEmail(a.email.text)) {
        found['actions.$i.email'] = 'Geçerli bir e-posta adresi girin.';
      }
    }
    if (found.isNotEmpty) return found;
    for (final v in validateFilterForSave(
      _definition(),
      ownAddresses: _ownAddresses(),
    )) {
      found.putIfAbsent(v.field, () => violationText(v));
    }
    return found;
  }

  void _edited(VoidCallback change) {
    setState(() {
      change();
      _errors = const {};
      _formError = null;
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    final accountId = ref.read(accountIdProvider);
    if (accountId == null) return;
    final found = _problems();
    if (found.isNotEmpty) {
      setState(() {
        _errors = found;
        _formError = 'Filtre kaydedilemedi. İşaretli alanları kontrol edin.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _formError = null;
    });
    final repo = ref.read(mailFilterRepositoryProvider);
    final initial = widget.initial;
    final result = initial == null
        ? await repo.add(
            accountId,
            _definition(),
            ownAddresses: _ownAddresses(),
          )
        : await repo.update(
            accountId,
            initial.id,
            _definition(),
            ownAddresses: _ownAddresses(),
          );
    if (!mounted) return;
    if (result.ok) {
      KaydetNotice.show(
        Overlay.of(context),
        message: initial == null ? 'Filtre oluşturuldu.' : 'Filtre kaydedildi.',
      );
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      if (result.limitReached) {
        _formError = 'En fazla $filterMaxPerAccount filtre oluşturabilirsiniz.';
      } else if (result.notFound) {
        _formError = 'Bu filtre artık yok. Listeye dönüp yeniden deneyin.';
      } else {
        _errors = {
          for (final v in result.violations) v.field: violationText(v),
        };
        _formError = 'Filtre kaydedilemedi. İşaretli alanları kontrol edin.';
      }
    });
  }

  /// Bir filtrenin taşıyabileceği klasörler: elle taşımayla aynı kural (Gelen Kutusu, Taslak, Gönderilmiş, Çöp ve İstenmeyen
  /// değil; bunların kendi eylemleri vardır) ve seçilebilir, gizli ayar klasörü dışında.
  List<MailboxRow> _targets(List<MailboxRow> all) => [
    for (final m in all)
      if ((m.specialUse == SpecialUse.custom ||
              m.specialUse == SpecialUse.archive) &&
          m.isSelectable &&
          !isSettingsMailbox(m.path, m.delimiter))
        m,
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    final mailboxes = ref.watch(mailboxesProvider).value ?? const [];
    final labels = ref.watch(labelsProvider).value ?? const <LabelRow>[];
    final targets = _targets(mailboxes);
    final creating = widget.initial == null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          tooltip: 'Geri',
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        title: Text(creating ? 'Filtre oluştur' : 'Filtreyi düzenle'),
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Space.lg,
            Space.md,
            Space.lg,
            Space.huge,
          ),
          children: [
            TextField(
              controller: _name,
              maxLength: filterNameMaxLength,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Filtre adı',
                hintText: 'İsteğe bağlı',
                counterText: '',
              ),
              onChanged: (_) => _edited(() {}),
            ),
            const SizedBox(height: Space.lg),
            Semantics(
              header: true,
              child: Text(
                'Koşullar',
                style: theme.textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: Space.sm),
            _Pick<FilterMatchMode>(
              label: 'Eşleşme',
              value: _mode,
              items: const [
                (FilterMatchMode.all, 'tümü sağlandığında'),
                (FilterMatchMode.any, 'herhangi biri sağlandığında'),
              ],
              onChanged: (v) => _edited(() => _mode = v),
            ),
            const SizedBox(height: Space.sm),
            for (var i = 0; i < _conditions.length; i++)
              _ConditionCard(
                key: ValueKey(_conditions[i].key),
                index: i,
                row: _conditions[i],
                error:
                    _errors['conditions.$i.value'] ?? _errors['conditions.$i'],
                canRemove: _conditions.length > 1,
                onChanged: (fn) => _edited(fn),
                onRemove: () => _edited(() {
                  _conditions.removeAt(i).value.dispose();
                }),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(LucideIcons.plus, size: IconSize.sm),
                label: const Text('Koşul ekle'),
                onPressed: _conditions.length >= filterMaxConditions
                    ? null
                    : () => _edited(
                        () => _conditions.add(
                          _CondRow(_keys++, blankCondition(fieldChoices.first)),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: Space.md),
            Semantics(
              header: true,
              child: Text(
                'İşlemler',
                style: theme.textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: Space.sm),
            for (var i = 0; i < _actions.length; i++)
              _ActionCard(
                key: ValueKey(_actions[i].key),
                index: i,
                row: _actions[i],
                folders: targets,
                labels: labels,
                error:
                    _errors['actions.$i.email'] ??
                    _errors['actions.$i.folderId'] ??
                    _errors['actions.$i'],
                canRemove: _actions.length > 1,
                onChanged: (fn) => _edited(fn),
                onRemove: () => _edited(() {
                  _actions.removeAt(i).email.dispose();
                }),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(LucideIcons.plus, size: IconSize.sm),
                label: const Text('İşlem ekle'),
                onPressed: _actions.length >= filterMaxActions
                    ? null
                    : () => _edited(
                        () => _actions.add(
                          _ActRow(
                            _keys++,
                            FilterAction.blank(FilterActionType.label),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: Space.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Bu filtre eşleştiğinde diğer filtreleri çalıştırma',
              ),
              value: _stop,
              onChanged: (v) => _edited(() => _stop = v),
            ),
            const SizedBox(height: Space.sm),
            _FilterTester(
              accountId: ref.watch(accountIdProvider),
              definition: _definition,
            ),
            const SizedBox(height: Space.lg),
            if (_formError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.md),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _formError!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: t.danger,
                    ),
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Vazgeç'),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _save,
                    child: Text(
                      _busy
                          ? 'Kaydediliyor…'
                          : (creating ? 'Filtreyi oluştur' : 'Filtreyi kaydet'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Bir açılır menü: etiketli, yapılandırılmış alan.
class _Pick<T> extends StatelessWidget {
  const _Pick({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.error,
    this.fieldKey,
  });

  final String label;
  final T? value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;
  final String? error;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      key: fieldKey,
      decoration: InputDecoration(labelText: label, errorText: error),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isExpanded: true,
          isDense: true,
          value: value,
          hint: const Text('Seçin'),
          items: [
            for (final (v, text) in items)
              DropdownMenuItem<T>(
                value: v,
                child: Text(text, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

BoxDecoration _rowDecoration(KaydetTokens t) => BoxDecoration(
  color: t.surface,
  borderRadius: BorderRadius.circular(Radii.md),
  border: Border.all(color: t.divider),
);

class _ConditionCard extends StatelessWidget {
  const _ConditionCard({
    super.key,
    required this.index,
    required this.row,
    required this.error,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final _CondRow row;
  final String? error;
  final bool canRemove;
  final void Function(VoidCallback change) onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = row.condition;
    final choice = fieldChoiceOf(c);
    final n = index + 1;
    return Container(
      margin: const EdgeInsets.only(bottom: Space.sm),
      padding: const EdgeInsets.all(Space.md),
      decoration: _rowDecoration(t),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _Pick<String>(
                  label: 'Alan',
                  value: choice.key,
                  items: [for (final f in fieldChoices) (f.key, f.label)],
                  onChanged: (key) => onChanged(() {
                    final next = fieldChoices.firstWhere((f) => f.key == key);
                    final current = row.condition.copyWith(
                      value: row.value.text,
                    );
                    row.condition = changeField(current, next);
                    row.value.text = row.condition.value;
                  }),
                ),
              ),
              IconButton(
                icon: const Icon(LucideIcons.x, size: IconSize.md),
                tooltip: 'Koşul $n’i kaldır',
                onPressed: canRemove ? onRemove : null,
              ),
            ],
          ),
          if (c.hasValue) ...[
            const SizedBox(height: Space.sm),
            _Pick<FilterOperator>(
              label: 'İşleç',
              value: c.operator,
              items: [
                for (final op in operatorsFor(c.field)) (op, operatorLabel(op)),
              ],
              onChanged: (op) => onChanged(
                () => row.condition = row.condition.copyWith(operator: op),
              ),
            ),
            const SizedBox(height: Space.sm),
            TextField(
              controller: row.value,
              maxLength: filterValueMaxLength,
              autocorrect: false,
              keyboardType:
                  c.field == FilterField.subject || c.field == FilterField.body
                  ? TextInputType.text
                  : TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Değer',
                hintText: c.field == FilterField.subject
                    ? 'Örn: Fatura'
                    : c.field == FilterField.body
                    ? 'Aranacak metin'
                    : 'Örn: fatura@example.com',
                counterText: '',
                errorText: error,
              ),
              onChanged: (_) => onChanged(() {}),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.index,
    required this.row,
    required this.folders,
    required this.labels,
    required this.error,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final _ActRow row;
  final List<MailboxRow> folders;
  final List<LabelRow> labels;
  final String? error;
  final bool canRemove;
  final void Function(VoidCallback change) onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    final n = index + 1;
    final folderKnown =
        row.folderId == null || folders.any((f) => f.id == row.folderId);
    final labelKnown =
        row.labelId == null || labels.any((l) => l.id == row.labelId);
    return Container(
      margin: const EdgeInsets.only(bottom: Space.sm),
      padding: const EdgeInsets.all(Space.md),
      decoration: _rowDecoration(t),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _Pick<FilterActionType>(
                  label: 'İşlem',
                  value: row.type,
                  items: [
                    for (final a in actionChoices) (a.type, a.label),
                    if (row.type == FilterActionType.forward)
                      (forwardChoice.type, forwardChoice.label),
                  ],
                  onChanged: (type) => onChanged(() {
                    row.type = type;
                    row.folderId = null;
                    row.labelId = null;
                    row.email.clear();
                  }),
                ),
              ),
              IconButton(
                icon: const Icon(LucideIcons.x, size: IconSize.md),
                tooltip: 'İşlem $n’i kaldır',
                onPressed: canRemove ? onRemove : null,
              ),
            ],
          ),
          if (row.type == FilterActionType.move) ...[
            const SizedBox(height: Space.sm),
            _Pick<int>(
              label: 'Klasör',
              value: row.folderId,
              error: error,
              items: [
                for (final f in folders) (f.id, filterFolderLabel(f)),
                if (!folderKnown) (row.folderId!, '(kullanılamayan klasör)'),
              ],
              onChanged: (id) => onChanged(() => row.folderId = id),
            ),
          ],
          if (row.type == FilterActionType.label) ...[
            const SizedBox(height: Space.sm),
            _Pick<int>(
              label: 'Etiket',
              value: row.labelId,
              error: error,
              items: [
                for (final l in labels) (l.id, l.name),
                if (!labelKnown) (row.labelId!, '(kullanılamayan etiket)'),
              ],
              onChanged: (id) => onChanged(() => row.labelId = id),
            ),
          ],
          if (row.type == FilterActionType.forward) ...[
            const SizedBox(height: Space.sm),
            TextField(
              controller: row.email,
              autocorrect: false,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'E-posta adresi',
                hintText: 'muhasebe@example.com',
                errorText: error,
              ),
              onChanged: (_) => onChanged(() {}),
            ),
          ],
          if (row.type != FilterActionType.move &&
              row.type != FilterActionType.label &&
              row.type != FilterActionType.forward &&
              error != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  error!,
                  style: theme.textTheme.bodySmall?.copyWith(color: t.danger),
                ),
              ),
            ),
          if (row.type == FilterActionType.delete)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    LucideIcons.triangleAlert,
                    size: IconSize.sm,
                    color: t.warning,
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      'İleti kalıcı olarak silinir, geri alınamaz.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: t.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// "Filtreyi test et": filtrenin KOŞULLARINI Gelen Kutusu'ndaki son iletilerden biriyle dener. Hiçbir şey değişmez ve ağa
/// çıkılmaz; gövde yalnızca cihazda önbellekteyse okunur (okunamazsa gövde koşulları eşleşmedi sayılır).
class _FilterTester extends ConsumerStatefulWidget {
  const _FilterTester({required this.accountId, required this.definition});

  final int? accountId;
  final FilterDefinition Function() definition;

  @override
  ConsumerState<_FilterTester> createState() => _FilterTesterState();
}

enum _Load { idle, loading, error, ready }

class _FilterTesterState extends ConsumerState<_FilterTester> {
  bool _open = false;
  _Load _load = _Load.idle;
  List<FilterPreviewMessage> _messages = const [];
  int? _messageId;
  bool _running = false;
  String? _error;
  FilterEvaluation? _result;
  List<FilterCondition> _tested = const [];

  Future<void> _openPanel() async {
    setState(() {
      _open = true;
      _load = _Load.loading;
    });
    final accountId = widget.accountId;
    if (accountId == null) {
      setState(() => _load = _Load.error);
      return;
    }
    try {
      final list = await ref
          .read(mailFilterRepositoryProvider)
          .previewMessages(accountId);
      if (!mounted) return;
      setState(() {
        _messages = list;
        _messageId = list.isEmpty ? null : list.first.id;
        _load = _Load.ready;
      });
    } on Object {
      if (mounted) setState(() => _load = _Load.error);
    }
  }

  bool _ready(FilterDefinition d) =>
      d.conditions.every((c) => !c.hasValue || c.value.trim().isNotEmpty);

  Future<void> _run() async {
    final id = _messageId;
    if (id == null || _running) return;
    final d = widget.definition();
    if (!_ready(d)) return;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final conditions = [
        for (final c in d.conditions)
          c.hasValue ? c.copyWith(value: c.value.trim()) : c,
      ];
      final needsBody = filterNeedsBody(conditions);
      final mail = await ref
          .read(mailFilterRepositoryProvider)
          .loadFilterableMail(id, withBody: needsBody);
      if (!mounted) return;
      if (mail == null) {
        setState(() {
          _running = false;
          _error = 'Filtre test edilemedi.';
        });
        return;
      }
      setState(() {
        _running = false;
        _tested = conditions;
        _result = evaluateFilter(d.matchMode, conditions, mail);
      });
    } on Object {
      if (mounted) {
        setState(() {
          _running = false;
          _error = 'Filtre test edilemedi.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    if (!_open) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(LucideIcons.flaskConical, size: IconSize.sm),
          label: const Text('Filtreyi test et'),
          onPressed: _openPanel,
        ),
      );
    }
    final d = widget.definition();
    final ready = _ready(d);
    final result = _result;
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: _rowDecoration(t),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text('Filtreyi test et', style: theme.textTheme.titleSmall),
          ),
          const SizedBox(height: Space.sm),
          if (_load == _Load.loading)
            Text(
              'E-postalar yükleniyor…',
              style: theme.textTheme.bodySmall?.copyWith(color: t.textTertiary),
            ),
          if (_load == _Load.error)
            Text(
              'E-postalar yüklenemedi.',
              style: theme.textTheme.bodySmall?.copyWith(color: t.danger),
            ),
          if (_load == _Load.ready && _messages.isEmpty)
            Text(
              'Gelen kutusunda test edilecek e-posta yok.',
              style: theme.textTheme.bodySmall?.copyWith(color: t.textTertiary),
            ),
          if (_load == _Load.ready && _messages.isNotEmpty) ...[
            _Pick<int>(
              label: 'Test edilecek e-posta',
              value: _messageId,
              items: [
                for (final m in _messages)
                  (
                    m.id,
                    '${(m.sender.isEmpty ? 'Bilinmeyen gönderen' : m.sender).characters.take(40)} — '
                        '${m.subject.isEmpty ? '(konu yok)' : m.subject}',
                  ),
              ],
              onChanged: (id) => setState(() {
                _messageId = id;
                _result = null;
              }),
            ),
            const SizedBox(height: Space.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, Dimens.controlHeight),
                  padding: const EdgeInsets.symmetric(horizontal: Space.xl),
                ),
                onPressed: _running || !ready ? null : _run,
                child: Text(_running ? 'Test ediliyor…' : 'Test et'),
              ),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(color: t.danger),
              ),
            ),
          if (result != null)
            Semantics(
              liveRegion: true,
              container: true,
              child: Padding(
                padding: const EdgeInsets.only(top: Space.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < result.conditions.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Space.xs),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              result.conditions[i]
                                  ? LucideIcons.check
                                  : LucideIcons.x,
                              size: IconSize.sm,
                              color: result.conditions[i]
                                  ? t.success
                                  : t.danger,
                            ),
                            const SizedBox(width: Space.sm),
                            Expanded(
                              child: Text(
                                '${describeCondition(_tested[i])}: '
                                '${result.conditions[i] ? 'eşleşti' : 'eşleşmedi'}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: Space.xs),
                    Text(
                      result.matched
                          ? 'Bu e-posta filtreyle eşleşiyor.'
                          : 'Bu e-posta filtreyle eşleşmiyor.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: result.matched ? t.success : t.textSecondary,
                      ),
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
