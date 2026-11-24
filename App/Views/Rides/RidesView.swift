//
//  RidesView.swift
//  ReTripper
//
//  Rides screen showing ride history, stats, and an empty state
//  with an option to add a manual ride record.
//

import SwiftUI

struct RidesView: View {
    @EnvironmentObject private var dataManager: DataManager
    @State private var showingAddRideSheet = false

    private var totalDistance: Double {
        dataManager.rideLogs.reduce(0) { $0 + $1.distance }
    }

    private var totalDurationMinutes: Int {
        dataManager.rideLogs.reduce(0) { $0 + $1.durationMinutes }
    }

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Header
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("RIDES")
                                    .font(.system(size: 24, weight: .black, design: .rounded))
                                    .foregroundColor(Theme.textPrimary)
                                Text("JOURNEY LOG")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .tracking(1.2)
                            }

                            Spacer()

                            Button(action: { showingAddRideSheet = true }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("Add Ride")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundColor(Theme.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Theme.apexRed)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.top, 8)

                        // Stats Summary Row
                        HStack(spacing: 10) {
                            StatBox(
                                title: "TOTAL DISTANCE",
                                value: String(format: "%.1f %@", totalDistance, dataManager.distanceUnit.shortLabel),
                                caption: "all recorded rides"
                            )

                            StatBox(
                                title: "RIDES",
                                value: String(dataManager.rideLogs.count),
                                caption: "logged journeys"
                            )

                            StatBox(
                                title: "TIME ON SADDLE",
                                value: formatDuration(totalDurationMinutes),
                                caption: "total ride time"
                            )
                        }
                        .darkCard(padding: 14)

                        // Ride List or Empty State
                        if dataManager.rideLogs.isEmpty {
                            // Realistic Empty State
                            VStack(spacing: 16) {
                                ZStack {
                                    Circle()
                                        .fill(Theme.surfaceSecondary)
                                        .frame(width: 64, height: 64)
                                    Image(systemName: "road.lanes")
                                        .font(.system(size: 28, weight: .semibold))
                                        .foregroundColor(Theme.apexRed)
                                }

                                VStack(spacing: 6) {
                                    Text("No rides recorded yet")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(Theme.textPrimary)

                                    Text("Start tracking your journeys on your Guerrilla 450. Log route titles, distances, and saddle time.")
                                        .font(.system(size: 13))
                                        .foregroundColor(Theme.textSecondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 20)
                                }

                                Button(action: { showingAddRideSheet = true }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 14, weight: .bold))
                                        Text("Record First Ride")
                                            .font(.system(size: 14, weight: .bold))
                                    }
                                    .foregroundColor(Theme.textPrimary)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 10)
                                    .background(Theme.apexRed)
                                    .clipShape(Capsule())
                                }
                                .padding(.top, 4)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                            .darkCard(padding: 16)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("LOGGED RIDES")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                                    .tracking(1.2)

                                ForEach(dataManager.rideLogs) { ride in
                                    RideCard(
                                        ride: ride,
                                        unit: dataManager.distanceUnit,
                                        dateString: dateFormatter.string(from: ride.date)
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAddRideSheet) {
                AddRideSheet()
            }
        }
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remaining = minutes % 60
        return remaining > 0 ? "\(hours)h \(remaining)m" : "\(hours)h"
    }
}

struct RideCard: View {
    let ride: RideLog
    let unit: DistanceUnit
    let dateString: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ride.title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Theme.textPrimary)

                    Text(dateString)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f %@", ride.distance, unit.shortLabel))
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.apexRed)

                    if ride.durationMinutes > 0 {
                        Text("\(ride.durationMinutes) min")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }

            if ride.source == "phone-gps" {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        if let moving = ride.movingMinutes {
                            Text("Moving \(moving) min")
                        }
                        if let avg = ride.averageMovingSpeedKmh {
                            Text(String(format: "Avg %.0f km/h", avg))
                        }
                        if let gain = ride.elevationGainMeters {
                            Text(String(format: "+%.0f m", gain))
                        }
                        if let points = ride.route?.count, points > 1 {
                            Text("\(points) GPS pts")
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    Text("PHONE GPS DATA")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
            }

            if !ride.notes.isEmpty {
                Text(ride.notes)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                .stroke(Theme.borderSubtle, lineWidth: 0.8)
        )
    }
}

#Preview {
    RidesView()
        .environmentObject(DataManager.shared)
}
