//
//  ContentView.swift
//  ReTripper
//
//  Main application container hosting the primary tab navigation.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var dataManager: DataManager

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            MainTabView()
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environmentObject(DataManager.shared)
        .environmentObject(AppEnvironment.shared)
}
