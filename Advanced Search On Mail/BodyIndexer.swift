//
//  BodyIndexer.swift
//  Advanced Search On Mail
//
//  Index plein texte (SQLite FTS5) du corps des emails, construit à partir des .emlx.
//

import Foundation
import SQLite3

nonisolated enum BodyIndexer {
    private static let lock = NSLock()

    static var indexPath: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/AdvancedSearchOnMail"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/index.sqlite"
    }

    static func openIndex() throws -> SQLite {
        let db = try SQLite(path: indexPath, readOnly: false)
        try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS body USING fts5(text, tokenize = 'unicode61 remove_diacritics 2');
            CREATE TABLE IF NOT EXISTS done(id INTEGER PRIMARY KEY, full INTEGER NOT NULL);
            """)
        return db
    }

    /// Indexe les messages pas encore traités (les plus récents d'abord).
    static func run(progress: @escaping @Sendable (Int, Int) -> Void) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        guard let db = try? openIndex(), let root = MailDB.mailRoot else { return }

        let files = MailFileMap.scan(root: root)
        MailFileMap.shared.set(files)

        var done: [Int64: Int64] = [:]
        try? db.query("SELECT id, full FROM done") { done[sqlite3_column_int64($0, 0)] = sqlite3_column_int64($0, 1) }

        let todo = files.keys.filter { id in
            guard let full = done[id] else { return true }
            return full == 0 && !(files[id]!.hasSuffix(".partial.emlx"))
        }.sorted(by: >)

        let total = files.count
        var count = total - todo.count
        progress(count, total)

        let chunkSize = 300
        var start = 0
        while start < todo.count {
            let ids = Array(todo[start..<min(start + chunkSize, todo.count)])
            start += chunkSize

            var texts = [String?](repeating: nil, count: ids.count)
            texts.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: ids.count) { i in
                    base[i] = EmlxParser.text(fromFile: files[ids[i]]!)
                }
            }

            try? db.exec("BEGIN")
            var del: OpaquePointer?, ins: OpaquePointer?, mark: OpaquePointer?
            sqlite3_prepare_v2(db.handle, "DELETE FROM body WHERE rowid = ?", -1, &del, nil)
            sqlite3_prepare_v2(db.handle, "INSERT INTO body(rowid, text) VALUES (?, ?)", -1, &ins, nil)
            sqlite3_prepare_v2(db.handle, "INSERT OR REPLACE INTO done(id, full) VALUES (?, ?)", -1, &mark, nil)
            for (i, id) in ids.enumerated() {
                sqlite3_bind_int64(del, 1, id); sqlite3_step(del); sqlite3_reset(del)
                if let t = texts[i] {
                    sqlite3_bind_int64(ins, 1, id)
                    sqlite3_bind_text(ins, 2, t, -1, SQLITE_TRANSIENT)
                    sqlite3_step(ins); sqlite3_reset(ins)
                }
                sqlite3_bind_int64(mark, 1, id)
                sqlite3_bind_int64(mark, 2, files[id]!.hasSuffix(".partial.emlx") ? 0 : 1)
                sqlite3_step(mark); sqlite3_reset(mark)
            }
            sqlite3_finalize(del); sqlite3_finalize(ins); sqlite3_finalize(mark)
            try? db.exec("COMMIT")

            count += ids.count
            progress(count, total)
        }
    }
}

// MARK: - Extraction du texte d'un .emlx

nonisolated enum EmlxParser {
    static let maxChars = 200_000

    static func text(fromFile path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              let nl = data.firstIndex(of: 0x0A) else { return nil }
        let first = String(decoding: data[data.startIndex..<nl], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let start = data.index(after: nl)
        let n = Int(first) ?? 0
        let end = n > 0 ? min(data.endIndex, start + n) : data.endIndex
        let t = partText(Data(data[start..<end]), depth: 0)
        return String(t.prefix(maxChars))
    }

    private static func partText(_ d: Data, depth: Int) -> String {
        guard depth < 8 else { return "" }
        let (head, body) = split(d)
        let h = parseHeaders(head)
        let (type, params) = parseContentType(h["content-type"] ?? "text/plain")
        if (h["content-disposition"] ?? "").lowercased().hasPrefix("attachment") { return "" }

        if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
            let s = String(data: body, encoding: .isoLatin1) ?? ""
            var out: [String] = []
            for part in s.components(separatedBy: "--" + boundary).dropFirst() {
                if part.hasPrefix("--") { break }
                var p = Substring(part)
                if p.hasPrefix("\r\n") { p = p.dropFirst(2) } else if p.hasPrefix("\n") { p = p.dropFirst() }
                if let pd = String(p).data(using: .isoLatin1) {
                    let t = partText(pd, depth: depth + 1)
                    if !t.isEmpty { out.append(t) }
                }
            }
            return out.joined(separator: "\n")
        }
        guard type == "text/plain" || type == "text/html" else { return "" }

        let raw: Data
        switch (h["content-transfer-encoding"] ?? "").lowercased() {
        case "base64":
            raw = Data(base64Encoded: body, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            raw = decodeQP(body)
        default:
            raw = body
        }
        let enc = encoding(params["charset"])
        let str = String(data: raw, encoding: enc) ?? String(decoding: raw, as: UTF8.self)
        return type == "text/html" ? stripHTML(str) : str
    }

    private static func split(_ d: Data) -> (String, Data) {
        let r1 = d.range(of: Data([13, 10, 13, 10])), r2 = d.range(of: Data([10, 10]))
        let r: Range<Data.Index>?
        if let a = r1, let b = r2 { r = a.lowerBound < b.lowerBound ? a : b } else { r = r1 ?? r2 }
        guard let r else { return (String(data: d, encoding: .isoLatin1) ?? "", Data()) }
        return (String(data: d[d.startIndex..<r.lowerBound], encoding: .isoLatin1) ?? "", Data(d[r.upperBound...]))
    }

    private static func parseHeaders(_ head: String) -> [String: String] {
        var h: [String: String] = [:]
        var last: String?
        for line in head.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if l.first == " " || l.first == "\t" {
                if let k = last { h[k, default: ""] += " " + l.trimmingCharacters(in: .whitespaces) }
            } else if let i = l.firstIndex(of: ":") {
                let k = l[..<i].lowercased()
                h[k] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
                last = k
            }
        }
        return h
    }

    private static func parseContentType(_ ct: String) -> (String, [String: String]) {
        let segs = ct.split(separator: ";")
        let type = segs.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        var params: [String: String] = [:]
        for s in segs.dropFirst() {
            let kv = s.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            params[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                kv[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return (type, params)
    }

    private static func encoding(_ name: String?) -> String.Encoding {
        guard let name else { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        if cf == kCFStringEncodingInvalidId { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private static func decodeQP(_ d: Data) -> Data {
        var out = Data(); out.reserveCapacity(d.count)
        let b = [UInt8](d)
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var i = 0
        while i < b.count {
            if b[i] == 61 { // "="
                if i + 1 < b.count, b[i + 1] == 10 { i += 2; continue }
                if i + 2 < b.count, b[i + 1] == 13, b[i + 2] == 10 { i += 3; continue }
                if i + 2 < b.count, let x = hex(b[i + 1]), let y = hex(b[i + 2]) {
                    out.append(x << 4 | y); i += 3; continue
                }
            }
            out.append(b[i]); i += 1
        }
        return out
    }

    private static func stripHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "(?is)<(style|script)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t
    }
}
