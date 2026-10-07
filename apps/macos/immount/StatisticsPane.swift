import Charts
import ImmountKit
import SwiftUI

struct StatisticsPane: View {
    let model: AppModel
    let navigator: SettingsNavigator
    let statistics: StatisticsModel

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                SettingLabel(
                    title: "Enable statistics",
                    subtitle: "Measure download activity and check server statistics."
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("Enable statistics", isOn: Binding(
                    get: { model.statisticsEnabled },
                    set: { model.setStatisticsEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
                .accessibilityLabel("Enable statistics")
            }
        } footer: {
            Text("When off, collection stops and your saved download totals are kept.")
                .font(.caption)
        }

        if !model.statisticsEnabled {
            Section {
                StatisticsEmptyState(
                    title: "Statistics are off",
                    message: "Turn on statistics above to see server health and download activity.",
                    badge: "pause.fill"
                )
            }
        } else if model.isConnected {
            connectionSection
            downloadsSection
            librarySection
            storageSection
        } else {
            Section {
                StatisticsEmptyState(
                    title: "No server connected",
                    message: "Connect to Immich to see server statistics and download activity.",
                    badge: "link",
                    connect: { navigator.show(.general) }
                )
            }
        }
    }

    private var connectionTitle: String {
        if case .connected = model.status, let measuredURL = statistics.response?.serverURL {
            return measuredURL == model.profile?.localServerURL ? "Connected locally" : "Connected"
        }
        return model.status.title
    }

    private var connectionSection: some View {
        Section {
            HStack(spacing: 10) {
                StatusDot(color: Color(nsColor: model.status.color))
                VStack(alignment: .leading, spacing: 3) {
                    Text(connectionTitle).fontWeight(.medium)
                    if let url = statistics.response?.serverURL ?? model.activeServerURL {
                        Text(url.host() ?? url.absoluteString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .help(url.absoluteString)
                    }
                }
                Spacer()
                Button {
                    Task { await statistics.refresh() }
                } label: {
                    Label("Refresh Statistics", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .disabled(statistics.isRefreshing)
                .help("Refresh server statistics now.")
            }
            LabeledContent {
                if let response = statistics.response {
                    Text("\(response.milliseconds.formatted(.number.precision(.fractionLength(0)))) ms")
                        .monospacedDigit()
                } else if let error = statistics.responseError {
                    Text("Unavailable").foregroundStyle(.secondary).help(error)
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                SettingLabel(title: "Response time", info: "Time for a small request to reach Immich and return. This includes the network and the server's response time.")
            }
            if let error = statistics.responseError {
                statisticNotice(error)
            }
            if let version = model.serverVersion {
                LabeledContent("Immich version", value: version)
            }
        } header: {
            SectionHeader(title: "Connection")
        } footer: {
            if let updated = statistics.updatedAt {
                Text("Checked \(updated.formatted(date: .omitted, time: .standard)). Updates every 30 seconds while this pane is open.")
                    .font(.caption)
            }
        }
    }

    private var downloadsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Download speed")
                            .foregroundStyle(.secondary)
                            .help("Combined download throughput over the last 3 seconds, including files that just finished.")
                        Text(Self.speed(statistics.downloads.bytesPerSecond))
                            .font(.system(.title, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                    }
                    Spacer()
                    Text(statistics.downloads.activeDownloads == 0 ? "Idle" : "\(statistics.downloads.activeDownloads) active")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                speedChart
                HStack {
                    Text("Last 60 seconds")
                    Spacer()
                    Text("Peak \(Self.speed(statistics.history.map(\.bytesPerSecond).max() ?? 0))")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            LabeledContent("Downloaded on this Mac", value: Self.bytes(statistics.downloads.downloadedBytes))
            LabeledContent("Completed downloads", value: statistics.downloads.completedDownloads.formatted())
            if let speed = statistics.downloads.lastDownloadBytesPerSecond {
                LabeledContent {
                    Text(Self.speed(speed)).monospacedDigit()
                } label: {
                    SettingLabel(
                        title: "Last download average",
                        subtitle: statistics.downloads.lastDownloadAt?.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }
        } header: {
            SectionHeader(title: "Finder Downloads")
        } footer: {
            Text("Measured from originals downloaded through Immount. Open or copy a file in Finder to see activity. Cached files and thumbnails are excluded. Totals start with this version and reset when you disconnect.")
                .font(.caption)
        }
    }

    private var speedChart: some View {
        Chart(statistics.history) { sample in
            AreaMark(
                x: .value("Time", sample.date),
                y: .value("Bytes per second", sample.bytesPerSecond)
            )
            .foregroundStyle(.blue.opacity(0.12))
            LineMark(
                x: .value("Time", sample.date),
                y: .value("Bytes per second", sample.bytesPerSecond)
            )
            .foregroundStyle(.blue)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXScale(domain: chartStart...chartEnd)
        .chartYScale(domain: 0...max(1_000, (statistics.history.map(\.bytesPerSecond).max() ?? 0) * 1.15))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 76)
        .accessibilityLabel("Download speed during the last 60 seconds")
        .accessibilityValue(Self.speed(statistics.downloads.bytesPerSecond))
    }

    private var chartEnd: Date { statistics.history.last?.date ?? .now }
    private var chartStart: Date { chartEnd.addingTimeInterval(-60) }

    private var librarySection: some View {
        Section {
            if let library = statistics.library {
                HStack(spacing: 20) {
                    count("Photos", value: library.images, symbol: "photo")
                    Spacer(minLength: 0)
                    count("Videos", value: library.videos, symbol: "video")
                    Spacer(minLength: 0)
                    count("Total", value: library.total, symbol: "square.stack")
                }
                .padding(.vertical, 6)
            } else if let error = statistics.libraryError {
                statisticNotice(error)
            } else {
                loading("Reading library…")
            }
        } header: {
            SectionHeader(title: "Your Library", subtitle: "Your timeline and archive, excluding the trash.")
        }
    }

    private var storageSection: some View {
        Section {
            if let storage = statistics.storage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(Self.bytes(storage.diskUseRaw)) used")
                        Spacer()
                        Text("\(Self.bytes(storage.diskSizeRaw)) total")
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(Double(max(0, storage.diskUseRaw)), Double(max(1, storage.diskSizeRaw))), total: Double(max(1, storage.diskSizeRaw)))
                        .tint(.blue)
                        .accessibilityLabel("Server disk usage")
                    Text("\(Self.bytes(storage.diskAvailableRaw)) available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if let error = statistics.storageError {
                statisticNotice(error)
            } else {
                loading("Reading storage…")
            }
        } header: {
            SectionHeader(title: "Server Storage", subtitle: "The server's disk, including data outside your library.")
        }
    }

    private func count(_ title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func statisticNotice(_ message: String) -> some View {
        Label(message, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func loading(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
        }
    }

    private static func bytes(_ value: Int64) -> String {
        value <= 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
    }

    private static func speed(_ value: Double) -> String {
        let safe = value.isFinite ? max(0, value) : 0
        if safe < 1_000 { return "\(Int(safe)) B/s" }
        if safe < 1_000_000 { return "\((safe / 1_000).formatted(.number.precision(.fractionLength(1)))) KB/s" }
        return "\((safe / 1_000_000).formatted(.number.precision(.fractionLength(1)))) MB/s"
    }
}

/// An explicitly full-width row keeps the illustration and text centered in a grouped Form.
private struct StatisticsEmptyState: View {
    let title: String
    let message: String
    let badge: String
    var connect: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            illustration
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 300)

            if let connect {
                Button("Go to General", action: connect)
                    .controlSize(.regular)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(.blue.opacity(0.06))
                .frame(width: 88, height: 88)

            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(LinearGradient(
                    colors: [.blue.opacity(0.18), .cyan.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(.blue.opacity(0.18), lineWidth: 1)
                }
                .frame(width: 56, height: 56)

            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.blue.gradient)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: badge)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 26, height: 26)
                .background(.background, in: .circle)
                .overlay { Circle().strokeBorder(.blue.opacity(0.2), lineWidth: 1) }
                .offset(x: -4, y: -4)
        }
        .accessibilityHidden(true)
    }
}
