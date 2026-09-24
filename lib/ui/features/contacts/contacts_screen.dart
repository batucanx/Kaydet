import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/providers.dart';
import '../../../core/turkish.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/models/mail_models.dart';
import '../../core/theme/tokens.dart';
import '../../core/widgets/kaydet_widgets.dart';
import '../compose/compose_launcher.dart';

/// Kişiler sekmesi.
///
/// CardDAV değil — tamamen yerel bir kişi defteri: gönderilen iletilerin
/// alıcıları (bkz. `MailRepository.queueSend`) ve Gelen Kutusu'na düşen
/// iletilerin göndericileri (bkz. `SyncEngine._captureContactsFromInbox`)
/// otomatik olarak buraya eklenir. Yazma ekranının Kime/Bilgi/Gizli
/// otomatik tamamlaması da aynı kaynağı kullanır (bkz. `_ContactAutocomplete`
/// içinde `compose_screen.dart`). Bir kişiye dokunmak yazma ekranını Kime
/// alanı dolu açar; sola kaydırmak siler.
class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Otomatik tamamlama listesi en son kullanılana göredir (bkz.
  /// `AppDatabase.watchContacts`); burada tarama/bulma kolay olsun diye
  /// ada göre A-Z gösterilir — aynı veri, ekrana göre farklı sıralama.
  List<ContactRow> _visibleContacts(List<ContactRow> contacts) {
    final sorted = [...contacts]
      ..sort(
        (a, b) => trLower(
          a.name.isEmpty ? a.email : a.name,
        ).compareTo(trLower(b.name.isEmpty ? b.email : b.name)),
      );
    if (_query.trim().isEmpty) return sorted;
    final folded = foldForSearch(_query);
    return sorted
        .where(
          (c) =>
              foldForSearch(c.email).contains(folded) ||
              (c.name.isNotEmpty && foldForSearch(c.name).contains(folded)),
        )
        .toList();
  }

  Future<void> _openCompose(String email) =>
      openCompose(context, ref, initialTo: email);

  Future<void> _addContact(int accountId) async {
    final nameController = TextEditingController();
    final emailController = TextEditingController();

    final created = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Yeni kişi'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(hintText: 'Ad Soyad'),
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(hintText: 'ornek@eposta.com'),
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          DialogActions(
            cancelLabel: 'Vazgeç',
            onCancel: () => Navigator.of(context).pop(false),
            confirmLabel: 'Ekle',
            onConfirm: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (created != true || !mounted) return;

    final email = emailController.text.trim();
    if (!EmailAddress.isValidEmail(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Geçerli bir e-posta adresi girin.')),
      );
      return;
    }
    await ref
        .read(accountRepositoryProvider)
        .createContact(
          accountId: accountId,
          email: email,
          name: nameController.text.trim(),
        );
  }

  Future<void> _confirmDelete(ContactRow contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kişi silinsin mi?'),
        content: Text(
          '${contact.name.isEmpty ? contact.email : contact.name} kişi '
          'listesinden kaldırılacak.',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          DialogActions(
            cancelLabel: 'Vazgeç',
            onCancel: () => Navigator.of(context).pop(false),
            confirmLabel: 'Sil',
            onConfirm: () => Navigator.of(context).pop(true),
            destructive: true,
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(accountRepositoryProvider).deleteContact(contact.id);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final accountId = ref.watch(accountIdProvider);
    final contacts = ref.watch(contactsProvider).value ?? const <ContactRow>[];
    final visible = _visibleContacts(contacts);

    return Scaffold(
      // Bu ekranın kendi `Scaffold`u `AppShell`'in klasör/modül menüsünü
      // taşımaz; menü butonu elle eklenir (bkz. `mail_list_screen.dart`
      // daki aynı desen).
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.menu),
          tooltip: 'Menü',
          onPressed: () => Scaffold.of(context).openDrawer(),
        ),
        title: const Text('Kişiler'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.userPlus),
            tooltip: 'Kişi ekle',
            onPressed: accountId == null ? null : () => _addContact(accountId),
          ),
          const SizedBox(width: Space.xs),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.md,
              Space.lg,
              Space.sm,
            ),
            child: TextField(
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'Kişilerde ara',
                prefixIcon: const Icon(LucideIcons.search, size: IconSize.sm),
                isDense: true,
                filled: true,
                fillColor: t.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(child: _buildList(contacts, visible)),
        ],
      ),
    );
  }

  Widget _buildList(List<ContactRow> all, List<ContactRow> visible) {
    if (all.isEmpty) {
      return const EmptyState(
        icon: LucideIcons.users,
        title: 'Henüz kişi yok',
        description:
            'Bir ileti gönderip aldıkça kişileriniz burada otomatik '
            'birikir; isterseniz sağ üstten elle de ekleyebilirsiniz.',
      );
    }
    if (visible.isEmpty) {
      return const EmptyState(
        icon: LucideIcons.search,
        title: 'Sonuç bulunamadı',
        description: 'Farklı bir arama deneyin.',
      );
    }

    final t = context.tokens;
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final contact = visible[index];
        return Slidable(
          key: ValueKey('contact-${contact.id}'),
          endActionPane: ActionPane(
            motion: const DrawerMotion(),
            extentRatio: 0.24,
            children: [
              SlidableAction(
                onPressed: (_) => _confirmDelete(contact),
                backgroundColor: t.dangerFill,
                foregroundColor: Colors.white,
                icon: LucideIcons.trash2,
                label: 'Sil',
              ),
            ],
          ),
          child: ListTile(
            leading: BrandAvatar(name: contact.name, email: contact.email),
            title: Text(
              contact.name.isEmpty ? contact.email : contact.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: contact.name.isEmpty
                ? null
                : Text(
                    contact.email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            onTap: () => _openCompose(contact.email),
          ),
        );
      },
    );
  }
}
