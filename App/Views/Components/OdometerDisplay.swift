//
//  OdometerDisplay.swift
//  ReTripper
//
//  Digital odometer cluster card with numeric formatting.
//

import SwiftUI

struct OdometerDisplay: View {
    let reading: Double
    let unit: DistanceUnit

    private var formattedDigits: String {
        let rounded = Int(reading)
        return String(format: "%06d", rounded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text("ODOMETER")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .tracking(1.2)
                } icon: {
                    Circle()
                        .fill(Theme.apexRed)
                        .frame(width: 6, height: 6)
                }

                Spacer()

                Text(unit.label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            // Odometer Digit Display
            HStack(spacing: 4) {
                ForEach(Array(formattedDigits.enumerated()), id: \.offset) { index, char in
                    Text(String(char))
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(index >= formattedDigits.count - 3 ? Theme.textPrimary : Theme.textTertiary)
                        .frame(minWidth: 26, minHeight: 40)
                        .background(Theme.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Theme.borderSubtle, lineWidth: 0.8)
                        )
                }

                Text(unit.shortLabel)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.apexRed)
                    .padding(.leading, 6)
            }

            if reading == 0 {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                    Text("Odometer starts at 0 until you log fuel, rides, or update in Garage.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
                .padding(.top, 2)
            }
        }
        .darkCard(padding: 16)
    }
}

#Preview {
    ZStack {
        Theme.background.ignoresSafeArea()
        VStack(spacing: 16) {
            OdometerDisplay(reading: 0, unit: .kilometers)
            OdometerDisplay(reading: 1450, unit: .kilometers)
        }
        .padding()
    }
}
