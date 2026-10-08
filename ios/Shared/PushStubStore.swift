import Foundation

/// Notification Service Extension'ın yazdığı, ana uygulamanın okuduğu "gelen
/// ileti kısa kaydı" deposu.
///
/// Uygulama arka planda ya da kapalıyken gelen her push'taki ileti (gönderen,
/// konu, tarih, uid) App Group konteynerine yazılır; uygulama açılınca liste
/// bu kayıtlardan IMAP eşitlemesini BEKLEMEDEN dolar (bkz. `PushStubs` Dart
/// tarafı). Bu dosya HER İKİ hedefe (Runner ve NotificationService) derlenir.
///
/// Kayıtlar tek dosyada değil, **ileti başına bir dosyada** tutulur
/// (`<App Group>/push_stubs/<hesap>-<uid>.json`): birden çok push eşzamanlı
/// işlenirse tek bir JSON'u okuyup-değiştirip-yazmak güncellemeleri ezerdi.
/// Dosya adı aynı iletiyi kendiliğinden tekilleştirir. Dosyalar atomik yazılır.
enum PushStubStore {
    /// `ShareInbox.appGroupIdentifier` ve entitlement'larla BİREBİR aynı olmalı.
    static let appGroupIdentifier = "group.tr.com.pazarlik.kaydet"
    static let directoryName = "push_stubs"

    /// Depoda tutulan en çok kayıt; aşılırsa en eskiler silinir.
    static let maxStubs = 200

    /// Bundan eski kayıtlar atılır (uygulama bu sürede açılmadıysa liste zaten
    /// eşitlemeyle dolacaktır).
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    struct Stub: Equatable {
        let accountId: Int
        let uid: Int
        let from: String
        let subject: String
        /// İletinin tarihi, epoch milisaniye; bilinmiyorsa alınma zamanı.
        let dateMs: Int64
        let receivedAtMs: Int64
    }

    static func rootURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: - Yazma (uzantı)

    /// Push yükündeki `items` listesinden (bkz. backend `payloadItems`) kayıtları
    /// yazar; `items` yoksa tek `uid` + bildirim başlığı/gövdesiyle yedek kayıt.
    static func record(userInfo: [AnyHashable: Any], title: String, body: String, root: URL) {
        guard let accountId = (userInfo["accountId"] as? NSNumber)?.intValue else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        var stubs: [Stub] = []
        if let items = userInfo["items"] as? [[String: Any]] {
            for item in items {
                guard let uid = (item["u"] as? NSNumber)?.intValue else { continue }
                let dateMs = (item["d"] as? String).flatMap(parseISODate) ?? nowMs
                stubs.append(Stub(
                    accountId: accountId,
                    uid: uid,
                    from: (item["f"] as? String) ?? "",
                    subject: (item["s"] as? String) ?? "",
                    dateMs: dateMs,
                    receivedAtMs: nowMs
                ))
            }
        } else if let uid = (userInfo["uid"] as? NSNumber)?.intValue {
            stubs.append(Stub(
                accountId: accountId, uid: uid, from: title, subject: body,
                dateMs: nowMs, receivedAtMs: nowMs
            ))
        }
        guard !stubs.isEmpty else { return }

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for stub in stubs { write(stub, root: root) }
        prune(root: root)
    }

    private static func fileURL(accountId: Int, uid: Int, root: URL) -> URL {
        root.appendingPathComponent("\(accountId)-\(uid).json", isDirectory: false)
    }

    private static func write(_ stub: Stub, root: URL) {
        let object: [String: Any] = [
            "accountId": stub.accountId,
            "uid": stub.uid,
            "from": stub.from,
            "subject": stub.subject,
            "dateMs": stub.dateMs,
            "receivedAtMs": stub.receivedAtMs,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: fileURL(accountId: stub.accountId, uid: stub.uid, root: root), options: .atomic)
    }

    private static func parseISODate(_ text: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    // MARK: - Okuma / silme (ana uygulama)

    /// Tüm kayıtlar, yeniden eskiye. Bozuk dosyalar atlanır.
    static func readAll(root: URL) -> [Stub] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var stubs: [Stub] = []
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                let accountId = (object["accountId"] as? NSNumber)?.intValue,
                let uid = (object["uid"] as? NSNumber)?.intValue
            else { continue }
            stubs.append(Stub(
                accountId: accountId,
                uid: uid,
                from: (object["from"] as? String) ?? "",
                subject: (object["subject"] as? String) ?? "",
                dateMs: (object["dateMs"] as? NSNumber)?.int64Value ?? 0,
                receivedAtMs: (object["receivedAtMs"] as? NSNumber)?.int64Value ?? 0
            ))
        }
        return stubs.sorted { $0.dateMs > $1.dateMs }
    }

    /// Eşitlemeyle gerçek iletisi gelen kayıtları siler.
    static func remove(accountId: Int, uids: [Int], root: URL) {
        for uid in uids {
            try? FileManager.default.removeItem(at: fileURL(accountId: accountId, uid: uid, root: root))
        }
    }

    /// Süresi dolanları ve tavanı aşan en eski kayıtları siler.
    static func prune(root: URL) {
        let cutoff = Int64((Date().timeIntervalSince1970 - maxAge) * 1000)
        var all = readAll(root: root)
        for stub in all where stub.receivedAtMs < cutoff {
            remove(accountId: stub.accountId, uids: [stub.uid], root: root)
        }
        all.removeAll { $0.receivedAtMs < cutoff }
        guard all.count > maxStubs else { return }
        for stub in all.sorted(by: { $0.receivedAtMs < $1.receivedAtMs }).prefix(all.count - maxStubs) {
            remove(accountId: stub.accountId, uids: [stub.uid], root: root)
        }
    }
}
