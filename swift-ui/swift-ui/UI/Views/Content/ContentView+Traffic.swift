import SwiftUI

extension ContentView {

    // MARK: - Traffic

    var trafficView: some View {
        HStack(spacing: 12) {
            trafficPanel(
                label: "下行",
                icon: "arrow.down",
                speed: backend.downloadSpeed,
                total: backend.totalDownload,
                history: backend.downloadSpeedHistory,
                color: Color(red: 0.25, green: 0.78, blue: 0.76)
            )
            trafficPanel(
                label: "上行",
                icon: "arrow.up",
                speed: backend.uploadSpeed,
                total: backend.totalUpload,
                history: backend.uploadSpeedHistory,
                color: Color(red: 1.0, green: 0.45, blue: 0.2)
            )
        }
    }

    func trafficPanel(
        label: String,
        icon: String,
        speed: Int64,
        total: Int64,
        history: [Int64],
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("累计 \(AppService.formatBytes(total))")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                Spacer(minLength: 8)
                Text(AppService.formatSpeed(speed))
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(color)
            }
            SpeedWaveformView(data: history, color: color)
                .frame(height: 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
