//
//  QuickActionButtons.swift
//  ReTripper
//
//  Quick actions bar for logging Fuel, Service, and Rides.
//

import SwiftUI

struct QuickActionButtons: View {
    let onFuelTap: () -> Void
    let onServiceTap: () -> Void
    let onRideTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUICK ACTIONS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
                .tracking(1.2)

            HStack(spacing: 12) {
                QuickActionButton(
                    title: "Fuel",
                    subtitle: "Refill",
                    systemIcon: "fuelpump.fill",
                    isPrimary: true,
                    action: onFuelTap
                )

                QuickActionButton(
                    title: "Service",
                    subtitle: "Maint.",
                    systemIcon: "wrench.and.screwdriver.fill",
                    isPrimary: false,
                    action: onServiceTap
                )

                QuickActionButton(
                    title: "Ride",
                    subtitle: "Record",
                    systemIcon: "flag.checkered",
                    isPrimary: false,
                    action: onRideTap
                )
            }
        }
    }
}

struct QuickActionButton: View {
    let title: String
    let subtitle: String
    let systemIcon: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: systemIcon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(isPrimary ? Theme.apexRed : Theme.textPrimary)
                    Spacer()
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(14)
            .background(isPrimary ? Theme.surfaceElevated : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(isPrimary ? Theme.apexRed.opacity(0.5) : Theme.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ZStack {
        Theme.background.ignoresSafeArea()
        QuickActionButtons(onFuelTap: {}, onServiceTap: {}, onRideTap: {})
            .padding()
    }
}
