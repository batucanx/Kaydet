import Foundation

/// Share Extension ile ana uygulamanın ORTAK gelen kutusu.
///
/// Uzantı ayrı bir süreçtir ve ana uygulamadan bağımsız yaşar; ikisinin ortak
/// dosya alanı yalnızca **App Group** konteyneridir (Apple'ın önerdiği
/// mekanizma). Bu dosya HER İKİ hedefe (Runner ve ShareExtension) derlenir:
///
///     <App Group>/share_inbox/<id>/<dosya adı> + manifest.json
///
/// Manifestin biçimi, Android'deki `ShareInbox.kt` ve Flutter'daki
/// `SharePayload` ile AYNIDIR. **Tüketilmiş durumu:** manifestin varlığı "henüz
/// teslim edilmedi" demektir; Flutter `acknowledgeShare` ile manifesti siler
/// (dosyalar kalır — artık taslağın eki). Manifest, dosyalar kopyalandıktan
/// SONRA ve atomik yazılır; yarım kalmış bir kopya asla "bekleyen paylaşım"
/// olarak görünmez.
///
/// Sınır sabitleri Flutter'daki `ShareAttachmentPolicy` ile AYNI olmalı.
enum ShareInbox {
    /// Apple Developer hesabında tanımlı App Group. `Runner.entitlements` ve
    /// `ShareExtension.entitlements` içindekiyle BİREBİR aynı olmalı.
    static let appGroupIdentifier = "group.tr.com.pazarlik.kaydet"

    /// Uzantının ana uygulamayı uyandırmak için açtığı URL şeması. URL veri
    /// taşımaz. `Runner/Info.plist` (`CFBundleURLSchemes`) ve Flutter'daki
    /// `ShareIntakeService.iosUrlScheme` ile AYNI olmalı.
    static let urlScheme = "kaydetshare"

    static let directoryName = "share_inbox"
    static let manifestName = "manifest.json"

    /// Bkz. `ShareAttachmentPolicy.maxFileBytes`.
    static let maxFileBytes: Int64 = 25 * 1024 * 1024

    /// Bkz. `ShareAttachmentPolicy.maxTotalBytes`.
    static let maxTotalBytes: Int64 = 50 * 1024 * 1024

    /// Tek paylaşımda işlenecek en çok dosya.
    static let maxFiles = 50

    /// Gövdeye konacak metin için üst sınır.
    static let maxTextLength = 50_000

    enum InboxError: Error {
        case invalidId
        case appGroupUnavailable
    }

    // MARK: - Konum

    /// App Group konteynerindeki gelen kutusu; entitlement/App Group eksikse `nil`.
    static func rootURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Kimlik dizin adı olarak kullanılır; yalnızca `[A-Za-z0-9-]{8,64}` kabul edilir
    /// (yol ayırıcı, nokta vb. içeremez).
    static func isValidId(_ id: String?) -> Bool {
        guard let id = id, (8...64).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122: return true  // 0-9, A-Z, a-z
            case 45: return true                          // -
            default: return false
            }
        }
    }

    // MARK: - Yazma (uzantı)

    @discardableResult
    static func createPayloadDirectory(id: String, root: URL) throws -> URL {
        guard isValidId(id) else { throw InboxError.invalidId }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Manifesti atomik yazar (geçici dosyaya yaz → yeniden adlandır); bu andan
    /// itibaren paylaşım "bekleyen"dir.
    static func writeManifest(_ manifest: [String: Any], id: String, root: URL) throws {
        guard isValidId(id) else { throw InboxError.invalidId }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [])
        let url = root
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(manifestName)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Okuma (ana uygulama)

    /// Tüketilmemiş paylaşımların manifest metinleri, en eskiden yeniye. Bozuk
    /// manifestler ve dizin adıyla `id`si uyuşmayanlar atlanır.
    static func readPending(root: URL) -> [String] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [(receivedAtMs: Int64, text: String)] = []
        for directory in directories {
            let id = directory.lastPathComponent
            guard isValidId(id) else { continue }

            let manifestURL = directory.appendingPathComponent(manifestName)
            guard
                let data = try? Data(contentsOf: manifestURL),
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                (object["id"] as? String) == id,
                let text = String(data: data, encoding: .utf8)
            else { continue }

            let receivedAtMs = (object["receivedAtMs"] as? NSNumber)?.int64Value ?? 0
            entries.append((receivedAtMs, text))
        }
        return entries.sorted { $0.receivedAtMs < $1.receivedAtMs }.map { $0.text }
    }

    /// Tüketildi: manifesti siler, dosyalar kalır. Kimlik geçersizse yok sayılır.
    static func acknowledge(id: String?, root: URL) {
        guard let id = id, isValidId(id) else { return }
        let manifestURL = root
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(manifestName)
        try? FileManager.default.removeItem(at: manifestURL)
    }

    /// Paylaşımı dosyalarıyla birlikte siler. Kimlik geçersizse yok sayılır.
    static func discard(id: String?, root: URL) {
        guard let id = id, isValidId(id) else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
    }

    // MARK: - Dosya adı güvenliği

    /// Paylaşan uygulamanın verdiği ad GÜVENİLMEYEN girdidir: yol ayırıcılar ve
    /// `..` atılır, kontrol karakterleri ve Windows'ta geçersiz karakterler
    /// değiştirilir, uzunluk sınırlanır. Sonuç HER ZAMAN tek bir yol bileşenidir.
    /// Android'deki `ShareFileName.sanitize` ile aynı kurallar.
    static func sanitizeFileName(_ raw: String?) -> String {
        let maxBaseBytes = 120
        let maxExtensionLength = 16
        let invalid: Set<Character> = ["<", ">", ":", "\"", "|", "?", "*", "\\", "/"]

        // Yol bileşeni: son `/` ya da `\`ten sonrası (`../../etc/passwd` → `passwd`).
        var name = raw ?? ""
        if let separator = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: separator)...])
        }

        var cleaned = ""
        for character in name {
            let isControl = character.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
            if isControl { continue }
            cleaned.append(invalid.contains(character) ? "_" : character)
        }

        // Baştaki nokta gizli dosya/`..` demek, sondaki nokta-boşluk Windows'ta geçersiz.
        let trimSet = CharacterSet.whitespacesAndNewlines
        let dotSet = CharacterSet(charactersIn: ".")
        name = cleaned
            .trimmingCharacters(in: trimSet)
            .trimmingCharacters(in: dotSet)
            .trimmingCharacters(in: trimSet)

        var base = name
        var fileExtension = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let candidate = String(name[name.index(after: dot)...])
            if (1...maxExtensionLength).contains(candidate.count),
               candidate.allSatisfy({ $0.isLetter || $0.isNumber }) {
                base = String(name[..<dot])
                    .trimmingCharacters(in: trimSet)
                    .trimmingCharacters(in: dotSet)
                fileExtension = candidate
            }
        }

        if base.isEmpty { base = "ek" }
        base = truncateUTF8(base, maxBytes: maxBaseBytes)
            .trimmingCharacters(in: trimSet)
            .trimmingCharacters(in: dotSet)
        if base.isEmpty { base = "ek" }

        return fileExtension.isEmpty ? base : "\(base).\(fileExtension)"
    }

    /// [desired] [taken] içinde varsa (büyük/küçük harf duyarsız) uzantıdan önce
    /// ` (2)`, ` (3)`… ekler. Aynı paylaşımdaki iki `image.jpg` ayrı adlarla kalır.
    static func uniqueFileName(_ desired: String, taken: Set<String>) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        if !lowered.contains(desired.lowercased()) { return desired }

        let nsName = desired as NSString
        let fileExtension = nsName.pathExtension
        let base = nsName.deletingPathExtension
        var counter = 2
        while true {
            let candidate = fileExtension.isEmpty
                ? "\(base) (\(counter))"
                : "\(base) (\(counter)).\(fileExtension)"
            if !lowered.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }

    /// Karakter ortasından kesmeden en çok [maxBytes] UTF-8 baytına indirir.
    private static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        var bytes = 0
        var result = ""
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > maxBytes { break }
            bytes += size
            result.append(character)
        }
        return result
    }
}
