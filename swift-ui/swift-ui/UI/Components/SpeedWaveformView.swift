import SwiftUI

// MARK: - Speed Waveform

struct SpeedWaveformView: View {
    let data: [Int64]
    let color: Color
    @State private var hoveredIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let peak = max(data.max() ?? 1, 1)
            let count = data.count

            ZStack(alignment: .bottomLeading) {
                linePath(width: w, height: h, peak: peak, count: count)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                fillPath(width: w, height: h, peak: peak, count: count)
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.35), color.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                if let idx = hoveredIndex, count > 0 {
                    let point = pointAt(index: idx, width: w, height: h, peak: peak, count: count)
                    Path { path in
                        path.move(to: CGPoint(x: point.x, y: 0))
                        path.addLine(to: CGPoint(x: point.x, y: h))
                    }
                    .stroke(.secondary.opacity(0.35), lineWidth: 1)

                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.9), lineWidth: 1.2)
                        )
                        .position(point)

                    infoBubble(index: idx, point: point, width: w, height: h, count: count)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .position(
                            x: w,
                            y: h - CGFloat(data.last ?? 0) / CGFloat(peak) * h
                        )
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredIndex = nearestIndex(x: location.x, width: w, count: count)
                case .ended:
                    hoveredIndex = nil
                }
            }
        }
    }

    private func linePath(width: CGFloat, height: CGFloat, peak: Int64, count: Int) -> Path {
        Path { path in
            guard count > 1 else { return }
            let step = width / CGFloat(count - 1)
            for (i, value) in data.enumerated() {
                let x = CGFloat(i) * step
                let y = height - CGFloat(value) / CGFloat(peak) * height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    private func fillPath(width: CGFloat, height: CGFloat, peak: Int64, count: Int) -> Path {
        Path { path in
            guard count > 1 else { return }
            let step = width / CGFloat(count - 1)
            path.move(to: CGPoint(x: 0, y: height))
            for (i, value) in data.enumerated() {
                let x = CGFloat(i) * step
                let y = height - CGFloat(value) / CGFloat(peak) * height
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: width, y: height))
            path.closeSubpath()
        }
    }

    private func pointAt(index: Int, width: CGFloat, height: CGFloat, peak: Int64, count: Int) -> CGPoint {
        guard count > 1 else {
            return CGPoint(x: width, y: height)
        }
        let clamped = max(0, min(index, count - 1))
        let step = width / CGFloat(count - 1)
        let value = data[clamped]
        let x = CGFloat(clamped) * step
        let y = height - CGFloat(value) / CGFloat(peak) * height
        return CGPoint(x: x, y: y)
    }

    private func nearestIndex(x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1, width > 0 else { return 0 }
        let step = width / CGFloat(count - 1)
        let raw = Int(round(x / step))
        return max(0, min(raw, count - 1))
    }

    private func infoBubble(index: Int, point: CGPoint, width: CGFloat, height: CGFloat, count: Int) -> some View {
        let speed = data[max(0, min(index, data.count - 1))]
        let timeText = sampleTimeText(index: index, count: count)
        let gap: CGFloat = 5
        let bubbleWidth: CGFloat = 88
        let bubbleHeight: CGFloat = 52
        let halfBubble = bubbleWidth / 2
        let preferRight = point.x <= width / 2
        let rawX = preferRight
            ? point.x + gap + halfBubble
            : point.x - gap - halfBubble
        let x = min(max(rawX, halfBubble), max(halfBubble, width - halfBubble))
        let y = 12 + height - bubbleHeight / 2

        return VStack(spacing: 3) {
            Text(timeText)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Text(AppService.formatSpeed(speed))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 8)
        .frame(width: bubbleWidth)
        .background(.white, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.secondary.opacity(0.15), lineWidth: 1)
        )
        .position(x: x, y: y)
    }

    private func sampleTimeText(index: Int, count: Int) -> String {
        let secondsAgo = max(0, count - 1 - index)
        let sampleDate = Date().addingTimeInterval(-TimeInterval(secondsAgo))
        return Self.timeFormatter.string(from: sampleDate)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - String Extension

extension String {
    var strippingEmoji: String {
        unicodeScalars
            .filter { !$0.properties.isEmoji || $0.isASCII }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespaces)
    }
}
