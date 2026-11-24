//
//  MotorcycleCard.swift
//  ReTripper
//
//  Sporty profile card showcasing the Royal Enfield Guerrilla 450 Apex Red.
//

import SwiftUI

struct MotorcycleCard: View {
    let motorcycle: Motorcycle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top Row: Model title & Status
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(motorcycle.make.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .tracking(1.2)

                    Text(motorcycle.model)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.textPrimary)

                    HStack(spacing: 8) {
                        Text(motorcycle.edition)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Theme.apexRed)

                        Text("•")
                            .foregroundColor(Theme.textTertiary)

                        Text(String(motorcycle.year))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                    }
                }

                Spacer()

                // Stylized Graphic Icon Badge
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.surfaceSecondary)
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.borderSubtle, lineWidth: 1)
                        )

                    // Sporty Dual-Circle Wheel & Frame Motif
                    HStack(spacing: 4) {
                        Circle()
                            .stroke(Theme.apexRed, lineWidth: 2.5)
                            .frame(width: 16, height: 16)
                        Rectangle()
                            .fill(Theme.textPrimary)
                            .frame(width: 8, height: 2)
                        Circle()
                            .stroke(Theme.textPrimary, lineWidth: 2.5)
                            .frame(width: 16, height: 16)
                    }
                }
            }

            // Divider line with Apex Red accent
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Theme.apexRed, Theme.surfaceSecondary],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1.5)

            // Technical Specs Row
            HStack(spacing: 8) {
                SpecPill(title: "ENGINE", value: "452cc")
                SpecPill(title: "POWER", value: "40 PS")
                SpecPill(title: "TORQUE", value: "40 Nm")
                if !motorcycle.registrationNumber.isEmpty {
                    SpecPill(title: "PLATE", value: motorcycle.registrationNumber)
                }
            }
        }
        .darkCard(padding: 18)
    }
}

struct SpecPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview {
    ZStack {
        Theme.background.ignoresSafeArea()
        MotorcycleCard(motorcycle: Motorcycle.defaultGuerrilla)
            .padding()
    }
}
