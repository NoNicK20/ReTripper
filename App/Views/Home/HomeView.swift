//
//  HomeView.swift
//  ReTripper
//
//  Main dashboard screen with branding, motorcycle profile, odometer,
//  quick action logging, and recent activity.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var dataManager: DataManager

    @State private var showingFuelSheet = false
    @State private var showingServiceSheet = false
    @State private var showingRideSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Branding Header
                        BrandHeader()

                        // Motorcycle Profile Card
                        MotorcycleCard(motorcycle: dataManager.motorcycle)

                        // Odometer Digital Cluster
                        OdometerDisplay(
                            reading: dataManager.motorcycle.currentOdometer,
                            unit: dataManager.distanceUnit
                        )

                        // Quick Actions Bar
                        QuickActionButtons(
                            onFuelTap: { showingFuelSheet = true },
                            onServiceTap: { showingServiceSheet = true },
                            onRideTap: { showingRideSheet = true }
                        )

                        // Recent Activity Feed
                        RecentActivityList(activities: dataManager.recentActivities)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingFuelSheet) {
                AddFuelSheet()
            }
            .sheet(isPresented: $showingServiceSheet) {
                AddServiceSheet()
            }
            .sheet(isPresented: $showingRideSheet) {
                AddRideSheet()
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(DataManager.shared)
}
