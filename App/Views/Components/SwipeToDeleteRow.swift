//
//  SwipeToDeleteRow.swift
//  ReTripper
//
//  A lightweight swipe-to-delete wrapper for cards shown in a plain ScrollView
//  (where SwiftUI's List-only `.onDelete` / `.swipeActions` aren't available).
//  Swipe a row to the left to reveal a red Delete button; tapping it runs the
//  supplied delete action. The wrapped content keeps its own tap behaviour.
//

import SwiftUI

struct SwipeToDeleteRow<Content: View>: View {
    var cornerRadius: CGFloat = Theme.smallCornerRadius
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    private let revealWidth: CGFloat = 88

    var body: some View {
        ZStack(alignment: .trailing) {
            // Red delete layer sits behind the card and is uncovered on swipe.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.apexRed)
                .overlay(alignment: .trailing) {
                    Button(action: performDelete) {
                        VStack(spacing: 3) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 16, weight: .bold))
                            Text("Delete")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(width: revealWidth)
                        .frame(maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete")
                }

            content()
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            let t = value.translation.width
                            if t < 0 {
                                offset = max(t, -revealWidth)
                            } else {
                                // Allow dragging the row back closed.
                                offset = min(0, -revealWidth + t)
                            }
                        }
                        .onEnded { _ in
                            withAnimation(.easeOut(duration: 0.2)) {
                                offset = offset < -revealWidth / 2 ? -revealWidth : 0
                            }
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func performDelete() {
        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
        onDelete()
    }
}
