# Bölüm 1 — Mimari, Domain Modeli ve Veritabanı Şeması

## 1.1 Katman Mimarisi

Üç katman, tek yönlü bağımlılık: **UI → Domain → Data**. UI katmanı `enough_mail` veya Drift tiplerini **asla** görmez.

```
┌──────────────────────────────────────────────────────────┐
│ UI       Views (Widget) + ViewModel (Riverpod Notifier)   │
│          Sadece domain modelleri tüketir                  │
├──────────────────────────────────────────────────────────┤
│ DOMAIN   Immutable modeller (freezed) + Use Case'ler      │
│          Threading, arama, klasör eşleme mantığı          │
├──────────────────────────────────────────────────────────┤
│ DATA     Repository'ler (tek doğruluk kaynağı)            │
│          Service'ler: ImapService, SmtpService,           │
│          DriftDatabase, SecureStorage, FileStore          │
└──────────────────────────────────────────────────────────┘
```

**Riverpod uyarlaması:** Standart Flutter mimarisindeki `ChangeNotifier` tabanlı ViewModel yerine `@riverpod class XNotifier extends _$XNotifier` kullanılır. Rol aynıdır: durumu tutar, repository'yi enjekte alır, View'a değişmez (immutable) bir durum anlık görüntüsü sunar. Bağımlılık enjeksiyonu için ayrı bir `get_it` gerekmez — provider grafiği bu işi görür.

**Offline-first ilkesi:** UI **hiçbir zaman** ağı doğrudan beklemez. UI yalnızca Drift'i dinler (Stream). Ağ katmanı veritabanını günceller, veritabanı UI'yi günceller. Uçak modunda uygulama tam işlevsel açılır.

```
Kullanıcı eylemi → Repository → (1) yerel DB'ye iyimser yazma → UI anında güncellenir
                              → (2) PendingOperation kuyruğuna ekle
                              → (3) ağ uygunsa sunucuya gönder → başarısızsa geri al + bildir
```

## 1.2 Klasör Yapısı

```text
lib/
├── main.dart
├── app.dart                      # MaterialApp.router, tema baglama
├── core/
│   ├── result.dart               # Result<T> / AppFailure — istisna firlatma yok
│   ├── logger.dart
│   ├── extensions/               # DateTime, String yardimcilari
│   └── constants.dart
├── data/
│   ├── database/
│   │   ├── app_database.dart     # Drift
│   │   ├── tables/               # Tablo tanimlari
│   │   └── daos/                 # MailDao, AccountDao, LabelDao
│   ├── services/
│   │   ├── imap_service.dart     # enough_mail sarmalayici (stateless)
│   │   ├── smtp_service.dart
│   │   ├── secure_store.dart     # flutter_secure_storage
│   │   ├── attachment_store.dart # dosya sistemi
│   │   └── notification_service.dart
│   ├── mappers/                  # MimeMessage <-> Drift <-> Domain donusumleri
│   └── repositories/
│       ├── account_repository.dart
│       ├── mailbox_repository.dart
│       ├── message_repository.dart
│       ├── draft_repository.dart
│       └── label_repository.dart
├── domain/
│   ├── models/                   # freezed: Account, Mailbox, Message, Thread...
│   └── use_cases/
│       ├── build_threads.dart    # JWZ benzeri konusma gruplama
│       ├── sync_mailbox.dart
│       └── search_messages.dart
└── ui/
    ├── core/
    │   ├── theme/                # tokens.dart, app_theme.dart (ThemeExtension)
    │   └── widgets/              # KaydetAvatar, LabelChip, SwipeAction...
    └── features/
        ├── auth/                 # login, hesap ekleme
        ├── mail_list/            # liste + arama + coklu secim
        ├── mail_detail/          # okuma + HTML render + ekler
        ├── compose/              # yazma + sesli giris + taslak
        ├── settings/             # etiket, imza, bildirim, senkronizasyon
        └── shell/                # Scaffold + Drawer (Sidebar) + router
```

## 1.3 Domain Modelleri

Hepsi `freezed` ile immutable. React prototipindeki düz `email` nesnesi, gerçek mail için **4 ayrı modele** bölünür — envelope (liste için hafif), body (ağır, talep üzerine), attachment (dosya), thread (gruplama).

### Account
```
id (local int)            displayName
email                     signature
imapHost, imapPort, imapSecurity (none|starttls|ssl)
smtpHost, smtpPort, smtpSecurity
username                  # cogunlukla email ile ayni, ayri tutulur
colorSeed                 # avatar/hesap rengi
isActive                  # aktif hesap
```
> Şifre **burada tutulmaz**. `flutter_secure_storage` içinde `account_<id>_password` anahtarıyla saklanır.

### Mailbox (klasör)
```
id, accountId
path            # "INBOX", "INBOX.Sent" — sunucudaki gercek yol
name            # kullaniciya gosterilen ad
specialUse      # inbox|sent|drafts|trash|spam|archive|custom   <- ENUM
delimiter       # "." veya "/"
uidValidity     # KRITIK (bkz. 1.5)
uidNext, highestModSeq
unreadCount, totalCount
lastSyncAt, isSubscribed
```

### Message (envelope — liste görünümünde kullanılan hafif kayıt)
```
id (local)                accountId, mailboxId
uid (int)                 # sunucudaki kimlik
messageIdHeader           # "<abc@host>" — threading icin
inReplyTo, referencesRaw  # threading icin
threadId                  # yerel hesaplanir
fromName, fromEmail
toJson, ccJson, bccJson   # List<MailAddress> serilestirilmis
subject
preview                   # ilk ~140 karakter duz metin
dateUtc (DateTime)        # <- React'teki String date'in yerine gecer
isSeen, isFlagged, isAnswered, isDraft, isDeleted
hasAttachments, sizeBytes
bodyFetchedAt             # null ise govde henuz indirilmedi
labelsJson
isLocalOnly               # gonderilmemis taslak/outbox
```

### MessageBody (ayrı tablo — liste sorgularını yavaşlatmaması için)
```
messageLocalId (PK)   plainText   html   fetchedAt
```

### Attachment
```
id, messageLocalId, partId (IMAP BODYSTRUCTURE yolu)
fileName, mimeType, sizeBytes
contentId, isInline
localPath   # null ise indirilmemis
```

### Thread (türetilmiş, tabloda materyalize edilir)
```
threadId, accountId, mailboxId
subjectNormalized     # "Re:", "Fwd:", "Yan:", "Ilt:" temizlenmis
participantsJson, messageCount, unreadCount
lastMessageDate, hasAttachments, isFlagged
```

### Label
```
id, accountId, name, colorToken, imapKeyword   # sunucuya yazilacaksa
```

### PendingOperation (senkronizasyon kuyruğu — kusursuz çalışmanın anahtarı)
```
id, accountId, type (markSeen|markUnseen|flag|unflag|move|delete|append|send)
targetJson (uid listesi, hedef klasor vb.)
createdAt, attemptCount, lastError, status (pending|running|failed)
```

## 1.4 Drift Şeması — Tablolar ve İndeksler

| Tablo | Not |
|---|---|
| `accounts` | |
| `mailboxes` | UNIQUE(accountId, path) |
| `messages` | UNIQUE(accountId, mailboxId, uid) — çift kayıt imkânsız |
| `message_bodies` | messages'a CASCADE |
| `attachments` | messages'a CASCADE |
| `threads` | |
| `labels` | |
| `pending_operations` | |
| `messages_fts` | **FTS5 sanal tablo**: subject, fromName, fromEmail, preview, plainText |

**İndeksler (performans için zorunlu):**
- `idx_messages_list` → (accountId, mailboxId, dateUtc DESC) — liste sorgusunun tamamı bu indeksten okunur
- `idx_messages_thread` → (threadId)
- `idx_messages_flagged` → (accountId, isFlagged) — "Sabitlenenler" sanal klasörü
- `idx_messages_msgid` → (messageIdHeader) — threading

**Arama:** React'teki `.filter()` + `.toLowerCase()` yerine FTS5. 50.000 mailde bile arama 20 ms altında. Türkçe için `unicode61 remove_diacritics 2` tokenizer'ı + sorgu öncesi normalizasyon (İ/ı/ş/ğ katlaması).

## 1.5 Kusursuz Çalışma İçin Kritik 8 Nokta

Mail istemcilerinin bozulduğu yerler bunlardır; şema bunları baştan karşılayacak şekilde tasarlandı.

1. **UIDVALIDITY.** Sunucu bu değeri değiştirdiğinde tüm UID'ler geçersizleşir. Her senkronizasyonda kontrol edilir; değiştiyse o klasörün yerel önbelleği silinip baştan çekilir. Bu kontrol yapılmazsa uygulama **yanlış maili siler** — en tehlikeli hata budur.
2. **UID sıra numarası değildir.** `enough_mail` her ikisini de sunar; şemada yalnızca UID saklanır, sıra numarası asla kalıcılaştırılmaz.
3. **Özel klasör tespiti.** Türk hosting'lerinde klasör adları `INBOX.Sent`, `Gönderilmiş Öğeler`, `Çöp Kutusu`, `Önemsiz` gibi değişir. Önce SPECIAL-USE/XLIST uzantısı denenir, olmazsa Türkçe/İngilizce ad eşleme tablosu devreye girer, o da olmazsa kullanıcıya Ayarlar'dan manuel eşleme sunulur.
4. **Arşiv klasörü yoksa.** Sunucuda Archive yoksa uygulama `INBOX.Archive` oluşturmayı teklif eder. (React'te arşiv sadece `alert()` idi.)
5. **Gönderilen mailin Sent'e yazılması.** Birçok SMTP sunucusu bunu otomatik yapmaz; SMTP gönderiminden sonra IMAP `APPEND` ile Sent klasörüne yazılır. Yapılmazsa "gönderdim ama Gönderilenler'de yok" şikâyeti oluşur.
6. **Silme davranışı.** IMAP'te silme = Trash'e MOVE + orijinali `\Deleted` + `EXPUNGE`. Kalıcı silme yalnızca Çöp Kutusu içinden yapılır. Tek adımda EXPUNGE yapılırsa veri **geri dönülemez** şekilde kaybolur.
7. **Threading sunucuda yok.** Düz IMAP konuşma grubu vermez. `References` / `In-Reply-To` başlıkları + normalize konu ile **yerel** JWZ benzeri algoritma kullanılır. Türkçe ön ekler (`Yan:`, `İlt:`) de temizlenir.
8. **Bağlantı ömrü.** IMAP bağlantısı pahalıdır ve kopar. Hesap başına tek bir kalıcı bağlantı havuzu + otomatik yeniden bağlanma + exponential backoff. Her ekran kendi bağlantısını açmaz.

## 1.6 Paket Listesi (öneri)

| Amaç | Paket |
|---|---|
| IMAP/SMTP/MIME | `enough_mail` |
| Durum yönetimi | `flutter_riverpod` + `riverpod_annotation` + `riverpod_generator` |
| Veritabanı | `drift` + `sqlite3_flutter_libs` |
| Modeller | `freezed` + `json_serializable` |
| Navigasyon | `go_router` |
| Şifre saklama | `flutter_secure_storage` |
| HTML render | `flutter_widget_from_html` |
| Arka plan | `workmanager` |
| Bildirim | `flutter_local_notifications` |
| Sesli yazma | `speech_to_text` |
| Dosya seçme/açma | `file_picker` + `open_filex` |
| Ağ durumu | `connectivity_plus` |
| Tarih formatı | `intl` (tr_TR) |

## 1.7 Verilen Kararlar

1. **Sabitleme (Pin) = IMAP `\Flagged`.** ✅ Karar verildi.
   Tek kavram kalır; `starred` alanı şemadan tamamen çıkarılır. Sabitlenen mail webmail'de ve diğer cihazlarda da yıldızlı görünür, telefon değişince kaybolmaz. "Sabitlenenler" klasörü = `WHERE isFlagged = 1` sanal sorgusu.
2. **Etiketler: destekleniyorsa sunucuya.** ✅ Karar verildi.
   Uygulama klasör seçiminde `PERMANENTFLAGS` yanıtını okur. `\*` varsa özel keyword'ler (`kaydet_is`, `kaydet_kisisel`...) sunucuya yazılır. Yoksa `labels` tablosu yerel modda çalışır ve Ayarlar'da "bu etiketler yalnızca bu cihazda görünür" uyarısı gösterilir. Bu tespit hesap bazında `accounts.supportsKeywords` alanında saklanır.
3. **Çoklu hesap: şema hazır, arayüz v1.1.** ✅ Karar verildi.
   Tüm tablolarda `accountId` bulunur, repository'ler hesap parametresi alır. v1 arayüzünde yalnızca aktif hesap gösterilir; Sidebar'daki "Hesap Ekle" v1'de gizlidir. Sonradan açmak veritabanı göçü gerektirmez.

## 1.8 Açık Kalan Tek Konu

**Gerçek sunucu bilgileri.** Prototipteki `port 110 / güvenlik NONE` kombinasyonu IMAP değil POP3'tür ve şifreyi düz metin gönderir. Geliştirme boyunca test edilecek gerçek IMAP ayarları (host / 993-SSL veya 143-STARTTLS) gerekli.

## 1.9 Paket Risk Analizi (pub.dev doğrulaması, 2026-09-14)

| Paket | Sürüm | Son yayın | Durum |
|---|---|---|---|
| `drift` | 2.35.0 | 5 gün önce | ✅ çok aktif |
| `flutter_riverpod` | 3.4.3 | 11 gün önce | ✅ çok aktif |
| `flutter_secure_storage` | 11.1.1 | 3 gün önce | ✅ çok aktif |
| `flutter_widget_from_html` | 0.17.4 | 6 gün önce | ✅ çok aktif |
| `workmanager` | 0.10.10 | 7 gün önce | ✅ aktif |
| `speech_to_text` | 7.4.0 | 4 ay önce | ✅ yeterli |
| **`enough_mail`** | **2.1.7** | **13 ay önce** | ⚠️ **RİSK** |
| `mailer` (SMTP yedeği) | 7.2.0 | 2 ay önce | ✅ aktif |

**`enough_mail` riski ve önlemi.** Dart'ta üretim kalitesinde IMAP istemcisi pratikte tek: `enough_mail`. Son sürüm 13 ay önce yayınlanmış, ondan önce de 20 aylık bir boşluk var. Yani terk edilmiş değil ama yavaş. SDK kısıtı `>=3.0.0 <4.0.0` olduğu için Dart 3.12 ile uyumlu. Alınacak önlemler:

1. **Sürüm sabitlenir** (`enough_mail: 2.1.7`, `^` kullanılmaz) — sürpriz güncelleme kırılması olmaz.
2. **Arayüz arkasına gizlenir.** `ImapService` / `SmtpService` soyut sınıflardır; `enough_mail` yalnızca bu iki dosyanın içinde geçer. Paket bir gün çökerse değişecek kod iki dosyadır, tüm uygulama değil.
3. **SMTP yedeği hazır.** Gönderimde sorun çıkarsa `mailer` (aktif bakımlı) devreye alınabilir; sadece `SmtpService` implementasyonu değişir.
4. **Kodlamadan önce Spike (Bölüm 0.5).** UI'ye hiç dokunmadan, gerçek sunucuya karşı şu 8 işlem bir konsol testinde doğrulanır: login → LIST → özel klasör tespiti → envelope FETCH → gövde FETCH → \Seen STORE → MOVE → SMTP gönder + Sent'e APPEND. Paket bu sunucuda çalışmıyorsa, **UI yazılmadan** öğrenilir.
