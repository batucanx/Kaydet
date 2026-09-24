import '../../core/turkish.dart';
import '../../data/database/app_database.dart';
import '../models/mail_models.dart';

/// Sunucu klasörünü uygulamanın bildiği türe eşler.
///
/// Sıralama önemli: önce sunucunun SPECIAL-USE/XLIST bayrağına bakılır
/// (kesin bilgi), o yoksa ad eşlemesine düşülür. Türk hosting'lerinde
/// klasörler `Gönderilmiş Öğeler`, `Önemsiz`, `Çöp Kutusu` gibi adlandırılır
/// ve bu isimler sunucudan sunucuya değişir.
abstract final class FolderMapping {
  /// İngilizce + Türkçe klasör adı eşlemesi (normalleştirilmiş).
  static const Map<SpecialUse, List<String>> _names = {
    SpecialUse.inbox: ['inbox', 'gelen', 'gelen kutusu', 'gelenkutusu'],
    SpecialUse.sent: [
      'sent',
      'sent items',
      'sent messages',
      'sentmail',
      'sent mail',
      'gonderilmis',
      'gonderilmis ogeler',
      'gonderilenler',
      'giden',
      'giden kutusu',
    ],
    SpecialUse.drafts: [
      'drafts',
      'draft',
      'taslak',
      'taslaklar',
      'taslak ogeler',
    ],
    SpecialUse.trash: [
      'trash',
      'deleted',
      'deleted items',
      'deleted messages',
      'bin',
      'cop',
      'cop kutusu',
      'silinmis',
      'silinmis ogeler',
      'cop kutusu ogeleri',
    ],
    SpecialUse.junk: [
      'junk',
      'spam',
      'bulk mail',
      'junk e-mail',
      'istenmeyen',
      'istenmeyen posta',
      'onemsiz',
      'gereksiz',
    ],
    SpecialUse.archive: [
      'archive',
      'archives',
      'all mail',
      'arsiv',
      'arsivler',
    ],
  };

  /// Klasör yolundan son bileşeni alır: `INBOX.Sent` → `Sent`
  static String leafName(String path, String delimiter) {
    if (delimiter.isEmpty) return path;
    final index = path.lastIndexOf(delimiter);
    if (index < 0 || index == path.length - 1) return path;
    return path.substring(index + delimiter.length);
  }

  /// Ada göre klasör türünü tahmin eder.
  ///
  /// [serverFlagUse] sunucunun bildirdiği tür — varsa her zaman kazanır.
  static SpecialUse resolve({
    required String path,
    required String delimiter,
    SpecialUse? serverFlagUse,
  }) {
    if (serverFlagUse != null && serverFlagUse != SpecialUse.custom) {
      return serverFlagUse;
    }

    // INBOX adı IMAP standardında büyük/küçük harf duyarsız ve sabittir.
    if (path.toUpperCase() == 'INBOX') return SpecialUse.inbox;

    final leaf = foldForSearch(leafName(path, delimiter)).trim();
    final full = foldForSearch(path.replaceAll(delimiter, ' ')).trim();

    for (final entry in _names.entries) {
      for (final candidate in entry.value) {
        if (leaf == candidate) return entry.key;
      }
    }
    // Ad tam eşleşmediyse, `INBOX.Sent Items` gibi birleşik yollarda ara.
    for (final entry in _names.entries) {
      for (final candidate in entry.value) {
        if (full.endsWith(' $candidate') || full == candidate) {
          return entry.key;
        }
      }
    }
    return SpecialUse.custom;
  }

  /// Yan menüdeki sıralama. Taslaklar, Çöp Kutusu'nun hemen üzerindedir.
  static int sortOrderFor(SpecialUse use) => switch (use) {
    SpecialUse.inbox => 0,
    SpecialUse.sent => 10,
    SpecialUse.archive => 20,
    SpecialUse.drafts => 30,
    SpecialUse.trash => 40,
    SpecialUse.junk => 50,
    SpecialUse.custom => 100,
  };

  /// Kullanıcıya gösterilen Türkçe ad.
  static String displayName(SpecialUse use, String fallback) => switch (use) {
    SpecialUse.inbox => 'Gelen Kutusu',
    SpecialUse.sent => 'Gönderilenler',
    SpecialUse.drafts => 'Taslaklar',
    SpecialUse.trash => 'Çöp Kutusu',
    SpecialUse.junk => 'İstenmeyen',
    SpecialUse.archive => 'Arşiv',
    SpecialUse.custom => fallback,
  };

  /// Bir klasörde silme işlemi kalıcı mı olmalı?
  ///
  /// Çöp Kutusu'nun içinde silmek kalıcıdır (EXPUNGE); başka yerde silmek
  /// iletiyi Çöp Kutusu'na taşır.
  static bool deleteIsPermanent(SpecialUse use) =>
      use == SpecialUse.trash || use == SpecialUse.junk;
}

/// Folder tree düğümü: [mailbox] + tree derinliği + alt düğümler.
///
/// [depth] == 0 → kök klasör (indent yok); her ek seviye `Space.lg` (16 dp)
/// ek girintiye karşılık gelir. Değer hesaplamasında kullanılan değişmez
/// kural: `path`taki delimiter sayısı o klasörün derinliğidir —
/// ek bir DB alanı veya migration gerektirmez.
class FolderTreeNode {
  FolderTreeNode({required this.mailbox, required this.depth});

  final MailboxRow mailbox;
  final int depth;
}

/// [mailboxes]'ı IMAP path/delimiter bilgisinden UI ağacına düzleştirir.
///
/// Girdi sortOrder'a göre sıralanmış olabilir; çıktı depth-first ağaç
/// sırasını korur (parent → children → grandchildren) ve her düğümün
/// [FolderTreeNode.depth]'i ui indentation için kullanılır.
///
/// IMAP path hiyerarşisi UI hiyerarşisini doğrudan belirlemez: sistem rollü
/// klasörler (Gelen, Gönderilmiş vb.) her zaman UI köküdür. Custom klasörlerde
/// gerçek IMAP parent path'i kullanılır; ek DB alanı veya migration gerekmez.
///
/// Algoritma:
/// 1. Sistem rollü klasörleri köke al; custom klasörlerin `parentPath`'ini
///    delimiter kullanarak hesapla.
/// 2. parentPath'i olan, ancak yerel listede karşılığı BULUNMAYAN (sunucu-
///    tarafı \Noselect düğümler, ya da henüz senkronize olmamış) klasörler
///    doğrudan kök kabul edilir — tree'yi kırmamaları için.
/// 3. depth-first DFS ile `_traverse` çağrısı.
///
/// Böylece `INBOX.Sent` gibi bir sunucu yolu, Gönderilmiş sistem rolü varsa
/// UI'da Gelen'in child'ı olmaz. `INBOX.Projeler` gibi custom klasörler ise
/// Gelen'in altında kalır.
List<FolderTreeNode> buildFolderTree(
  List<MailboxRow> mailboxes, {
  bool Function(MailboxRow mailbox)? include,
}) {
  if (mailboxes.isEmpty) return const [];

  // IMAP path tek başına kimlik değildir: farklı hesaplarda aynı path olur.
  final byAccountAndPath = <int, Map<String, MailboxRow>>{};
  for (final mailbox in mailboxes) {
    (byAccountAndPath[mailbox.accountId] ??= {})[mailbox.path] = mailbox;
  }

  // Her klasörün parent path'ini hesapla.
  String? parentPathOf(MailboxRow m) {
    // IMAP path (ör. INBOX.Sent) sunucunun namespace düzenidir. Sistem
    // klasörünün `specialUse` rolü UI hiyerarşisinde daima kök olmasını sağlar.
    if (m.specialUse != SpecialUse.custom) return null;
    if (m.delimiter.isEmpty) return null;
    final idx = m.path.lastIndexOf(m.delimiter);
    if (idx <= 0) return null;
    return m.path.substring(0, idx);
  }

  // Hesap + parent path → çocuklar. Parent ilişkisi addan tahmin edilmez.
  final children = <(int, String?), List<MailboxRow>>{};
  for (final m in mailboxes) {
    final pp = parentPathOf(m);
    // Eksik/\Noselect parent düğümü varsa klasör en yakın görünen ataya
    // bağlanır; seçilebilir olmayanlar traversal sırasında atlanabilir.
    final accountPaths = byAccountAndPath[m.accountId]!;
    final effectiveParent = (pp != null && accountPaths.containsKey(pp))
        ? pp
        : null;
    (children[(m.accountId, effectiveParent)] ??= []).add(m);
  }

  // Kök listesini ve tüm children gruplarını sortOrder'a göre sırala.
  for (final list in children.values) {
    list.sort((a, b) {
      final byOrder = a.sortOrder.compareTo(b.sortOrder);
      if (byOrder != 0) return byOrder;
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.path.compareTo(b.path);
    });
  }

  // depth-first traversal.
  final result = <FolderTreeNode>[];
  final visible = include ?? (_) => true;
  void traverse(int accountId, String? parentPath, int visibleDepth) {
    final kids = children[(accountId, parentPath)];
    if (kids == null) return;
    for (final m in kids) {
      final included = visible(m);
      if (included) {
        result.add(FolderTreeNode(mailbox: m, depth: visibleDepth));
      }
      traverse(accountId, m.path, visibleDepth + (included ? 1 : 0));
    }
  }

  for (final accountId in byAccountAndPath.keys.toList()..sort()) {
    traverse(accountId, null, 0);
  }
  return result;
}
