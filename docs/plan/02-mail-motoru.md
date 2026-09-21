# Bölüm 2 — Mail Motoru: IMAP/SMTP Senkronizasyon Stratejisi

Bu bölüm uygulamanın "kusursuz çalışan" olup olmayacağını belirleyen katmandır. Arayüz sonradan değiştirilebilir; senkronizasyon mantığı yanlış kurulursa kullanıcı **mail kaybeder**.

## 2.0 Temel Kural: UI asla ağı beklemez

```
        ┌─────────┐   dinler   ┌──────────┐
        │   UI    │ ◀───────── │  DRIFT   │  ← tek doğruluk kaynağı
        └────┬────┘   (Stream) └────▲─────┘
             │ eylem                │ yazar
             ▼                      │
        ┌─────────────────────────┴──────────┐
        │  Repository  →  PendingOperation    │
        └─────────────┬───────────────────────┘
                      │ arka planda
                      ▼
                 ┌─────────┐
                 │  IMAP   │
                 └─────────┘
```

Kullanıcı bir maili sildiğinde: Drift'te `mailboxId = trash` yazılır (UI 16 ms içinde günceller) → kuyruğa `move` işlemi eklenir → ağ varsa hemen, yoksa bağlantı gelince sunucuya işlenir. Sunucu reddederse yerel değişiklik geri alınır ve kullanıcıya bildirilir.

## 2.1 Bağlantı Yönetimi

Hesap başına **tek** kalıcı IMAP bağlantısı. Her ekranın kendi bağlantısını açması, sunucunun eşzamanlı bağlantı limitine (cPanel'de genelde 5-10) takılmanın ve "Too many connections" hatasının birinci sebebidir.

```
ImapConnectionManager (hesap başına singleton)
├── connect()        : ilk kullanımda tembel bağlanır
├── ensureReady()    : her komut öncesi bağlantı sağlığı kontrolü
├── keepAlive        : 4 dakikada bir NOOP (sunucular ~30 dk sonra düşürür)
├── reconnect()      : exponential backoff → 1s, 2s, 4s, 8s ... max 60s
├── connectivity_plus dinleyicisi : ağ döndüğünde anında yeniden bağlan
└── dispose()        : uygulama arka plana geçince veya hesap silinince
```

**Komut sıralaması (kritik):** IMAP tek kanalda sıralı protokoldür. İki komut aynı anda gönderilirse yanıtlar karışır. Tüm komutlar `synchronized` paketi ile tek bir kuyruktan geçer.

**Klasör seçimi (SELECT) maliyetlidir.** Aktif seçili klasör `ImapConnectionManager` içinde tutulur; aynı klasöre art arda SELECT gönderilmez.

## 2.2 İlk Senkronizasyon (Initial Sync)

Giriş başarılı olduktan sonra, kullanıcı boş ekrana bakmadan:

| Adım | İşlem | Süre hedefi |
|---|---|---|
| 1 | LOGIN + CAPABILITY oku (IDLE, CONDSTORE, QRESYNC, MOVE, SPECIAL-USE destekleri kaydedilir) | <2 sn |
| 2 | LIST/LSUB → klasörler + özel klasör tespiti → `mailboxes` tablosuna yaz | <1 sn |
| 3 | INBOX seç, UIDVALIDITY + UIDNEXT kaydet | <1 sn |
| 4 | En yeni **50** mailin envelope'ını çek → liste dolar, kullanıcı kullanmaya başlar | <3 sn |
| 5 | Arka planda sessizce 200 maile kadar devam | — |
| 6 | Diğer klasörler: **tembel** — ilk açıldığında senkronize olur | — |

**Envelope fetch'te ne çekiliyor:**
`UID FETCH <aralık> (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID IN-REPLY-TO REFERENCES)])`

Gövde çekilmez. `BODYSTRUCTURE` sayesinde ek olup olmadığı gövdeyi indirmeden bilinir.

**Önizleme metni (preview) sorunu.** Liste ekranındaki 3. satır (özet) için metin gerekir ama tam gövdeyi çekmek pahalıdır. Çözüm: `BODY.PEEK[1]<0.2048>` ile yalnızca ilk 2 KB'lık metin parçası çekilir, HTML ise etiketleri temizlenip 140 karaktere kırpılır. Bu, 50 mail için ~100 KB ek trafik demektir — kabul edilebilir.

> **`BODY.PEEK` vurgusu:** `BODY[...]` kullanılırsa sunucu maili **otomatik okundu işaretler**. Önizleme çekerken bu olursa tüm gelen kutusu kendiliğinden okunmuş görünür. Uygulamada `PEEK` dışında hiçbir varyant kullanılmayacak.

## 2.3 Artımlı Senkronizasyon (Delta Sync)

Her açılışta, her yenilemede (pull-to-refresh) ve her periyodik kontrolde çalışır. Üç ayrı soruya cevap arar:

### A. Klasör hâlâ geçerli mi?
```
SELECT klasör → UIDVALIDITY karşılaştır
   eşitse   → devam
   farklıysa → o klasörün TÜM yerel kayıtlarını sil, baştan çek
```
Bu kontrol atlanırsa, sunucu tarafında klasör yeniden oluşturulduğunda uygulama eski UID'lerle işlem yapar ve **yanlış maili siler/taşır**. Mail istemcilerindeki en tehlikeli hata sınıfıdır.

### B. Yeni mail var mı?
```
UIDNEXT değişmişse → UID FETCH <eski_uidnext>:* (envelope)
```

### C. Neler değişti / silindi?
İki yol, sunucu yeteneğine göre otomatik seçilir:

| Sunucu | Yöntem | Maliyet |
|---|---|---|
| CONDSTORE/QRESYNC destekliyorsa | `UID FETCH 1:* (FLAGS) (CHANGEDSINCE <modseq>)` + `VANISHED` | Çok ucuz, sadece değişenler gelir |
| Desteklemiyorsa (yaygın durum) | Son 500 UID için `UID SEARCH ALL` → yerel küme ile fark al; silinenler tespit edilir + `UID FETCH <son500> (FLAGS)` | Orta; 500 UID ~10 KB |

Sunucu yetenekleri `accounts` tablosunda saklanır, her seferinde yeniden sorgulanmaz.

## 2.4 Gövde ve Ek Dosya İndirme

| Ne zaman | İşlem |
|---|---|
| Mail açıldığında | `message_bodies` boşsa `UID FETCH <uid> BODY.PEEK[]` → MIME ayrıştır → text/plain + text/html ayrı sütunlara yaz |
| Ekler | Sadece metadata (ad, tür, boyut) BODYSTRUCTURE'dan gelir. Dosyanın kendisi **kullanıcı dokununca** indirilir → `AttachmentStore` uygulama dizinine yazar, `localPath` güncellenir |
| Inline görseller (`cid:`) | HTML render'da gerekliyse ilgili part indirilir, `cid:` → `file://` yeniden yazılır |
| Önbellek | Gövdeler kalıcı. Ayarlar'da "Önbelleği temizle" ile silinir; 30 günden eski gövdeler otomatik budanır (envelope kalır) |

**Okundu işaretleme kuralı:** Mail açıldıktan **1,5 saniye sonra** `\Seen` eklenir. Anında işaretlenirse, kullanıcı yanlış maile dokunup hemen geri çıktığında mail okunmuş sayılır — gerçek istemcilerin hepsinde bu gecikme vardır.

## 2.5 Gönderim ve Outbox

React'te `handleSendMail` sadece listeye bir nesne ekliyordu. Gerçekte gönderim çok adımlı ve her adımı başarısız olabilir:

```
1. Compose ekranı → MimeMessage oluştur (MessageBuilder)
     - Message-ID üret: <timestamp.random@barzamakina.com.tr>
     - Yanıtsa: In-Reply-To + References başlıkları eklenir  ← thread devamlılığı
     - İmza gövdeye eklenir, ekler MIME part olarak bağlanır
2. Mesaj yerel DB'ye "outbox" durumunda yazılır → UI'de "Gönderiliyor..." görünür
3. PendingOperation(send) kuyruğa girer
4. SMTP: bağlan → STARTTLS/SSL → AUTH → MAIL FROM → RCPT TO → DATA
5. Başarılı → IMAP APPEND ile Sent klasörüne \Seen bayrağıyla yaz
6. Yerel kayıt "sent" durumuna geçer, taslak varsa silinir
```

**Hata senaryoları ve davranış:**

| Hata | Davranış |
|---|---|
| Ağ yok | Outbox'ta bekler, ağ gelince otomatik gönderilir. UI'de saat ikonu. |
| SMTP kimlik doğrulama hatası | Kuyruk durur, kullanıcıya "Şifre hatalı" bildirimi + Ayarlar'a yönlendirme |
| Alıcı reddedildi (5xx) | Kalıcı hata: tekrar denenmez, mail Outbox'ta "Gönderilemedi" olarak kalır, sebep gösterilir |
| Geçici hata (4xx) | 3 deneme, aralar 30 sn / 5 dk / 30 dk |
| SMTP başarılı ama APPEND başarısız | Mail **gönderilmiştir**, iki kez gönderilmez. APPEND ayrı bir kuyruk işi olarak tekrar denenir |

> Adım 4 ile 5'in ayrılması şart. İkisi tek işlem sayılırsa, APPEND hatasında gönderim tekrarlanır ve **alıcı maili iki kez alır**.

## 2.6 Taslaklar

- Compose ekranında **3 saniyelik yazma duraklamasında** yerel taslak otomatik kaydedilir (uygulama çökse bile kayıp yok).
- Ekrandan çıkarken React'teki diyalog korunur: *Taslağı Kaydet / Sil / İptal*.
- "Kaydet" seçilirse taslak IMAP Drafts klasörüne `APPEND` edilir (`\Draft` bayrağıyla). Aynı taslağın önceki sürümü sunucudan silinir — IMAP'te "güncelleme" yoktur, sil-yeniden yaz vardır.
- Taslağa dokunulduğunda Compose ekranı o taslakla açılır; gönderilince taslak hem yerelden hem sunucudan silinir.

## 2.7 Kullanıcı Eylemi → IMAP Komutu Eşlemesi

| UI eylemi | IMAP karşılığı | Not |
|---|---|---|
| Okundu işaretle | `UID STORE +FLAGS (\Seen)` | |
| Okunmadı yap | `UID STORE -FLAGS (\Seen)` | |
| Sabitle / kaldır | `UID STORE ±FLAGS (\Flagged)` | Bölüm 1 kararı |
| Etiketle | `UID STORE +FLAGS (kaydet_<etiket>)` | Sunucu keyword destekliyorsa |
| Sil (normal klasörde) | `UID MOVE → Trash` (MOVE yoksa COPY + STORE \Deleted + EXPUNGE) | |
| Sil (Çöp Kutusu içinde) | `UID STORE +FLAGS (\Deleted)` + `UID EXPUNGE` | **Onay diyaloğu zorunlu** — geri dönüşü yok |
| Arşivle | `UID MOVE → Archive` | Klasör yoksa oluşturma teklif edilir |
| Spam bildir | `UID MOVE → Junk/Spam` | React'te yanlışlıkla silme yapıyordu |
| Taşı | `UID MOVE → seçilen klasör` | Klasör seçim sayfası (React'te `alert()` idi) |
| Çöp kutusunu boşalt | Tüm UID'lere `\Deleted` + `EXPUNGE` | Çift onay |

**Toplu işlemler** tek komutta gönderilir: `UID STORE 12,15,18:24 +FLAGS (\Seen)`. 200 mail seçildiğinde 200 ayrı istek atılmaz.

## 2.8 Hata Taksonomisi

Hiçbir yerde ham `Exception` yukarı fırlatılmaz. Her repository `Result<T>` döner:

| Hata tipi | Kullanıcıya gösterilen Türkçe mesaj | Eylem |
|---|---|---|
| `AuthFailure` | "Kullanıcı adı veya şifre hatalı" | Ayarlar > Hesap'a yönlendir |
| `ConnectionFailure` | "Sunucuya ulaşılamıyor" | Otomatik tekrar dene, çevrimdışı rozeti göster |
| `TlsFailure` | "Güvenli bağlantı kurulamadı (sertifika)" | Port/güvenlik ayarını kontrol et uyarısı |
| `MailboxNotFound` | "Klasör bulunamadı" | Klasör listesini yeniden senkronize et |
| `UidValidityChanged` | (sessiz) | Otomatik tam yeniden senkronizasyon |
| `QuotaExceeded` | "Posta kutusu dolu" | |
| `ParseFailure` | (sessiz, loglanır) | Mail ham metin olarak gösterilir, uygulama çökmez |
| `StorageFailure` | "Cihaz depolaması dolu" | |

**Bozuk mail kuralı:** Standart dışı MIME yüzünden bir mail ayrıştırılamıyorsa **uygulama çökmez, o mail listede kaybolmaz**. Konu satırı ham haliyle gösterilir, gövde düz metin olarak sunulur. Tek bir bozuk mail yüzünden tüm gelen kutusunun açılmaması, amatör istemcilerin klasik hatasıdır.

## 2.9 Sayfalama (Sonsuz Kaydırma)

React'te rastgele sahte mail üretiliyordu. Gerçek karşılığı:

```
Liste en alta yaklaştığında (son 10 öğe görününce):
  1. Yerel DB'de daha eski mail var mı?  → varsa anında göster (ağ yok, 0 ms)
  2. Yoksa → sunucudan bir sonraki 50 eski UID'nin envelope'ı çekilir
  3. Sunucuda da kalmadıysa → "Tüm mailler yüklendi" göstergesi
```

- Flutter'da `ListView.builder` + `ScrollController` kullanıldığı için React'teki "liste başa atlıyor" sorunu yapısal olarak oluşmaz.
- Liste durumu `PageStorageKey` ile korunur: mail açıp geri dönüldüğünde kaydırma konumu aynı kalır.
- Yükleme göstergesi listenin sonunda ayrı bir öğe olarak render edilir; liste yeniden kurulmaz.

## 2.10 Anlık Bildirim (IDLE) — Bölüm 5'e köprü

- **Uygulama önplandayken:** IMAP `IDLE` açıktır, yeni mail saniyeler içinde düşer. 29 dakikada bir IDLE yenilenir (RFC gereği).
- **Arka plandayken — "Anlık" mod (varsayılan):** Android IDLE bağlantısını sıradan bir arka plan sürecinde yaşatmaz; sürekli dinlemenin tek güvenilir yolu kalıcı bildirimli bir **ön plan servisidir** (`flutter_foreground_task`, tür `specialUse`). Servis içinde her hesap için ayrı bir `AccountWatcher` kendi IMAP bağlantısını açık tutar (`lib/data/repositories/account_watcher.dart`, `lib/app/push_task_handler.dart`); yeni mail geldiği anda eşitleyip bildirimi basar. Bedeli: durum çubuğunda sessiz bir "Kaydet" bildirimi ve pil — Ayarlar ekranında açıkça yazılır. Servis yalnızca bildirimler açık + sıklık "Anlık" + en az bir hesap + sistem izni varken çalışır (`lib/app/push_controller.dart`).
- **Yedek ve diğer sıklıklar:** `workmanager` periyodik görevi (15 dk / 30 dk / 1 saat / manuel) sürer. Anlık modda servis öldürülürse ya da bir bağlantı sessizce koparsa kaçan iletileri bu görev toplar; diğer sıklıklarda bildirimin tek kaynağıdır ve Android'in 15 dakikalık alt sınırı geçerlidir.
- **Bildirim içeriği** (`NotificationService`, `NewMailNotifier`): başlıkta gönderen, kapalı hâlde konu, açılınca konu + önizleme; üst satırda hesabın e-postası ve iletinin geliş saati. Eylemler: Arşivle, Sil (arka plan isolate'inde), Yanıtla (uygulamayı yanıt ekranında açar). İlk indirmede (yeni hesap) bildirim üretilmez.
- Detaylar Bölüm 5'te.

## 2.11 Bölüm 0.5 — Spike (kodlamadan önceki zorunlu adım)

UI'ye tek satır yazmadan, konsol uygulamasında gerçek sunucuya karşı doğrulanacaklar:

- [ ] LOGIN + CAPABILITY (IDLE / MOVE / CONDSTORE / SPECIAL-USE var mı?)
- [ ] LIST → klasörler ve Türkçe adların doğru eşlenmesi
- [ ] Envelope FETCH (50 mail, süre ölçümü)
- [ ] Türkçe karakterli konu başlıklarının doğru çözülmesi (RFC 2047 encoded-word)
- [ ] Gövde FETCH + HTML/plain ayrımı + ek tespiti
- [ ] `\Seen` ve `\Flagged` STORE, webmail'de doğrulama
- [ ] MOVE (Trash'e) ve geri alma
- [ ] Özel keyword (etiket) yazma denemesi → `PERMANENTFLAGS` yanıtı
- [ ] SMTP gönderim + Sent'e APPEND
- [ ] IDLE ile yeni mail bildirimi

Bu 10 madde geçerse mimari doğrulanmış olur ve UI'ye güvenle geçilir. Herhangi biri patlarsa, **çözümü UI yazıldıktan sonra değil şimdi** bulunur.
