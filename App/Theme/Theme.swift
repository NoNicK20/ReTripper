//
//  Theme.swift
//  ReTripper
//
//  Locked visual identity: Pure black, Guerrilla 450 Apex Red accents,
//  white primary text, and dark grey secondary surfaces.
//

import SwiftUI

enum Theme {
    // MARK: - Core Palette
    static let background = Color.black
    static let surface = Color(red: 0.08, green: 0.08, blue: 0.10)
    static let surfaceSecondary = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let surfaceElevated = Color(red: 0.18, green: 0.18, blue: 0.20)
    static let border = Color(white: 0.22)
    static let borderSubtle = Color(white: 0.15)

    // MARK: - Apex Red Accent (Inspired by Guerrilla 450 Apex Red)
    static let apexRed = Color(red: 0.90, green: 0.12, blue: 0.16)
    static let apexRedDark = Color(red: 0.65, green: 0.08, blue: 0.11)
    static let apexRedMuted = Color(red: 0.90, green: 0.12, blue: 0.16).opacity(0.18)

    // MARK: - Typography & Monochromatic Text
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.68)
    static let textTertiary = Color(white: 0.44)

    // MARK: - Card Corner Radius
    static let cornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 10
}

struct DarkCardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(Theme.borderSubtle, lineWidth: 1)
            )
    }
}

extension View {
    func darkCard(padding: CGFloat = 16) -> some View {
        modifier(DarkCardModifier(padding: padding))
    }
}
