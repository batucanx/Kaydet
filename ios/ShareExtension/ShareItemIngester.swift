import Foundation
import UniformTypeIdentifiers

/// Share Extension'a verilen `NSItemProvider`'ları App Group gelen kutusuna
/// (`ShareInbox`) kopyalar ve manifesti yazar.
///
/// Kullanıcı dosyayı zaten sistem Share Sheet'inden bu uzantıya verdiği için
/// Fotoğraflar/Dosyalar izni İSTENMEZ: her şey `NSItemProvider` üzerinden
/// okunur. İçerik belleğe ALINMAZ (uzantıların bellek sınırı düşüktür); dosyalar
/// `FileManager` ile disk üstünde kopyalanır. Hiçbir hata uzantıyı çökertmez:
/// okunamayan/çok büyük/boş dosya manifestin `issues` listesine yazılır ve
/// Flutter kullanıcıya anlaşılır bir mesaj gösterir.
enum ShareItemIngester {
    enum Outcome {
        /// Manifest yazıldı; ana uygulama açılabilir.
        case delivered(id: String)
        /// Kullanılabilir hiçbir şey kalmadı; [message] kullanıcıya gösterilir.
        case failed(message: String)
        /// Kullanıcı Share Sheet'ten vazgeçti; yarım kopya silindi.
        case cancelled
    }

    private struct Issue {
        let code: String
        let fileName: String?
    }

    private struct FileEntry {
        let fileName: String
        let mimeType: String
        let sizeBytes: Int64
    }

    private struct State {
        var files: [FileEntry] = []
        var issues: [Issue] = []
        var takenNames = Set<String>()
        var totalBytes: Int64 = 0
        var texts: [String] = []
    }

    private enum LoadError: Error {
        case unreadable
    }

    /// Bir dosyanın kopyalanma sonucu. `store` paylaşılan durumu DEĞİŞTİRMEZ,
    /// sonucu değer olarak döndürür: `loadFileRepresentation`ın geri çağrısı
    /// eşzamanlı çalışan (`@Sendable`) bir kapanıştır ve yakalanan `var`ı
    /// değiştirmek derleme hatasıdır.
    private enum StoreResult {
        case stored(FileEntry)
        case rejected(Issue)
    }

    // MARK: - Giriş noktası

    static func ingest(items: [NSExtensionItem]) async -> Outcome {
        guard let root = ShareInbox.rootURL() else {
            // App Group erişilemiyor: entitlement/portal yapılandırması eksik.
            return .failed(message: "Paylaşılan alana erişilemedi. Lütfen Kaydet uygulamasını güncelleyip yeniden deneyin.")
        }

        let id = UUID().uuidString
        let directory: URL
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            directory = try ShareInbox.createPayloadDirectory(id: id, root: root)
        } catch {
            return .failed(message: "Paylaşılan içerik cihaza kaydedilemedi.")
        }

        var state = State()
        let subject = items
            .compactMap { $0.attributedTitle?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers {
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: directory)
                return .cancelled
            }
            if state.files.count >= ShareInbox.maxFiles {
                state.issues.append(Issue(code: "unknown", fileName: nil))
                break
            }
            await ingest(provider: provider, into: directory, state: &state)
        }

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: directory)
            return .cancelled
        }

        // Kullanılabilir hiçbir şey kalmadıysa ana uygulamayı açmanın anlamı yok.
        if state.files.isEmpty && state.texts.isEmpty {
            try? FileManager.default.removeItem(at: directory)
            return .failed(message: describe(state.issues) ?? "Paylaşılan içerik alınamadı.")
        }

        // Tek büyük sözlük literali yerine parça parça kurulur: derleyicinin
        // "ifade çok karmaşık" hatasına düşmemesi için.
        var fileEntries: [[String: Any]] = []
        for file in state.files {
            var entry: [String: Any] = [:]
            entry["fileName"] = file.fileName
            entry["mimeType"] = file.mimeType
            entry["sizeBytes"] = file.sizeBytes
            fileEntries.append(entry)
        }
        var issueEntries: [[String: Any]] = []
        for issue in state.issues {
            var entry: [String: Any] = ["code": issue.code]
            if let name = issue.fileName { entry["fileName"] = name }
            issueEntries.append(entry)
        }

        var manifest: [String: Any] = [:]
        manifest["version"] = 1
        manifest["id"] = id
        manifest["source"] = "ios-share-extension"
        manifest["receivedAtMs"] = Int64(Date().timeIntervalSince1970 * 1000)
        manifest["files"] = fileEntries
        manifest["issues"] = issueEntries
        if !state.texts.isEmpty {
            manifest["text"] = String(state.texts.joined(separator: "\n").prefix(ShareInbox.maxTextLength))
        }
        if let subject = subject {
            manifest["subject"] = String(subject.prefix(998))
        }

        do {
            try ShareInbox.writeManifest(manifest, id: id, root: root)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return .failed(message: "Paylaşılan içerik cihaza kaydedilemedi.")
        }
        return .delivered(id: id)
    }

    // MARK: - Tek öğe

    private static func ingest(provider: NSItemProvider, into directory: URL, state: inout State) async {
        // Dosya olarak (Dosyalar, diğer uygulamalar): önce `public.file-url`.
        // `public.url`un alt türü olduğundan, web bağlantısından ayırmak için
        // ilk bu sınanır.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            await ingestFileURL(provider, into: directory, state: &state)
            return
        }

        // Fotoğraflar/Videolar: özgün biçimi (HEIC/JPEG/PNG…) korunur.
        for kind in [UTType.image, UTType.movie] where provider.hasItemConformingToTypeIdentifier(kind.identifier) {
            let identifier = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: kind) == true
            } ?? kind.identifier
            await ingestRepresentation(provider, typeIdentifier: identifier, into: directory, state: &state)
            return
        }

        // Bağlantı / düz metin (Safari, Notlar…): gövdeye konur.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            await ingestText(provider, typeIdentifier: UTType.url.identifier, state: &state)
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            await ingestText(provider, typeIdentifier: UTType.plainText.identifier, state: &state)
            return
        }

        // Diğer her şey (PDF, Word, ZIP…): genel veri olarak dosya.
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            let identifier = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .data) == true
            } ?? UTType.data.identifier
            await ingestRepresentation(provider, typeIdentifier: identifier, into: directory, state: &state)
            return
        }

        state.issues.append(Issue(code: "unreadable", fileName: provider.suggestedName))
    }

    /// `public.file-url`: dosya, sağlayıcının sandbox'ında durur; okunup kopyalanır.
    private static func ingestFileURL(_ provider: NSItemProvider, into directory: URL, state: inout State) async {
        let source: URL
        do {
            source = try await loadFileURL(from: provider)
        } catch {
            state.issues.append(Issue(code: "unreadable", fileName: provider.suggestedName))
            return
        }

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // Klasör paylaşımı desteklenmez.
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true {
            state.issues.append(Issue(code: "unreadable", fileName: source.lastPathComponent))
            return
        }

        let result = store(
            from: source,
            suggestedName: provider.suggestedName,
            typeIdentifier: nil,
            into: directory,
            coordinated: true,
            takenNames: state.takenNames,
            totalBytes: state.totalBytes
        )
        apply(result, to: &state)
    }

    /// Fotoğraflar ve genel veri: `loadFileRepresentation` geçici bir dosya
    /// verir ve yalnızca geri çağrı SÜRESİNCE geçerlidir — kopya o içinde yapılır.
    private static func ingestRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String,
        into directory: URL,
        state: inout State
    ) async {
        let suggestedName = provider.suggestedName
        // Kapanışa yalnızca DEĞİŞMEZ değerler girer (bkz. `StoreResult`).
        let takenNames = state.takenNames
        let totalBytes = state.totalBytes

        let result: StoreResult = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url = url, error == nil else {
                    continuation.resume(returning: .rejected(Issue(code: "unreadable", fileName: suggestedName)))
                    return
                }
                continuation.resume(
                    returning: store(
                        from: url,
                        suggestedName: suggestedName,
                        typeIdentifier: typeIdentifier,
                        into: directory,
                        coordinated: false,
                        takenNames: takenNames,
                        totalBytes: totalBytes
                    )
                )
            }
        }
        apply(result, to: &state)
    }

    /// Bağlantı ya da düz metin → gövde metni.
    private static func ingestText(_ provider: NSItemProvider, typeIdentifier: String, state: inout State) async {
        do {
            let item = try await loadItem(from: provider, typeIdentifier: typeIdentifier)
            let value: String?
            if let url = item as? URL {
                value = url.absoluteString
            } else if let string = item as? String {
                value = string
            } else if let attributed = item as? NSAttributedString {
                value = attributed.string
            } else if let data = item as? Data {
                value = String(data: data, encoding: .utf8)
            } else {
                value = nil
            }

            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                state.issues.append(Issue(code: "unreadable", fileName: nil))
                return
            }
            // Bazı uygulamalar aynı bağlantıyı hem URL hem metin olarak verir.
            if !state.texts.contains(where: { $0.contains(text) }) {
                state.texts.append(text)
            }
        } catch {
            state.issues.append(Issue(code: "unreadable", fileName: nil))
        }
    }

    // MARK: - Kopyalama

    /// [source]'u paylaşım dizinine güvenli adla kopyalar. Sınırlar ve hatalar
    /// `.rejected` olarak döner, asla fırlatmaz.
    private static func store(
        from source: URL,
        suggestedName: String?,
        typeIdentifier: String?,
        into directory: URL,
        coordinated: Bool,
        takenNames: Set<String>,
        totalBytes: Int64
    ) -> StoreResult {
        // Ad: önerilen ad (genellikle uzantısız) ya da dosyanın kendi adı;
        // uzantı yoksa dosyadan/türden tamamlanır.
        var rawName = (suggestedName?.isEmpty == false) ? suggestedName! : source.lastPathComponent
        if (rawName as NSString).pathExtension.isEmpty {
            let fromFile = source.pathExtension
            let fromType = typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension }
            if !fromFile.isEmpty {
                rawName += "." + fromFile
            } else if let fromType = fromType, !fromType.isEmpty {
                rawName += "." + fromType
            }
        }
        let fileName = ShareInbox.uniqueFileName(
            ShareInbox.sanitizeFileName(rawName),
            taken: takenNames
        )

        // Boyut önceden biliniyorsa hiç kopyalamaya başlanmaz.
        if let declared = fileSize(of: source),
           declared > ShareInbox.maxFileBytes || totalBytes + declared > ShareInbox.maxTotalBytes {
            return .rejected(Issue(code: "tooLarge", fileName: fileName))
        }

        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        // Ad zaten temizlendi; yine de hedefin gerçekten paylaşım dizininde
        // kaldığı doğrulanır.
        // `.path` karşılaştırılır: iki URL'den biri sondaki `/` ile bitiyorsa
        // `==` yanlışlıkla eşit saymaz ve TÜM dosyalar reddedilirdi.
        guard destination.deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path else {
            return .rejected(Issue(code: "unreadable", fileName: fileName))
        }

        do {
            if coordinated {
                try copyCoordinated(from: source, to: destination)
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            let nsError = error as NSError
            let isOutOfSpace = nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSFileWriteOutOfSpaceError
            return .rejected(Issue(code: isOutOfSpace ? "storage" : "unreadable", fileName: fileName))
        }

        // Bildirilen boyuta güvenilmez: gerçek boyut kopyadan okunur.
        let actualSize = fileSize(of: destination) ?? 0
        if actualSize == 0 {
            try? FileManager.default.removeItem(at: destination)
            return .rejected(Issue(code: "empty", fileName: fileName))
        }
        if actualSize > ShareInbox.maxFileBytes || totalBytes + actualSize > ShareInbox.maxTotalBytes {
            try? FileManager.default.removeItem(at: destination)
            return .rejected(Issue(code: "tooLarge", fileName: fileName))
        }

        return .stored(
            FileEntry(
                fileName: fileName,
                mimeType: mimeType(for: fileName, typeIdentifier: typeIdentifier),
                sizeBytes: actualSize
            )
        )
    }

    private static func apply(_ result: StoreResult, to state: inout State) {
        switch result {
        case .stored(let file):
            state.takenNames.insert(file.fileName)
            state.totalBytes += file.sizeBytes
            state.files.append(file)
        case .rejected(let issue):
            state.issues.append(issue)
        }
    }

    /// iCloud Drive gibi dosya sağlayıcılarından okurken `NSFileCoordinator`
    /// kullanılır (dosya henüz indirilmemişse indirilmesini de sağlar).
    private static func copyCoordinated(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source,
            options: .withoutChanges,
            error: &coordinationError
        ) { readable in
            do {
                try FileManager.default.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
    }

    private static func fileSize(of url: URL) -> Int64? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return Int64(size)
    }

    /// Tür tanımlayıcısından → uzantıdan → genel ikili.
    private static func mimeType(for fileName: String, typeIdentifier: String?) -> String {
        if let identifier = typeIdentifier,
           let mime = UTType(identifier)?.preferredMIMEType {
            return mime
        }
        let fileExtension = (fileName as NSString).pathExtension
        if !fileExtension.isEmpty,
           let mime = UTType(filenameExtension: fileExtension)?.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    // MARK: - NSItemProvider sarmalayıcıları

    private static func loadFileURL(from provider: NSItemProvider) async throws -> URL {
        let item = try await loadItem(from: provider, typeIdentifier: UTType.fileURL.identifier)
        if let url = item as? URL { return url }
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
        throw LoadError.unreadable
    }

    private static func loadItem(from provider: NSItemProvider, typeIdentifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item)
                }
            }
        }
    }

    // MARK: - Kullanıcı mesajı

    /// Flutter'daki `ShareAttachmentPolicy.describe` ile aynı cümleler.
    private static func describe(_ issues: [Issue]) -> String? {
        if issues.isEmpty { return nil }
        if issues.count > 1 {
            return "\(issues.count) dosya eklenemedi (çok büyük, desteklenmeyen ya da okunamayan dosyalar)."
        }
        let issue = issues[0]
        let name = issue.fileName.map { "“\($0)”" } ?? "Dosya"
        switch issue.code {
        case "tooLarge":
            return "\(name) çok büyük (en fazla \(ShareInbox.maxFileBytes >> 20) MB) ve eklenmedi."
        case "empty":
            return "\(name) boş olduğu için eklenmedi."
        case "storage":
            return "\(name) cihaza kaydedilemediği için eklenmedi."
        default:
            return "\(name) okunamadığı için eklenmedi."
        }
    }
}
