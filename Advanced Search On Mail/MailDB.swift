//
//  MailDB.swift
//  Advanced Search On Mail
//
//  Lecture de la base « Envelope Index » de Mail et recherche.
//

import AppKit
import Foundation
import SQLite3

nonisolated enum AttachmentFilter: String, CaseIterable, Identifiable {
    case any = "Peu importe"
    case with = "Avec pièce jointe"
    case without = "Sans pièce jointe"
    var id: String { rawValue }
}

nonisolated struct SearchCriteria: Equatable {
    var text = ""
    var inSubject = true
    var inBody = true
    var inSender = true
    var inRecipients = true
    var useFrom = false
    var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    var useTo = false
    var to = Date()
    var attachment: AttachmentFilter = .any
    var mailboxID: Int64? = nil

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
            && !useFrom && !useTo && attachment == .any && mailboxID == nil
    }
}

nonisolated struct MailHit: Identifiable, Hashable {
    let id: Int64           // ROWID dans Envelope Index
    let subject: String
    let sender: String
    let date: Date?
    let mailbox: String
}

nonisolated struct MailboxInfo: Identifiable, Hashable {
    let id: Int64
    let url: String
    let count: Int
    var label: String
}

nonisolated struct SearchResult {
    var hits: [MailHit]
    var truncated: Bool
}

nonisolated enum MailDB {
    static let maxResults = 1000

    // MARK: Emplacements

    static var mailRoot: String? {
        let root = NSHomeDirectory() + "/Library/Mail"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        let versions = items.compactMap { n -> (Int, String)? in
            guard n.hasPrefix("V"), let v = Int(n.dropFirst()) else { return nil }
            return (v, n)
        }.sorted { $0.0 > $1.0 }
        for (_, n) in versions where FileManager.default.fileExists(atPath: "\(root)/\(n)/MailData/Envelope Index") {
            return "\(root)/\(n)"
        }
        return nil
    }

    static let accessError = "Impossible de lire la base de Mail. Accordez l'« Accès complet au disque » à cette app (Réglages Système › Confidentialité et sécurité), puis relancez-la."

    static func openEnvelope() throws -> SQLite {
        guard let root = mailRoot else { throw DBError(accessError) }
        do {
            let db = try SQLite(path: root + "/MailData/Envelope Index", readOnly: true)
            db.registerFoldFunction()
            return db
        } catch {
            throw DBError(accessError + " (\(error.localizedDescription))")
        }
    }

    // MARK: Boîtes

    static func mailboxes() throws -> [MailboxInfo] {
        let db = try openEnvelope()
        var out: [MailboxInfo] = []
        try db.query("""
            SELECT mb.ROWID, mb.url, (SELECT COUNT(*) FROM messages m WHERE m.mailbox = mb.ROWID)
            FROM mailboxes mb
            """) { st in
            let n = Int(sqlite3_column_int64(st, 2))
            guard n > 0 else { return }
            let url = SQLite.text(st, 1)
            out.append(MailboxInfo(id: sqlite3_column_int64(st, 0), url: url, count: n, label: defaultLabel(url)))
        }
        return out
    }

    static func accountID(of url: String) -> String {
        URLComponents(string: url)?.host ?? ""
    }

    static func folderName(_ url: String) -> String {
        guard let p = URLComponents(string: url)?.percentEncodedPath.removingPercentEncoding else { return url }
        return p.split(separator: "/").map(String.init).joined(separator: " › ")
    }

    static func defaultLabel(_ url: String) -> String {
        let acc = accountID(of: url)
        return "\(acc.prefix(6)) · \(folderName(url))"
    }

    // MARK: Recherche

    static func search(_ c: SearchCriteria) throws -> SearchResult {
        for useRecipients in [true, false] {
            do { return try run(c, useRecipients: useRecipients) }
            catch where useRecipients { continue }
        }
        throw DBError("Recherche impossible")
    }

    private static func run(_ c: SearchCriteria, useRecipients: Bool) throws -> SearchResult {
        let db = try openEnvelope()

        let idxPath = BodyIndexer.indexPath
        if !FileManager.default.fileExists(atPath: idxPath) { _ = try? BodyIndexer.openIndex() }
        let hasIdx = (try? db.exec("ATTACH DATABASE '\(idxPath.replacingOccurrences(of: "'", with: "''"))' AS idx")) != nil

        var conds: [String] = []
        var binds: [Bind] = []

        if db.hasColumn("messages", "deleted") { conds.append("m.deleted = 0") }

        for w in c.text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let f = w.folded
            var ors: [String] = []
            if c.inSubject { ors.append("fold_has(s.subject, ?)"); binds.append(.text(f)) }
            if c.inSender {
                ors.append("fold_has(a.comment, ?)"); ors.append("fold_has(a.address, ?)")
                binds += [.text(f), .text(f)]
            }
            if c.inRecipients && useRecipients {
                ors.append("""
                    EXISTS (SELECT 1 FROM recipients r JOIN addresses ra ON ra.ROWID = r.address \
                    WHERE r.message_id = m.ROWID AND (fold_has(ra.address, ?) OR fold_has(ra.comment, ?)))
                    """)
                binds += [.text(f), .text(f)]
            }
            if c.inBody && hasIdx {
                ors.append("m.ROWID IN (SELECT rowid FROM idx.body WHERE body MATCH ?)")
                binds.append(.text("\"" + w.replacingOccurrences(of: "\"", with: "") + "\"*"))
            }
            if !ors.isEmpty { conds.append("(" + ors.joined(separator: " OR ") + ")") }
        }
        if c.useFrom {
            conds.append("m.date_received >= ?")
            binds.append(.int(Int64(Calendar.current.startOfDay(for: c.from).timeIntervalSince1970)))
        }
        if c.useTo {
            let end = Calendar.current.date(byAdding: .day, value: 1,
                                            to: Calendar.current.startOfDay(for: c.to)) ?? c.to
            conds.append("m.date_received < ?")
            binds.append(.int(Int64(end.timeIntervalSince1970)))
        }
        if let mb = c.mailboxID {
            conds.append("m.mailbox = ?")
            binds.append(.int(mb))
        }
        if c.attachment != .any, db.hasTable("attachments") {
            let neg = c.attachment == .without ? "NOT " : ""
            conds.append("\(neg)EXISTS (SELECT 1 FROM attachments t WHERE t.message_id = m.ROWID)")
        }

        let sql = """
            SELECT m.ROWID, COALESCE(s.subject, ''), COALESCE(a.comment, ''), COALESCE(a.address, ''),
                   m.date_received, COALESCE(mb.url, '')
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN mailboxes mb ON mb.ROWID = m.mailbox
            \(conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND "))
            ORDER BY m.date_received DESC
            LIMIT \(maxResults + 1)
            """

        var hits: [MailHit] = []
        try db.query(sql, binds) { st in
            let name = SQLite.text(st, 2)
            let sender = name.isEmpty ? SQLite.text(st, 3) : name
            let t = sqlite3_column_double(st, 4)
            hits.append(MailHit(id: sqlite3_column_int64(st, 0),
                                subject: SQLite.text(st, 1),
                                sender: sender,
                                date: t > 0 ? Date(timeIntervalSince1970: t) : nil,
                                mailbox: folderName(SQLite.text(st, 5))))
        }
        let truncated = hits.count > maxResults
        if truncated { hits.removeLast() }
        return SearchResult(hits: hits, truncated: truncated)
    }
}

// MARK: - Fichiers .emlx

nonisolated final class MailFileMap: @unchecked Sendable {
    static let shared = MailFileMap()
    private let lock = NSLock()
    private var map: [Int64: String] = [:]

    func set(_ m: [Int64: String]) { lock.lock(); map = m; lock.unlock() }
    func path(for id: Int64) -> String? { lock.lock(); defer { lock.unlock() }; return map[id] }

    /// Parcourt l'arborescence de Mail : ROWID -> chemin du .emlx.
    static func scan(root: String) -> [Int64: String] {
        var out: [Int64: String] = [:]
        guard let e = FileManager.default.enumerator(atPath: root) else { return out }
        for case let rel as String in e {
            if rel.hasSuffix("/Attachments") { e.skipDescendants(); continue }
            guard rel.hasSuffix(".emlx") else { continue }
            let name = (rel as NSString).lastPathComponent
            guard let idStr = name.split(separator: ".").first, let id = Int64(idStr) else { continue }
            let partial = name.hasSuffix(".partial.emlx")
            if partial && out[id] != nil { continue }
            out[id] = root + "/" + rel
        }
        return out
    }
}

nonisolated extension MailDB {
    /// En-tête Message-ID d'un message, lu dans la base de Mail (message_global_data).
    static func messageIDHeader(rowid: Int64) -> String? {
        guard let db = try? openEnvelope(), db.hasTable("message_global_data") else { return nil }
        var found: String?
        try? db.query("""
            SELECT g.* FROM messages m JOIN message_global_data g ON g.ROWID = m.global_message_id
            WHERE m.ROWID = ?
            """, [.int(rowid)]) { st in
            for i in 0..<sqlite3_column_count(st) where sqlite3_column_type(st, i) == SQLITE_TEXT {
                let v = SQLite.text(st, i).trimmingCharacters(in: .whitespacesAndNewlines)
                if v.contains("@"), !v.contains(" ") { found = v; break }
            }
        }
        guard var id = found else { return nil }
        if !id.hasPrefix("<") { id = "<" + id }
        if !id.hasSuffix(">") { id += ">" }
        return id
    }
}

@MainActor
enum MailOpener {
    private static func messageID(path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 32_000),
              let s = String(data: d, encoding: .isoLatin1),
              let r = s.range(of: #"(?im)^message-id:\s*(<[^>\r\n]+>)"#, options: .regularExpression),
              let a = s[r].firstIndex(of: "<"), let b = s[r].firstIndex(of: ">")
        else { return nil }
        return String(s[r][a...b])
    }

    private static func openURL(messageID id: String) -> Bool {
        guard let enc = id.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: "message://" + enc) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Ouvre le message dans Mail (la fenêtre de recherche reste ouverte). Renvoie un message d'erreur en cas d'échec.
    static func open(rowid: Int64) -> String? {
        // 1. Message-ID lu dans la base de Mail (marche même si le corps n'est pas téléchargé)
        if let id = MailDB.messageIDHeader(rowid: rowid), openURL(messageID: id) { return nil }
        // 2. Message-ID lu dans le fichier .emlx
        let path = MailFileMap.shared.path(for: rowid)
        if let path, let id = messageID(path: path), openURL(messageID: id) { return nil }
        // 3. Ouverture directe du fichier .emlx
        if let path, let mail = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") {
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: mail,
                                    configuration: NSWorkspace.OpenConfiguration())
            return nil
        }
        return "Impossible d'ouvrir ce message : il n'est pas disponible localement (boîte inactive ou non téléchargée ?). Activez le compte dans Mail et réessayez."
    }
}
