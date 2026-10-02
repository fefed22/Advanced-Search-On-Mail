//
//  ContentView.swift
//  Advanced Search On Mail
//
//  Created by Frederic Marie on 02/10/2026.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var engine = MailSearchEngine()
    @State private var criteria = SearchCriteria()
    @State private var selection = Set<Int64>()

    var body: some View {
        VStack(spacing: 0) {
            form
                .padding(12)
            if let err = engine.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption)
                    Spacer()
                    if let s = engine.errorSettingsURL, let url = URL(string: s) {
                        Button("Réglages…") { NSWorkspace.shared.open(url) }
                    }
                    Button("OK") { engine.errorMessage = nil }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            resultsTable
            Divider()
            HStack {
                if engine.isSearching { ProgressView().controlSize(.small) }
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(minWidth: 720, minHeight: 540)
        .background(WindowFloater())
        .task { engine.start() }
        .task(id: criteria) {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            engine.search(criteria)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Rechercher dans vos emails…", text: $criteria.text)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .onSubmit { engine.search(criteria) }

            HStack(spacing: 14) {
                Text("Chercher dans :").foregroundStyle(.secondary)
                Toggle("Objet", isOn: $criteria.inSubject)
                Toggle("Corps", isOn: $criteria.inBody)
                Toggle("Expéditeur", isOn: $criteria.inSender)
                Toggle("Destinataires", isOn: $criteria.inRecipients)
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 14) {
                Toggle("Depuis le", isOn: $criteria.useFrom)
                    .toggleStyle(.checkbox)
                DatePicker("", selection: $criteria.from, displayedComponents: .date)
                    .labelsHidden().disabled(!criteria.useFrom)
                Toggle("Jusqu'au", isOn: $criteria.useTo)
                    .toggleStyle(.checkbox)
                DatePicker("", selection: $criteria.to, displayedComponents: .date)
                    .labelsHidden().disabled(!criteria.useTo)
                Picker("", selection: $criteria.attachment) {
                    ForEach(AttachmentFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 170)
            }

            HStack(spacing: 10) {
                Text("Boîte :").foregroundStyle(.secondary)
                Picker("", selection: $criteria.mailboxID) {
                    Text("Toutes les boîtes").tag(Int64?.none)
                    ForEach(engine.mailboxes) { mb in
                        Text("\(mb.label) (\(mb.count))").tag(Int64?.some(mb.id))
                    }
                }
                .labelsHidden().frame(maxWidth: 360)
                Button {
                    if let id = engine.activeMailboxID() { criteria.mailboxID = id }
                } label: {
                    Label("Boîte active de Mail", systemImage: "tray")
                }
            }
        }
    }

    private var resultsTable: some View {
        Table(engine.results, selection: $selection) {
            TableColumn("Date") { hit in
                Text(hit.date?.formatted(date: .abbreviated, time: .shortened) ?? "")
            }
            .width(min: 110, ideal: 130)
            TableColumn("Expéditeur", value: \.sender).width(min: 100, ideal: 170)
            TableColumn("Objet", value: \.subject)
            TableColumn("Dossier", value: \.mailbox).width(min: 60, ideal: 110)
        }
        .contextMenu(forSelectionType: Int64.self) { _ in
        } primaryAction: { ids in
            // Double-clic : ouvre dans Mail, la fenêtre reste ouverte.
            for id in ids {
                if let err = MailOpener.open(rowid: id) {
                    engine.errorSettingsURL = nil
                    engine.errorMessage = err
                }
            }
        }
    }

    private var statusText: String {
        if criteria.isEmpty { return "Saisissez un terme ou un filtre." }
        let n = engine.results.count
        let suffix = engine.truncated ? " (limité aux \(MailSearchEngine.maxResults) plus récents)" : ""
        var idx = ""
        if engine.indexing && engine.total > 0 {
            idx = " — indexation du contenu : \(engine.indexed)/\(engine.total)"
        }
        return "\(n) résultat\(n > 1 ? "s" : "")\(suffix)\(idx)"
    }
}

/// Garde la fenêtre au-dessus de Mail pour continuer la recherche.
struct WindowFloater: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.level = .floating }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

#Preview {
    ContentView()
}
