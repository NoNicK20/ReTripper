//
//  MainTabView.swift
//  ReTripper
//
//  Bottom navigation bar hosting Home, Garage, Rides, and Settings.
//

import SwiftUI

@MainActor
struct MainTabView: View {
    @EnvironmentObject private var appEnv: AppEnvironment

    init() {
        // Configure standard tab bar appearance for dark theme
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        
        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.normal.iconColor = UIColor(white: 0.5, alpha: 1.0)
        itemAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(white: 0.5, alpha: 1.0)
        ]
        itemAppearance.selected.iconColor = UIColor(red: 0.90, green: 0.12, blue: 0.16, alpha: 1.0)
        itemAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor(red: 0.90, green: 0.12, blue: 0.16, alpha: 1.0)
        ]
        
        appearance.stackedLayoutAppearance = itemAppearance
        appearance.inlineLayoutAppearance = itemAppearance
        appearance.compactInlineLayoutAppearance = itemAppearance
        
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $appEnv.selectedTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)

            RideModeView()
                .tabItem {
                    Label("Ride", systemImage: "location.north.circle.fill")
                }
                .tag(1)

            GarageView()
                .tabItem {
                    Label("Garage", systemImage: "motorcycle.fill")
                }
                .tag(2)

            RidesView()
                .tabItem {
                    Label("Rides", systemImage: "flag.checkered")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(4)
        }
        .tint(Theme.apexRed)
    }
}

#Preview {
    MainTabView()
        .environmentObject(DataManager.shared)
        .environmentObject(DashboardConnectionManager.shared)
        .environmentObject(RideSessionManager.shared)
        .environmentObject(AppEnvironment.shared)
}
