//
//  keynotepptxApp.swift
//  keynotepptx
//
//  Created by Sean Laidlaw on 15/04/2026.
//

import SwiftUI

@main
struct keynotepptxApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
