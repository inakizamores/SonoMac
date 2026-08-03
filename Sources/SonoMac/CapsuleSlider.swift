import SwiftUI

/// Control-Center-style volume slider: capsule track, white fill,
/// glyph riding inside the leading cap. Tap the glyph to mute,
/// drag or click anywhere to set the level.
struct CapsuleSlider: View {
    @Binding var value: Double            // 0...100
    var height: CGFloat = 22
    var icon: String? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onIconTap: (() -> Void)? = nil

    @State private var isDragging = false
    @State private var startedOnIcon = false
    @State private var moved = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let frac = CGFloat(min(max(value / 100, 0), 1))
            let fillWidth = height + frac * (width - height)

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.white)
                    .frame(width: fillWidth)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: height * 0.5, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: height, height: height)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging {
                            isDragging = true
                            moved = false
                            startedOnIcon = icon != nil && onIconTap != nil
                                && g.startLocation.x < height
                            onEditingChanged(true)
                        }
                        if abs(g.translation.width) > 2 || abs(g.translation.height) > 2 {
                            moved = true
                        }
                        if !startedOnIcon || moved {
                            let f = min(max((g.location.x - height / 2) / (width - height), 0), 1)
                            value = Double(f) * 100
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                        if startedOnIcon && !moved { onIconTap?() }
                        startedOnIcon = false
                    }
            )
        }
        .frame(height: height)
    }
}
