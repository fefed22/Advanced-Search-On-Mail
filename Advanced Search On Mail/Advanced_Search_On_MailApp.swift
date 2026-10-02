//
//  Advanced_Search_On_MailApp.swift
//  Advanced Search On Mail
//
//  Created by Frederic Marie on 02/10/2026.
//

import AppKit
import SwiftUI

@main
struct Advanced_Search_On_MailApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Recherche Mail", systemImage: "magnifyingglass.circle") {
            Button("Rechercher dans Mail…") {
                openWindow(id: "search")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Quitter") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }

        Window("Recherche avancée Mail", id: "search") {
            ContentView()
        }
        .defaultSize(width: 860, height: 640)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
    }
}
