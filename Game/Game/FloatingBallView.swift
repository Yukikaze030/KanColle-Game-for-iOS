import SwiftUI

struct FloatingBallView: View {
    let isExpanded: Bool
    let onTap: () -> Void

    private let diameter: CGFloat = 56
    @State private var center: CGPoint?
    @State private var dragOrigin: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let safeRect = availableRect(in: geometry)
            Button(action: onTap) {
                Image(systemName: isExpanded ? "xmark" : "ship.wheel.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: diameter, height: diameter)
                    .background(.black.opacity(0.78), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .position(clamped(center ?? initialCenter(in: safeRect), to: safeRect))
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("floatingBall"))
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = center ?? initialCenter(in: safeRect)
                        }
                        guard let dragOrigin else { return }
                        center = clamped(
                            CGPoint(x: dragOrigin.x + value.translation.width,
                                    y: dragOrigin.y + value.translation.height),
                            to: safeRect
                        )
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        guard var settled = center else { return }
                        settled.x = settled.x < safeRect.midX ? safeRect.minX : safeRect.maxX
                        center = clamped(settled, to: safeRect)
                    }
            )
            .onChange(of: geometry.size) { _, _ in
                if let center { self.center = clamped(center, to: safeRect) }
            }
            .onChange(of: geometry.safeAreaInsets) { _, _ in
                if let center { self.center = clamped(center, to: safeRect) }
            }
        }
        .coordinateSpace(name: "floatingBall")
    }

    private func availableRect(in geometry: GeometryProxy) -> CGRect {
        let radius = diameter / 2
        return CGRect(
            x: geometry.safeAreaInsets.leading + radius + 8,
            y: geometry.safeAreaInsets.top + radius + 8,
            width: max(0, geometry.size.width - geometry.safeAreaInsets.leading
                       - geometry.safeAreaInsets.trailing - diameter - 16),
            height: max(0, geometry.size.height - geometry.safeAreaInsets.top
                        - geometry.safeAreaInsets.bottom - diameter - 16)
        )
    }

    private func initialCenter(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.maxX, y: rect.midY)
    }

    private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX),
                y: min(max(point.y, rect.minY), rect.maxY))
    }
}
