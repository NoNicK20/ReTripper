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
    @StateObject private var connectionManager = DashboardConnectionManager.shared
    @StateObject private var rideSession = RideSessionManager.shared
    @StateObject private var appEnv = AppEnvironment.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        GoogleNavigationController.shared.configureAtLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataManager)
                .environmentObject(connectionManager)
                .environmentObject(rideSession)
                .environmentObject(appEnv)
                .onOpenURL { url in
                    // Destinations shared into ReTripper, e.g. retripper://navigate?lat=..&lon=..&name=..
                    if let destination = DestinationLinkParser.parse(url.absoluteString) {
                        rideSession.navigation.setDestination(destination)
                        appEnv.selectedTab = AppEnvironment.rideTab
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { rideSession.appWillResignActive() }
        }
    }
}

/// Application environment for global state management.
@MainActor
class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()
    static let rideTab = 1

    @Published var isLaunched = true
    @Published var selectedTab: Int = 0

    private init() {}
}
