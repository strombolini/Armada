import Foundation
import PDFKit

/// Short text previews that go into the rerank request so Codiv can judge files by content, not just name.
enum Preview {
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "py", "ts", "tsx", "js", "jsx", "swift", "sh", "zsh",
                                              "html", "htm", "yaml", "yml", "toml", "rtf", "tex", "log", "xml", "ini", "cfg", "conf", "rb", "go",
                                              "rs", "c", "h", "cpp", "java", "kt", "sql", "env", "plist", "srt", "vtt", "org", "rst"]

    /// Files whose names suggest secrets never have their contents sent anywhere.
    static func isSensitive(_ path: String) -> Bool {
        let n = (path as NSString).lastPathComponent.lowercased()
        let words = ["secret", "password", "passwd", "credential", "token", "apikey", "api-key", "api_key", "private", ".env", "id_rsa", "id_ed25519",
                     ".pem", ".p12", ".key", "keychain", "recovery-codes", "recovery codes", "2fa", "seed phrase", "mnemonic", "wallet"]
        return words.contains { n.contains($0) }
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: String?] = [:]

    /// Previews for many files, concurrently, with a hard time budget so a slow PDF never stalls a search.
    static func texts(for paths: [String], budgetMs: Int = 700) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self, returning: [String: String].self) { group in
            let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000)
            for p in paths { group.addTask { (p, Date() < deadline ? text(for: p) : nil) } }
            var out: [String: String] = [:]
            for await (p, t) in group { if let t { out[p] = t } }
            return out
        }
    }

    static func text(for path: String, maxChars: Int = 220) -> String? {
        let url = URL(fileURLWithPath: path)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(mtime)|\(maxChars)"
        cacheLock.lock(); if let c = cache[key] { cacheLock.unlock(); return c }; cacheLock.unlock()
        let result = compute(url: url, maxChars: maxChars)
        cacheLock.lock(); cache[key] = result; if cache.count > 5000 { cache.removeAll() }; cacheLock.unlock()
        return result
    }

    private static func compute(url: URL, maxChars: Int) -> String? {
        let ext = url.pathExtension.lowercased()
        // Spotlight has already extracted the text of most documents; that is far cheaper than parsing the file.
        if ext == "pdf" || ext == "docx" || ext == "doc" || ext == "pages" || ext == "key" || ext == "numbers" || ext == "pptx" || ext == "xlsx" || ext == "rtf" || ext == "epub" {
            if let t = officeText(url, maxChars: maxChars) { return t }
            if ext == "pdf" { return pdfText(url, maxChars: maxChars) }
            return nil
        }
        guard textExtensions.contains(ext) || ext.isEmpty else { return nil }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 4000)) ?? Data()
        guard !data.isEmpty else { return nil }
        // Reject binaries: too many non-printable bytes.
        let bad = data.prefix(512).filter { $0 < 9 || ($0 > 13 && $0 < 32) }.count
        if bad > 8 { return nil }
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return clean(s, maxChars: maxChars)
    }

    private static func pdfText(_ url: URL, maxChars: Int) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url), let head = try? fh.read(upToCount: 5), head == Data("%PDF-".utf8) else { return nil }
        try? fh.close()
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
        var s = ""
        for i in 0..<min(1, doc.pageCount) {
            if let t = doc.page(at: i)?.string { s += t + " " }
            if s.count > maxChars * 2 { break }
        }
        return clean(s, maxChars: maxChars)
    }

    /// .docx/.pptx/.xlsx/.pages/.key are zip containers; Spotlight already extracted their text, so ask it.
    private static func officeText(_ url: URL, maxChars: Int) -> String? {
        let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL)
        guard let item else { return nil }
        if let t = MDItemCopyAttribute(item, kMDItemTextContent) as? String { return clean(t, maxChars: maxChars) }
        if let t = MDItemCopyAttribute(item, kMDItemTitle) as? String { return clean(t, maxChars: maxChars) }
        return nil
    }

    static func clean(_ s: String, maxChars: Int) -> String? {
        let filtered = s.unicodeScalars.filter { $0 == " " || $0 == "\n" || $0 == "\t" || ($0.value >= 32 && $0.value != 127) }
        let joined = String(String.UnicodeScalarView(filtered)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let out = String(joined.prefix(maxChars))
        return out.count >= 8 ? out : nil
    }
}
