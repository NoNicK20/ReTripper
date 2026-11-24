//
//  RecentActivityList.swift
//  ReTripper
//
//  Feed of recent activity with realistic empty states.
//

import SwiftUI

struct RecentActivityList: View {
    let activities: [ActivityItem]

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RECENT ACTIVITY")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .tracking(1.2)

                Spacer()

                if !activities.isEmpty {
                    Text("\(activities.count) TOTAL")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                }
            }

            if activities.isEmpty {
                // Realistic Empty State
                VStack(spacing: 12) {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textTertiary)

                    VStack(spacing: 4) {
                        Text("No logs recorded yet")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)

                        Text("Use Quick Actions above to log your first fuel fill-up, service maintenance, or manual ride.")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .darkCard(padding: 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(activities.prefix(5)) { item in
                        ActivityRow(item: item, dateString: dateFormatter.string(from: item.date))
                    }
                }
            }
        }
    }
}

struct ActivityRow: View {
    let item: ActivityItem
    let dateString: String

    private var iconName: String {
        switch item.type {
        case .fuel: return "fuelpump.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .ride: return "flag.checkered"
        }
    }

    private var iconColor: Color {
        switch item.type {
        case .fuel, .ride: return Theme.apexRed
        case .maintenance: return Theme.textPrimary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.surfaceSecondary)
                    .frame(width: 38, height: 38)
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                Text("\(dateString) • \(item.subtitle)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer()

            Text(item.value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                .stroke(Theme.borderSubtle, lineWidth: 0.8)
        )
    }
}

#Preview {
    ZStack {
        Theme.background.ignoresSafeArea()
        RecentActivityList(activities: [])
            .padding()
    }
}
