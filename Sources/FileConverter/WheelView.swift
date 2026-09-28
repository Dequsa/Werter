import SwiftUI

/// Shared by drawing (SwiftUI) and hit testing (AppKit) so they always agree.
/// Coordinates are y-down; angles grow clockwise, 0 = pointing right.
struct WheelGeometry {
    static let diameter: CGFloat = 300
    static let canvas: CGFloat = 340

    let count = ImageFormat.allCases.count
    let outerRadius: CGFloat = 141
    let innerRadius: CGFloat = 66
    let centerRadius: CGFloat = 56

    var span: Double { 2 * .pi / Double(count) }

    /// Wedge 0 is centred on the top.
    func startAngle(of index: Int) -> Angle { .radians(-.pi / 2 - span / 2 + span * Double(index)) }
    func endAngle(of index: Int) -> Angle { .radians(startAngle(of: index).radians + span) }
    func midAngle(of index: Int) -> Angle { .radians(startAngle(of: index).radians + span / 2) }

    /// Direction decides the wedge, so anything outside the centre counts — even past the rim.
    func index(at point: CGPoint, in bounds: CGRect) -> Int? {
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        guard hypot(dx, dy) > centerRadius + 4 else { return nil }
        var angle = (atan2(dy, dx) - startAngle(of: 0).radians).truncatingRemainder(dividingBy: 2 * .pi)
        if angle < 0 { angle += 2 * .pi }
        return min(Int(angle / span), count - 1)
    }
}

/// A ring segment with rounded corners and a constant-width gap to its neighbours.
struct Wedge: Shape {
    var startAngle: Angle
    var endAngle: Angle
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var gap: CGFloat = 7
    var cornerRadius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        // Build a shape shrunk by the corner radius, then grow it back with a round-joined stroke.
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let inset = gap / 2 + cornerRadius
        let outer = outerRadius - cornerRadius
        let inner = innerRadius + cornerRadius
        let outerInset = asin(min(1, inset / outer))
        let innerInset = asin(min(1, inset / inner))

        var core = Path()
        core.addArc(center: center, radius: outer,
                    startAngle: .radians(startAngle.radians + outerInset),
                    endAngle: .radians(endAngle.radians - outerInset), clockwise: false)
        core.addArc(center: center, radius: inner,
                    startAngle: .radians(endAngle.radians - innerInset),
                    endAngle: .radians(startAngle.radians + innerInset), clockwise: true)
        core.closeSubpath()

        let cgCore = core.cgPath
        let rounding = cgCore.copy(strokingWithWidth: cornerRadius * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return Path(cgCore.union(rounding))
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var colorScheme
    private let geometry = WheelGeometry()

    private var segmentFill: Color { .white.opacity(colorScheme == .dark ? 0.12 : 0.55) }
    private var rimColor: Color { .white.opacity(colorScheme == .dark ? 0.2 : 0.6) }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(rimColor, lineWidth: 1)
                .frame(width: WheelGeometry.diameter, height: WheelGeometry.diameter)

            ForEach(Array(ImageFormat.allCases.enumerated()), id: \.element) { index, format in
                segment(format, index: index)
            }

            center
        }
        .frame(width: WheelGeometry.canvas, height: WheelGeometry.canvas)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: model.hovered)
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }

    private func segment(_ format: ImageFormat, index: Int) -> some View {
        let isHovered = model.hovered == format
        let wedge = Wedge(startAngle: geometry.startAngle(of: index), endAngle: geometry.endAngle(of: index),
                          innerRadius: geometry.innerRadius, outerRadius: geometry.outerRadius)
        let mid = geometry.midAngle(of: index)
        let labelRadius = (geometry.innerRadius + geometry.outerRadius) / 2

        return ZStack {
            wedge.fill(isHovered ? Color.accentColor : segmentFill)
            wedge.stroke(rimColor, lineWidth: 0.5)
            Text(format.label)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(isHovered ? Color.white : Color.primary)
                .offset(x: cos(mid.radians) * labelRadius, y: sin(mid.radians) * labelRadius)
        }
        .opacity(model.disabled.contains(format) ? 0.35 : 1)
        .scaleEffect(isHovered ? 1.05 : 1)
        .shadow(color: .black.opacity(isHovered ? 0.25 : 0), radius: 10, y: 4)
    }

    private var center: some View {
        let size = geometry.centerRadius * 2
        return ZStack {
            Circle().fill(segmentFill)

            if let thumbnail = model.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }

            if model.phase != .choosing {
                Circle().fill(.black.opacity(0.5))
            }

            switch model.phase {
            case .choosing:
                Text(model.hovered.map { "→ \($0.label)" } ?? model.sizeText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            case .converting:
                ProgressView()
                    .controlSize(.small)
                    .environment(\.colorScheme, .dark)
            case .done(let message):
                status("checkmark.circle.fill", message)
            case .failed(let message):
                status("exclamationmark.triangle.fill", message)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(rimColor, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if model.files.count > 1 {
                Text("\(model.files.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Color.accentColor, in: Capsule())
                    .offset(x: 2, y: -2)
            }
        }
    }

    private func status(_ symbol: String, _ message: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 26))
            Text(message)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(8)
    }
}
