//
//  ContentView.swift
//  ReTripper
//
//  Main content view - Welcome screen for the app.
//

import SwiftUI

/// Main content view - the welcome screen.
struct ContentView: View {
    @EnvironmentObject private var appEnv: AppEnvironment

    var body: some View {
        ZStack(alignment: .center) {
            // Dark background with subtle gradient
            LinearGradient(
                colors: [Color.black, Color(uiColor: .darkGray)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 48) {
                // App logo placeholder (simple geometric design inspired by motorcycle themes)
                GeometryReader { geometry in
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(
                                width: min(geometry.size.width * 0.15, geometry.size.height * 0.15),
                                height: min(geometry.size.width * 0.15, geometry.size.height * 0.15)
                            )

                        // Inner circle for depth effect
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(
                                width: min(geometry.size.width * 0.1, geometry.size.height * 0.1),
                                height: min(geometry.size.width * 0.1, geometry.size.height * 0.1)
                            )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .aspectRatio(1, contentMode: .fit)

                // App title
                Text("ReTripper")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .shadow(color: Color.red.opacity(0.3), radius: 8, x: 0, y: 4)

                // Subtitle
                Text("Your motorcycle.\nYour journeys.")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)

                // Welcome message
                Text("Welcome to ReTripper")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.top, 16)
            }

            // Bottom progress indicator
            VStack(spacing: 24) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)

                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)

                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }

                Text("Getting ready for your journey")
                    .font(.caption)
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppEnvironment.shared)
}
