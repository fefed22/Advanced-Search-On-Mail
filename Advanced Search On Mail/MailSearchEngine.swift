//
//  MailSearchEngine.swift
//  Advanced Search On Mail
//

import AppKit
import Combine
import Foundation

@MainActor
final class MailSearchEngine: ObservableObject {
    @Published var results: [MailHit] = []
    @Published var isSearching = false
    @Published var truncated = false
    @Published var errorMessage: String?
    @Published var errorSettingsURL: String? = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    @Published var mailboxes: [MailboxInfo] = []
    @Published var indexing = false
    @Published var indexed = 0
    @Published var total = 0

    static let maxResults = MailDB.maxResults
    private var generation = 0
    private var timer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        loadMailboxes()
        startIndexing()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startIndexing() }
        }
    }

    // MARK: Recherche

    func search(_ c: SearchCriteria) {
        generation += 1
        let gen = generation
        guard !c.isEmpty else {
            results = []; isSearching = false; truncated = false
            return
        }
        isSearching = true
        Task.detached(priority: .userInitiated) { [weak self] in
            var res: SearchResult?
            var err: String?
            do { res = try MailDB.search(c) } catch { err = error.localizedDescription }
            await MainActor.run {
                guard let self, gen == self.generation else { return }
                self.isSearching = false
                if let res {
                    self.results = res.hits
                    self.truncated = res.truncated
                    self.errorMessage = nil
                } else {
                    self.results = []
                    self.errorMessage = err
                }
            }
        }
    }

    // MARK: Indexation

    func startIndexing() {
        guard !indexing else { return }
        indexing = true
        Task.detached(priority: .utility) { [weak self] in
            BodyIndexer.run { done, total in
                Task { @MainActor in
                    self?.indexed = done
                    self?.total = total
                }
            }
            await MainActor.run { self?.indexing = false }
        }
    }

    // MARK: Boîtes

    func loadMailboxes() {
        let names = Self.accountNames()
        Task.detached { [weak self] in
            var list: [MailboxInfo] = []
            var err: String?
            do { list = try MailDB.mailboxes() } catch { err = error.localizedDescription }
            await MainActor.run {
                guard let self else { return }
                if let err { self.errorMessage = err; self.errorSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"; return }
                self.mailboxes = list.map { mb in
                    var m = mb
                    let acc = MailDB.accountID(of: mb.url)
                    let name = names[acc.uppercased()] ?? String(acc.prefix(6))
                    m.label = "\(name) · \(MailDB.folderName(mb.url))"
                    return m
                }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            }
        }
    }

    /// Renvoie l'ID de la boîte actuellement sélectionnée dans Mail.
    func activeMailboxID() -> Int64? {
        let src = """
        tell application "Mail"
            set mbs to selected mailboxes of front message viewer
            set mb to item 1 of mbs
            return (id of account of mb) & "|" & (name of mb)
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue else {
            let code = (err?[NSAppleScript.errorNumber] as? Int) ?? 0
            let detail = (err?[NSAppleScript.errorMessage] as? String) ?? ""
            if code == -1743 {
                errorMessage = "Contrôle de Mail refusé : autorisez l'app dans Réglages Système › Confidentialité et sécurité › Automatisation."
                errorSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            } else {
                errorMessage = "Boîte active introuvable (Mail est-il ouvert avec une boîte non unifiée sélectionnée ?) \(detail)"
                errorSettingsURL = nil
            }
            return nil
        }
        errorMessage = nil
        let parts = out.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let match = mailboxes.first {
            MailDB.accountID(of: $0.url).caseInsensitiveCompare(parts[0]) == .orderedSame
                && ($0.url.split(separator: "/").last.map { String($0).removingPercentEncoding ?? String($0) } ?? "")
                    .caseInsensitiveCompare(parts[1]) == .orderedSame
        }
        if match == nil { errorSettingsURL = nil; errorMessage = "La boîte « \(parts[1]) » n'a pas été trouvée dans la base de Mail." }
        return match?.id
    }

    private static func accountNames() -> [String: String] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty else { return [:] }
        let src = """
        tell application "Mail"
            set out to ""
            repeat with a in accounts
                set out to out & (id of a) & "=" & (name of a) & linefeed
            end repeat
            return out
        end tell
        """
        var err: NSDictionary?
        guard let s = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue else { return [:] }
        var m: [String: String] = [:]
        for l in s.split(separator: "\n") {
            let kv = l.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { m[String(kv[0]).uppercased()] = String(kv[1]) }
        }
        return m
    }
}
