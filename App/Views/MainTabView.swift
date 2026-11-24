//
//  MainTabView.swift
//  ReTripper
//
//  Bottom navigation bar hosting Home, Garage, Rides, and Settings.
//

import SwiftUI

@MainActor
struct MainTabView: View {
    @State private var selectedTab: Int = 0

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
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(0)

            GarageView()
                .tabItem {
                    Label("Garage", systemImage: "motorcycle.fill")
                }
                .tag(1)

            RidesView()
                .tabItem {
                    Label("Rides", systemImage: "flag.checkered")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .tint(Theme.apexRed)
    }
}

#Preview {
    MainTabView()
        .environmentObject(DataManager.shared)
        .environmentObject(DashboardConnectionManager.shared)
}
