//
//  ReTripperApp.swift
//  ReTripper
//
//  A premium motorcycle companion application for iOS.
//  Your motorcycle. Your journeys.
//

import SwiftUI

@main
struct ReTripperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppEnvironment.shared)
        }
    }
}

/// Application environment for global state management.
class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()

    @Published var isLaunched = false

    private init() {}
}
