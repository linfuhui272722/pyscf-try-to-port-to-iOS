// PySCFApp.swift
//
// Application entry point.  Boots the embedded interpreter during launch and
// shows a blocking splash until the engine reports its capabilities.

import SwiftUI

@main
struct PySCFApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.bootstrap() }
        }
    }
}
