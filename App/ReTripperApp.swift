//
//  ReTripperApp.swift
//  ReTripper
//
//  A premium motorcycle companion application for iOS.
//  Your motorcycle. Your journeys.
//

import SwiftUI

@main
@MainActor
struct ReTripperApp: App {
    @StateObject private var dataManager = DataManager.shared
    @StateObject private var appEnv = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataManager)
                .environmentObject(appEnv)
        }
    }
}

/// Application environment for global state management.
class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()

    @Published var isLaunched = true

    private init() {}
}
