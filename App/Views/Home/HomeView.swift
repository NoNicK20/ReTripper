//
//  HomeView.swift
//  ReTripper
//
//  Main dashboard screen with branding, motorcycle profile, odometer,
//  Tripper Dash connectivity, quick action logging, and recent activity.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var dataManager: DataManager
    @EnvironmentObject private var connectionManager: DashboardConnectionManager
    @EnvironmentObject private var appEnv: AppEnvironment

    @State private var showingFuelSheet = false
    @State private var showingServiceSheet = false
    @State private var showingRideSheet = false
    @State private var showingConnectSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Branding Header
                        BrandHeader()

                        // Tripper Dash Connectivity Banner (Phase 2 P0)
                        TripperDashStatusCard(onTap: { showingConnectSheet = true })

                        // Motorcycle Profile Card
                        MotorcycleCard(motorcycle: dataManager.motorcycle)

                        // Odometer Digital Cluster
                        OdometerDisplay(
                            reading: dataManager.motorcycle.currentOdometer,
                            unit: dataManager.distanceUnit
                        )

                        // Connected Ride Cockpit Hero Launcher
                        Button(action: { appEnv.selectedTab = AppEnvironment.rideTab }) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Theme.apexRed)
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "location.north.fill")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(Theme.textPrimary)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("START CONNECTED RIDE")
                                        .font(.system(size: 13, weight: .black, design: .monospaced))
                                        .foregroundColor(Theme.textPrimary)
                                        .tracking(1.0)
                                    Text("Map, Turn-by-Turn, Trip Meter, Compass & Music")
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.textSecondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Theme.apexRed)
                            }
                            .padding(12)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                                    .stroke(Theme.apexRed, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)

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
            .sheet(isPresented: $showingConnectSheet) {
                DashboardConnectSheet()
            }
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

struct TripperDashStatusCard: View {
    @EnvironmentObject private var connectionManager: DashboardConnectionManager
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.surfaceSecondary)
                        .frame(width: 40, height: 40)
                    Image(systemName: "gauge.open.with.lines.needle.33percent")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(connectionManager.state.isAssociated ? Theme.apexRed : Theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("TRIPPER DASH")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.textTertiary)
                            .tracking(1.2)

                        StatusIndicator(state: connectionManager.state)
                    }

                    Text(connectionManager.state.displayTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                }

                Spacer()

                HStack(spacing: 4) {
                    Text(connectionManager.state.isAssociated ? "Manage" : "Pair")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.apexRed)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.apexRed)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.surfaceSecondary)
                .clipShape(Capsule())
            }
            .darkCard(padding: 12)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HomeView()
        .environmentObject(DataManager.shared)
        .environmentObject(DashboardConnectionManager.shared)
        .environmentObject(RideSessionManager.shared)
        .environmentObject(AppEnvironment.shared)
}
