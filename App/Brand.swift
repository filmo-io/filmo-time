import AppKit
import SwiftUI

// MARK: - Brand bits

/// The Filmo symbol: three bars that read as an F (from Resources/filmo-simbolo.svg).
struct FilmoF: Shape {
    func path(in rect: CGRect) -> Path {
        // SVG viewBox spans x 10…90 and y 8…92.
        let s = min(rect.width / 80, rect.height / 84)
        let ox = rect.midX - 40 * s, oy = rect.midY - 42 * s
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + (x - 10) * s, y: oy + (y - 8) * s) }
        var path = Path()
        // Top bar with the rounded corner.
        path.move(to: p(10, 22))
        path.addArc(center: p(24, 22), radius: 14 * s, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: p(90, 8)); path.addLine(to: p(82, 34)); path.addLine(to: p(10, 34)); path.closeSubpath()
        path.move(to: p(10, 37)); path.addLine(to: p(68, 37)); path.addLine(to: p(60, 63)); path.addLine(to: p(10, 63)); path.closeSubpath()
        path.move(to: p(10, 66)); path.addLine(to: p(40, 66)); path.addLine(to: p(32, 92)); path.addLine(to: p(24, 92))
        path.addArc(center: p(24, 78), radius: 14 * s, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// A white filmo-coin with the black Filmo symbol.
struct CoinIcon: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.white, Color(white: 0.88)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(Color(white: 0.55), lineWidth: max(size * 0.06, 0.7))
            Circle().strokeBorder(Color(white: 0.78), lineWidth: max(size * 0.03, 0.5)).padding(size * 0.12)
            FilmoF().fill(hex(0x0B0B0C)).frame(width: size * 0.42, height: size * 0.44).offset(x: size * 0.02)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: size * 0.04, y: size * 0.03)
    }
}


func hex(_ v: UInt32) -> Color {
    Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}
