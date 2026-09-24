import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../app/sync_controller.dart';
import '../../../core/result.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../../domain/use_cases/folder_mapping.dart';
import '../../core/actions/message_actions.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';

/// Klasör Yönetimi: Navigation Drawer'daki pencil/Düzenle ikonuyla açılır
/// (bkz. `FolderDrawer._manageFolders`).
///
/// Kasıtlı olarak SEARCH YOK — klasör bulmak doğrudan liste + yıldız +
/// sürükle-bırak + "Klasör Oluştur" üzerinden yapılır. Tek doğruluk kaynağı
/// her zaman `mailboxesForAccountProvider`dır (Drawer'ın kendisiyle aynı) —
/// burada yapılan her değişiklik (yıldız, sıra, yeni klasör) doğrudan
/// veritabanına yazılır ve Drawer o akıştan kendiliğinden güncellenir; ayrı
/// bir paralel state YOKTUR.
class FolderManagementScreen extends ConsumerStatefulWidget {
  const FolderManagementScreen({super.key});

  @override
  ConsumerState<FolderManagementScreen> createState() =>
      _FolderManagementScreenState();
}

class _FolderManagementScreenState
    extends ConsumerState<FolderManagementScreen> {
  /// Sürükleme/yıldız dokunuşu sonrası anlık yansıyan iyimser (optimistic)
  /// tam klasör sırası. `null` iken ekran doğrudan
  /// `mailboxesForAccountProvider`u izler.
  ///
  /// `ReorderableListView.onReorderItem` sözleşmesi, çağrı sırasında
  /// ALTINDAKİ veri kaynağının SENKRON olarak yeni sırayı yansıtmasını
  /// gerektirir —
  /// yoksa sürüklenen öğe eski konumuna "geri sıçrar" ve bir kare sonra
  /// veritabanı yazması bitince yeniden yeni konumuna atlar. Bu yüzden yeni
  /// sıra önce burada `setState` ile anında gösterilir, kalıcı yazma arka
  /// planda sürer; veritabanından gelen akış tam olarak bu sırayı
  /// doğruladığında (bkz. [_reconcileWithProvider]) bu alan `null`a döner ve
  /// ekran tekrar doğrudan akışı izlemeye başlar.
  List<MailboxRow>? _optimisticOrder;
  int? _optimisticAccountId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(syncControllerProvider.notifier).syncFolders(force: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final accountId = ref.watch(accountIdProvider);
    final providerFolders = accountId == null
        ? const <MailboxRow>[]
        : ref.watch(mailboxesForAccountProvider(accountId)).value ??
              const <MailboxRow>[];
    // Drawer'da zaten yalnızca seçilebilir klasörler gösterilir (bkz.
    // `_AccountFolderPanelContent`) — burada favorilenen/sıralanan bir
    // klasör Drawer'da hiç görünmeyecekse (ör. \Noselect ara düğümler)
    // yönetimi de anlamsızdır, aynı süzgeç uygulanır.
    final selectableFolders = providerFolders
        .where((m) => m.isSelectable)
        .toList();

    if (accountId != null) {
      ref.listen<AsyncValue<List<MailboxRow>>>(
        mailboxesForAccountProvider(accountId),
        (previous, next) => _reconcileWithProvider(next),
      );
    }

    final optimisticOrder = _optimisticAccountId == accountId
        ? _optimisticOrder
        : null;
    final folders = optimisticOrder ?? selectableFolders;
    final collapsed = accountId == null
        ? const <int>{}
        : ref.watch(collapsedFoldersProvider)[accountId] ??
              ref.read(settingsStoreProvider).readCollapsedFolders(accountId);
    final folderTree = accountId == null
        ? const <FolderTreeNode>[]
        : optimisticOrder == null
        ? ref.watch(folderTreeForAccountProvider(accountId))
        : buildFolderTree(folders);
    final visibleTree = [
      for (var i = 0; i < folderTree.length; i++)
        if (!_isHidden(folderTree, i, collapsed)) folderTree[i],
    ];
    final favorites = folders.where((f) => f.isFavorite).toList();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.x),
          tooltip: 'Kapat',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Düzenle'),
      ),
      // "+ Klasör Oluştur" her zaman erişilebilir olmalı — klasör listesi
      // boş olsa BİLE (ör. henüz hiç senkron olmamış yeni bir hesap):
      // bu yüzden burada tüm gövdeyi tek bir `EmptyState`e çeviren ayrı bir
      // dal YOK, boşluk her kartın kendi içinde ele alınır.
      body: accountId == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.only(bottom: Space.huge),
              children: [
                const SectionHeader('SIK KULLANILANLAR'),
                AnimatedSize(
                  duration: context.motion(Motion.base),
                  curve: Motion.standard,
                  alignment: Alignment.topCenter,
                  child: favorites.isEmpty
                      ? const _EmptyFolderCard(
                          key: ValueKey('empty-fav'),
                          message: 'Henüz sık kullanılan klasörünüz yok.',
                        )
                      : _FolderCard(
                          key: const ValueKey('fav-list'),
                          child: ReorderableListView(
                            buildDefaultDragHandles: false,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            onReorderItem: (oldIndex, newIndex) =>
                                _reorderFavorites(folders, oldIndex, newIndex),
                            children: [
                              for (var i = 0; i < favorites.length; i++)
                                _FolderManagementTile(
                                  key: ValueKey('fav-${favorites[i].id}'),
                                  index: i,
                                  folder: favorites[i],
                                  onToggleFavorite: () =>
                                      _toggleFavorite(folders, favorites[i]),
                                  onRename: () => _renameFolder(
                                    context,
                                    accountId,
                                    favorites[i],
                                  ),
                                  onNewSubfolder: () => _createFolder(
                                    context,
                                    accountId,
                                    parentMailboxId: favorites[i].id,
                                  ),
                                  onMove: () => _moveFolder(
                                    context,
                                    accountId,
                                    favorites[i],
                                  ),
                                  onDelete: () => _deleteFolder(
                                    context,
                                    accountId,
                                    favorites[i],
                                  ),
                                ),
                            ],
                          ),
                        ),
                ),
                SectionHeader(
                  'KLASÖRLER',
                  trailing: TextButton.icon(
                    onPressed: () => _createFolder(context, accountId),
                    icon: const Icon(LucideIcons.plus, size: IconSize.sm),
                    label: const Text('Klasör Oluştur'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                      minimumSize: const Size(0, Dimens.touchTarget - 12),
                    ),
                  ),
                ),
                if (folders.isEmpty)
                  const _EmptyFolderCard(message: 'Henüz klasör yok.')
                else
                  _FolderCard(
                    child: ReorderableListView(
                      buildDefaultDragHandles: false,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      onReorderItem: (oldIndex, newIndex) =>
                          _reorderAll(folders, visibleTree, oldIndex, newIndex),
                      children: [
                        // Tree sırası kullanılır: depth-first DFS — parent →
                        // children. ReorderableListView global index ister, bu
                        // yüzden tree'yi `folders` (optimistic) listesi üzerinden
                        // çözerek doğru index'i birlikte taşırız.
                        for (var i = 0; i < visibleTree.length; i++)
                          _FolderManagementTile(
                            key: ValueKey('all-${visibleTree[i].mailbox.id}'),
                            index: i,
                            expanded:
                                _hasChildren(
                                  folderTree,
                                  folderTree.indexOf(visibleTree[i]),
                                )
                                ? !collapsed.contains(visibleTree[i].mailbox.id)
                                : null,
                            onToggleExpanded: () => ref
                                .read(collapsedFoldersProvider.notifier)
                                .toggle(accountId, visibleTree[i].mailbox.id),
                            folder: visibleTree[i].mailbox,
                            depth: visibleTree[i].depth,
                            onToggleFavorite: () => _toggleFavorite(
                              folders,
                              visibleTree[i].mailbox,
                            ),
                            onRename: () => _renameFolder(
                              context,
                              accountId,
                              visibleTree[i].mailbox,
                            ),
                            onNewSubfolder: () => _createFolder(
                              context,
                              accountId,
                              parentMailboxId: visibleTree[i].mailbox.id,
                            ),
                            onMove: () => _moveFolder(
                              context,
                              accountId,
                              visibleTree[i].mailbox,
                            ),
                            onDelete: () => _deleteFolder(
                              context,
                              accountId,
                              visibleTree[i].mailbox,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  /// Kendi yazdığımız iyimser sıra veritabanından geri geldiğinde (ya da
  /// klasör kümesi başka bir yerden değiştiğinde — yeni klasör, senkron
  /// vb.) iyimser kopyayı bırakıp tekrar doğrudan akışı izlemeye döner.
  void _reconcileWithProvider(AsyncValue<List<MailboxRow>> next) {
    final optimistic = _optimisticOrder;
    if (optimistic == null) return;
    final data = next.value?.where((m) => m.isSelectable).toList();
    if (data == null) return;

    final sameIds = setEquals(
      data.map((m) => m.id).toSet(),
      optimistic.map((m) => m.id).toSet(),
    );
    if (!sameIds) {
      // Klasör kümesi değişti (yeni klasör, silinen klasör…) — iyimser
      // sırayı zorlamak yerine gerçek veriye dönülür.
      setState(() => _optimisticOrder = null);
      return;
    }
    final sameOrder = listEquals(
      data.map((m) => m.id).toList(),
      optimistic.map((m) => m.id).toList(),
    );
    if (sameOrder) setState(() => _optimisticOrder = null);
  }

  void _toggleFavorite(List<MailboxRow> folders, MailboxRow folder) {
    final updated = folder.copyWith(isFavorite: !folder.isFavorite);
    final next = [
      for (final f in folders)
        if (f.id == folder.id) updated else f,
    ];
    setState(() {
      _optimisticAccountId = ref.read(accountIdProvider);
      _optimisticOrder = next;
    });
    unawaited(
      _saveOptimistic(
        () => ref
            .read(folderRepositoryProvider)
            .setFavorite(folder.id, updated.isFavorite),
      ),
    );
  }

  Future<void> _saveOptimistic(Future<void> Function() save) async {
    try {
      await save();
    } on Object catch (_) {
      if (!mounted) return;
      setState(() => _optimisticOrder = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Klasör değişikliği kaydedilemedi.')),
      );
    }
  }

  /// Favori satırlarını yalnızca aynı IMAP parent altındaysa yeniden sıralar.
  void _reorderFavorites(List<MailboxRow> folders, int oldIndex, int newIndex) {
    final favorites = folders.where((f) => f.isFavorite).toList();
    if (oldIndex < 0 || oldIndex >= favorites.length) return;
    final moved = favorites[oldIndex];
    final afterRemoval = [...favorites]..removeAt(oldIndex);
    final targetIndex = newIndex.clamp(0, afterRemoval.length);
    if (afterRemoval.isEmpty) return;
    final target = afterRemoval[targetIndex.clamp(0, afterRemoval.length - 1)];
    final parentPath = _parentPath(moved);
    if (_parentPath(target) != parentPath) return;
    final siblings = buildFolderTree(folders)
        .map((node) => node.mailbox)
        .where((mailbox) => _parentPath(mailbox) == parentPath)
        .toList();
    siblings.removeWhere((mailbox) => mailbox.id == moved.id);
    final targetSibling = siblings.indexWhere(
      (mailbox) => mailbox.id == target.id,
    );
    siblings.insert(targetSibling.clamp(0, siblings.length), moved);
    _persistSiblingOrder(folders, siblings, parentPath);
  }

  bool _hasChildren(List<FolderTreeNode> tree, int index) =>
      index + 1 < tree.length && tree[index + 1].depth > tree[index].depth;

  bool _isHidden(List<FolderTreeNode> tree, int index, Set<int> collapsed) {
    var depth = tree[index].depth;
    for (var i = index - 1; i >= 0 && depth > 0; i--) {
      if (tree[i].depth < depth) {
        depth = tree[i].depth;
        if (collapsed.contains(tree[i].mailbox.id)) return true;
      }
    }
    return false;
  }

  void _reorderAll(
    List<MailboxRow> folders,
    List<FolderTreeNode> visibleTree,
    int oldIndex,
    int newIndex,
  ) {
    if (oldIndex < 0 ||
        oldIndex >= visibleTree.length ||
        visibleTree.length < 2) {
      return;
    }
    final moved = visibleTree[oldIndex].mailbox;
    final afterRemoval = [...visibleTree]..removeAt(oldIndex);
    final insertionIndex = newIndex.clamp(0, afterRemoval.length);
    final target = insertionIndex < afterRemoval.length
        ? afterRemoval[insertionIndex].mailbox
        : afterRemoval.last.mailbox;
    final parentPath = _parentPath(moved);
    if (_parentPath(target) != parentPath) return;

    final siblings = buildFolderTree(folders)
        .map((node) => node.mailbox)
        .where((mailbox) => _parentPath(mailbox) == parentPath)
        .toList();
    siblings.removeWhere((m) => m.id == moved.id);
    final siblingTargetIndex = siblings.indexWhere((m) => m.id == target.id);
    final at = siblingTargetIndex.clamp(0, siblings.length);
    siblings.insert(at, moved);

    _persistSiblingOrder(folders, siblings, parentPath);
  }

  void _persistSiblingOrder(
    List<MailboxRow> folders,
    List<MailboxRow> siblings,
    String? parentPath,
  ) {
    final ranks = {for (var i = 0; i < siblings.length; i++) siblings[i].id: i};
    final next =
        folders
            .map(
              (m) => ranks.containsKey(m.id)
                  ? m.copyWith(sortOrder: ranks[m.id]!)
                  : m,
            )
            .toList()
          ..sort((a, b) {
            final byOrder = a.sortOrder.compareTo(b.sortOrder);
            return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
          });
    final accountId = ref.read(accountIdProvider);
    if (accountId == null ||
        (parentPath != null && folders.every((m) => m.path != parentPath))) {
      return;
    }
    setState(() {
      _optimisticAccountId = accountId;
      _optimisticOrder = next;
    });
    unawaited(
      _saveOptimistic(
        () => ref
            .read(folderRepositoryProvider)
            .reorderSiblings(
              accountId: accountId,
              parentMailboxId: parentPath == null
                  ? null
                  : folders.where((m) => m.path == parentPath).firstOrNull?.id,
              orderedIds: siblings.map((m) => m.id).toList(),
            ),
      ),
    );
  }

  String? _parentPath(MailboxRow mailbox) {
    if (mailbox.delimiter.isEmpty) return null;
    final index = mailbox.path.lastIndexOf(mailbox.delimiter);
    return index <= 0 ? null : mailbox.path.substring(0, index);
  }

  /// Üst düzey "Klasör Oluştur" (bkz. `SectionHeader` trailing) VE
  /// bağlam menüsündeki "Yeni Alt Klasör" (bkz. `_FolderContextMenu`) AYNI
  /// diyaloğu paylaşır: klasör adı + "Dizin" (üst klasör) seçimi.
  /// [parentMailboxId] verilirse dizin o klasörle, verilmezse Gelen Kutusu ile
  /// başlar; kullanıcı açılır listeden herhangi bir klasörü ya da "Kök
  /// klasör"ü seçebilir. Seçim `AccountRepository.createFolder`a aktarılır.
  Future<void> _createFolder(
    BuildContext context,
    int accountId, {
    int? parentMailboxId,
  }) {
    // Yalnızca AKTİF hesabın klasörleri (kimlikler hesaba özgüdür).
    final all =
        ref.read(mailboxesForAccountProvider(accountId)).value ??
        const <MailboxRow>[];
    final options = _parentOptions(
      ref.read(folderTreeForAccountProvider(accountId)),
    );
    final inboxId = all
        .where((m) => m.specialUse == SpecialUse.inbox)
        .map((m) => m.id)
        .firstOrNull;
    var selectedParent = parentMailboxId ?? inboxId ?? _rootParent;
    if (!options.any((o) => o.id == selectedParent)) {
      selectedParent = _rootParent;
    }

    return _showFolderNameDialog(
      context,
      title: parentMailboxId == null ? 'Yeni klasör' : 'Yeni alt klasör',
      confirmLabel: 'Oluştur',
      busyLabel: 'Oluşturuluyor…',
      extraBuilder: (dialogContext, setDialogState, busy) => Consumer(
        builder: (context, ref, _) {
          final currentOptions = _parentOptions(
            ref.watch(folderTreeForAccountProvider(accountId)),
          );
          final effectiveParent =
              currentOptions.any((option) => option.id == selectedParent)
              ? selectedParent
              : _rootParent;
          return DropdownButtonFormField<int>(
            key: ValueKey(effectiveParent),
            initialValue: effectiveParent,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Dizin'),
            items: [
              for (final o in currentOptions)
                DropdownMenuItem<int>(
                  value: o.id,
                  child: Padding(
                    padding: EdgeInsets.only(left: o.depth * Space.lg),
                    child: Row(
                      children: [
                        Icon(o.icon, size: IconSize.sm),
                        const SizedBox(width: Space.sm),
                        Expanded(
                          child: Text(
                            o.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            selectedItemBuilder: (_) => [
              for (final o in currentOptions)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    o.breadcrumb,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: busy
                ? null
                : (value) {
                    if (value != null) selectedParent = value;
                    setDialogState(() {});
                  },
          );
        },
      ),
      onSubmit: (name) async {
        final result = await ref
            .read(folderRepositoryProvider)
            .createFolder(
              accountId: accountId,
              name: name,
              parentMailboxId: selectedParent == _rootParent
                  ? null
                  : selectedParent,
              atRoot: selectedParent == _rootParent,
            );
        if (result case Err(:final failure)) return failure;
        ref.read(syncControllerProvider.notifier).syncFolders(force: true);
        return null;
      },
    );
  }

  /// "Kök klasör" seçeneğinin sahte kimliği (gerçek satır kimlikleri ≥ 1).
  static const int _rootParent = -1;

  /// Dizin listesi: "Kök klasör" + depth-first klasör ağacı. Ağaç, `path`/
  /// delimiter tabanlı ortak Riverpod tree'sinden gelir.
  List<_ParentOption> _parentOptions(List<FolderTreeNode> tree) {
    final result = <_ParentOption>[
      const _ParentOption(
        id: _rootParent,
        label: 'Kök klasör',
        breadcrumb: 'Kök klasör',
        depth: 0,
        icon: LucideIcons.home,
      ),
    ];
    final names = <String>[];
    for (final node in tree) {
      names.length = node.depth;
      names.add(node.mailbox.name);
      result.add(
        _ParentOption(
          id: node.mailbox.id,
          label: node.mailbox.name,
          breadcrumb: names.join(' > '),
          depth: node.depth,
          icon: folderIcon(node.mailbox.specialUse),
        ),
      );
    }
    return result;
  }

  Future<void> _renameFolder(
    BuildContext context,
    int accountId,
    MailboxRow folder,
  ) {
    return _showFolderNameDialog(
      context,
      title: 'Klasörü yeniden adlandır',
      confirmLabel: 'Kaydet',
      busyLabel: 'Kaydediliyor…',
      initialValue: folder.name,
      onSubmit: (name) async {
        final result = await ref
            .read(folderRepositoryProvider)
            .renameFolder(
              accountId: accountId,
              mailboxId: folder.id,
              newName: name,
            );
        if (result case Err(:final failure)) return failure;
        ref.read(syncControllerProvider.notifier).syncFolders(force: true);
        return null;
      },
    );
  }

  /// Klasör adı isteyen tek metin alanlı diyaloğun ortak iskeleti — klasör
  /// oluşturma ve yeniden adlandırma [onSubmit]in ne yaptığı dışında
  /// birebir aynı UI/durum akışına sahiptir (bkz. `labels_settings_screen.
  /// dart`daki aynı `AlertDialog`+`DialogActions` deseni).
  Future<void> _showFolderNameDialog(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    required String busyLabel,
    String initialValue = '',
    Widget Function(
      BuildContext context,
      void Function(VoidCallback) setDialogState,
      bool busy,
    )?
    extraBuilder,
    required Future<AppFailure?> Function(String trimmedName) onSubmit,
  }) {
    final controller = TextEditingController(text: initialValue);
    final messenger = ScaffoldMessenger.of(context);
    var busy = false;
    String? nameError;

    return showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          Future<void> submit() async {
            if (busy) return;
            final name = controller.text.trim();
            if (name.isEmpty) {
              setState(() => nameError = 'Klasör adı boş bırakılamaz.');
              return;
            }
            setState(() {
              nameError = null;
              busy = true;
            });
            final failure = await onSubmit(name);
            if (failure != null) {
              setState(() => busy = false);
              messenger.showSnackBar(
                SnackBar(content: Text(failure.userMessage)),
              );
              return;
            }
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
          }

          return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    enabled: !busy,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Klasör adı',
                      errorText: nameError,
                    ),
                    onChanged: (_) {
                      if (nameError != null) setState(() => nameError = null);
                    },
                    onSubmitted: (_) => submit(),
                  ),
                  if (extraBuilder != null) ...[
                    const SizedBox(height: Space.lg),
                    extraBuilder(dialogContext, setState, busy),
                  ],
                ],
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              DialogActions(
                cancelLabel: 'Vazgeç',
                onCancel: () => Navigator.of(dialogContext).pop(),
                confirmLabel: busy ? busyLabel : confirmLabel,
                onConfirm: submit,
              ),
            ],
          );
        },
      ),
    );
  }

  /// Klasörü başka bir klasörün altına (ya da kök düzeye) taşır — hedef,
  /// kendisi ve kendi alt ağacı DIŞLANMIŞ bir klasör listesinden seçilir
  /// (döngü oluşturmasın diye, bkz. `AccountRepository.moveFolder`).
  ///
  /// `(bool, int?)` kaydı: `showDialog`ın `null` dönüşü ("Vazgeç"/dışarı
  /// dokunma ile kapatma) ile kullanıcının BİLEREK "Kök klasör"ü (kendisi
  /// `null` üst kimlik) seçmesini ayırt etmek için — ikisi de "hiçbir üst
  /// klasör kimliği yok" anlamına gelir ama biri iptal, diğeri geçerli bir
  /// seçimdir.
  Future<void> _moveFolder(
    BuildContext context,
    int accountId,
    MailboxRow folder,
  ) async {
    final ownSubtreePrefix = '${folder.path}${folder.delimiter}';
    final messenger = ScaffoldMessenger.of(context);

    final selected = await showDialog<(bool, int?)>(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (context, ref, _) {
          final candidates = ref
              .watch(folderTreeForAccountProvider(accountId))
              .where(
                (node) =>
                    node.mailbox.id != folder.id &&
                    !node.mailbox.path.startsWith(ownSubtreePrefix),
              )
              .toList();
          return AlertDialog(
            title: const Text('Klasörü taşı'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const Icon(LucideIcons.home, size: IconSize.md),
                    title: const Text('Kök klasör'),
                    onTap: () => Navigator.of(dialogContext).pop((true, null)),
                  ),
                  for (final candidate in candidates)
                    ListTile(
                      leading: Icon(
                        folderIcon(candidate.mailbox.specialUse),
                        size: IconSize.md,
                      ),
                      contentPadding: EdgeInsets.only(
                        left: Space.lg + candidate.depth * Space.lg,
                        right: Space.lg,
                      ),
                      title: Text(candidate.mailbox.name),
                      onTap: () => Navigator.of(
                        dialogContext,
                      ).pop((true, candidate.mailbox.id)),
                    ),
                ],
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Vazgeç'),
              ),
            ],
          );
        },
      ),
    );
    if (selected == null) return;
    final (_, newParentId) = selected;

    final result = await ref
        .read(folderRepositoryProvider)
        .moveFolder(
          accountId: accountId,
          mailboxId: folder.id,
          newParentId: newParentId,
        );
    if (result case Err(:final failure)) {
      messenger.showSnackBar(SnackBar(content: Text(failure.userMessage)));
    } else {
      ref.read(syncControllerProvider.notifier).syncFolders(force: true);
    }
  }

  Future<void> _deleteFolder(
    BuildContext context,
    int accountId,
    MailboxRow folder,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await confirmDialog(
      context,
      title: 'Klasörü sil',
      message:
          '"${folder.name}" klasörü ve içindeki tüm iletiler kalıcı olarak '
          'silinecek. Bu işlem geri alınamaz.',
      confirmLabel: 'Sil',
      destructive: true,
    );
    if (confirmed != true) return;

    final result = await ref
        .read(folderRepositoryProvider)
        .deleteFolder(accountId: accountId, mailboxId: folder.id);
    if (result case Err(:final failure)) {
      messenger.showSnackBar(SnackBar(content: Text(failure.userMessage)));
    } else {
      ref.read(syncControllerProvider.notifier).syncFolders(force: true);
    }
  }
}

/// Kart benzeri gruplama kutusu — `SettingsGroup`la aynı görsel dil, ama
/// içeriği bir `ReorderableListView` olduğundan (kendi `Column`ünü kurar)
/// satır aralarına otomatik ayraç eklemez.
class _FolderCard extends StatelessWidget {
  const _FolderCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Space.lg),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: t.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _EmptyFolderCard extends StatelessWidget {
  const _EmptyFolderCard({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return _FolderCard(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Text(
          message,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: t.textTertiary),
        ),
      ),
    );
  }
}

/// Klasör satırı: yıldız + ikon + ad + sürükle tutamacı.
///
/// `ReorderableListView(buildDefaultDragHandles: false)` ile birlikte
/// kullanılır — yalnızca sağdaki tutamaç [ReorderableDragStartListener]e
/// sarılıdır, böylece yıldıza dokunmak satırı sürüklemeye başlatmaz. Ad
/// alanına dokunmak da klasörü sürüklemez/açmaz — bağlam menüsünü açar
/// (bkz. [_FolderContextMenu]).
class _FolderManagementTile extends StatelessWidget {
  const _FolderManagementTile({
    super.key,
    required this.index,
    required this.folder,
    required this.onToggleFavorite,
    required this.onRename,
    required this.onNewSubfolder,
    required this.onMove,
    required this.onDelete,
    this.depth = 0,
    this.expanded,
    this.onToggleExpanded,
  });

  final int index;
  final MailboxRow folder;
  final VoidCallback onToggleFavorite;
  final VoidCallback onRename;
  final VoidCallback onNewSubfolder;
  final VoidCallback onMove;
  final VoidCallback onDelete;
  final bool? expanded;
  final VoidCallback? onToggleExpanded;

  /// Tree derinliği — [buildFolderTree]'den gelir; sol padding'e dönüştürülür.
  final int depth;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      constraints: const BoxConstraints(minHeight: Dimens.touchTarget + 8),
      padding: EdgeInsets.only(
        left: Space.md + depth * Space.lg,
        right: Space.md,
      ),
      child: Row(
        children: [
          if (expanded == null)
            const SizedBox(width: Dimens.touchTarget - 8)
          else
            IconButton(
              tooltip: expanded!
                  ? 'Alt klasörleri daralt'
                  : 'Alt klasörleri aç',
              onPressed: onToggleExpanded,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                expanded! ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: IconSize.sm,
              ),
            ),
          _FavoriteStarButton(
            isFavorite: folder.isFavorite,
            onTap: onToggleFavorite,
          ),
          const SizedBox(width: Space.xs),
          Icon(
            folderIcon(folder.specialUse),
            size: IconSize.md,
            color: t.textSecondary,
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: _FolderContextMenu(
              folder: folder,
              onToggleFavorite: onToggleFavorite,
              onRename: onRename,
              onNewSubfolder: onNewSubfolder,
              onMove: onMove,
              onDelete: onDelete,
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.all(Space.sm),
              child: Icon(
                LucideIcons.gripVertical,
                size: IconSize.md,
                color: t.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Klasör adına dokununca açılan bağlam menüsü — bkz. referans: Outlook'un
/// "Düzenle" ekranındaki klasör menüsü (Sık Kullanılan/Yeniden Adlandır/
/// Yeni Alt Klasör/Taşı/Sil). Bir alt sayfa (bottom sheet) YERİNE anchored
/// bir popup (`MenuAnchor`) — bkz. bellek: popup'lar modallara tercih
/// edilir; `mail_detail_screen.dart`daki `_MoreMenu` ile aynı desen.
///
/// Sistem klasörlerinde (Gelen Kutusu, Gönderilenler, Taslaklar, Çöp
/// Kutusu, İstenmeyen, Arşiv) yeniden adlandırma/taşıma/silme
/// GÖSTERİLMEZ — bunlar zaten sunucu tarafında da reddedilir (bkz.
/// `AccountRepository.renameFolder`/`moveFolder`/`deleteFolder`), ama
/// kullanıcıya hiç çalışmayacak bir seçenek sunmanın anlamı yok.
class _FolderContextMenu extends StatelessWidget {
  const _FolderContextMenu({
    required this.folder,
    required this.onToggleFavorite,
    required this.onRename,
    required this.onNewSubfolder,
    required this.onMove,
    required this.onDelete,
  });

  final MailboxRow folder;
  final VoidCallback onToggleFavorite;
  final VoidCallback onRename;
  final VoidCallback onNewSubfolder;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final isSystemFolder = folder.specialUse != SpecialUse.custom;

    return MenuAnchor(
      animated: true,
      menuChildren: [
        MenuItemButton(
          leadingIcon: Icon(
            folder.isFavorite ? LucideIcons.starOff : LucideIcons.star,
            size: IconSize.sm,
          ),
          onPressed: onToggleFavorite,
          child: Text(
            folder.isFavorite
                ? 'Sık kullanılanlardan çıkar'
                : 'Sık kullanılanlara ekle',
          ),
        ),
        const Divider(height: 1),
        if (!isSystemFolder)
          MenuItemButton(
            leadingIcon: const Icon(LucideIcons.pencil, size: IconSize.sm),
            onPressed: onRename,
            child: const Text('Klasörü Yeniden Adlandır'),
          ),
        MenuItemButton(
          leadingIcon: const Icon(LucideIcons.folderPlus, size: IconSize.sm),
          onPressed: onNewSubfolder,
          child: const Text('Yeni Alt Klasör'),
        ),
        if (!isSystemFolder) ...[
          MenuItemButton(
            leadingIcon: const Icon(LucideIcons.folderInput, size: IconSize.sm),
            onPressed: onMove,
            child: const Text('Klasörü Taşı'),
          ),
          const Divider(height: 1),
          MenuItemButton(
            leadingIcon: Icon(
              LucideIcons.trash2,
              size: IconSize.sm,
              color: t.danger,
            ),
            onPressed: onDelete,
            child: Text('Sil', style: TextStyle(color: t.danger)),
          ),
        ],
      ],
      builder: (context, controller, child) => InkWell(
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.md),
          child: Text(
            folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: t.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _FavoriteStarButton extends StatelessWidget {
  const _FavoriteStarButton({required this.isFavorite, required this.onTap});

  final bool isFavorite;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      button: true,
      label: isFavorite
          ? 'Sık kullanılanlardan çıkar'
          : 'Sık kullanılanlara ekle',
      child: InkResponse(
        onTap: onTap,
        radius: Dimens.touchTarget / 2,
        child: SizedBox(
          width: Dimens.touchTarget - 12,
          height: Dimens.touchTarget - 12,
          child: Center(
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: isFavorite ? t.warning : t.textTertiary),
              duration: context.motion(Motion.fast),
              curve: Motion.standard,
              builder: (context, color, _) =>
                  Icon(LucideIcons.star, size: IconSize.md, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Dizin" açılır listesindeki bir satır (bkz. `_createFolder`).
class _ParentOption {
  const _ParentOption({
    required this.id,
    required this.label,
    required this.breadcrumb,
    required this.depth,
    required this.icon,
  });

  final int id;
  final String label;
  final String breadcrumb;
  final int depth;
  final IconData icon;
}
