import SwiftUI

/// A single macOS-style traffic-light button.
struct TrafficButton: View {
    let color: Color
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 15, height: 15)
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color.black.opacity(0.6))
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    static let macClose    = Color(red: 1.00, green: 0.37, blue: 0.34)
    static let macMinimize = Color(red: 0.99, green: 0.74, blue: 0.18)
    static let macMaximize = Color(red: 0.16, green: 0.80, blue: 0.25)
}
