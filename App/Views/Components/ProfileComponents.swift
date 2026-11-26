//
//  ProfileComponents.swift
//  ReTripper
//
//  Small shared presentation pieces used across screens.
//

import SwiftUI

/// A compact labelled statistic tile (used on Mileage and summaries).
struct StatBox: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundColor(Theme.textPrimary)
            Text(caption)
                .font(.system(size: 10))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A labelled single-line text field used across the logging forms.
struct FormField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .foregroundColor(Theme.textPrimary)
                .padding(12)
                .background(Theme.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.borderSubtle, lineWidth: 1)
                )
        }
    }
}
