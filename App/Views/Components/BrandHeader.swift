//
//  BrandHeader.swift
//  ReTripper
//
//  Premium brand header with monochromatic text and Apex Red accent.
//

import SwiftUI

struct BrandHeader: View {
    var subtitle: String = "ROYAL ENFIELD GUERRILLA 450"

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("RE")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundColor(Theme.apexRed)
                    Text("TRIPPER")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                }

                Text(subtitle)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .tracking(1.5)
            }

            Spacer()

            // Apex Red Badge
            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.apexRed)
                    .frame(width: 8, height: 8)
                Text("APEX RED")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surfaceElevated)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Theme.apexRed.opacity(0.4), lineWidth: 1)
            )
        }
    }
}

#Preview {
    ZStack {
        Theme.background.ignoresSafeArea()
        BrandHeader()
            .padding()
    }
}
