import ImmountKit
import SwiftUI

struct CacheSection: View {
    let model: AppModel
    @State private var confirmClear = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            LabeledContent {
                Text(sizeLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } label: {
                SettingLabel(title: "Downloaded files", subtitle: countLabel,
                             info: "Original files downloaded through Immount and still stored on this Mac. The estimate uses file sizes; actual disk space can differ. Thumbnails and library information are not included.")
            }
            HStack {
                if model.activity == .clearingCache {
                    ProgressView().controlSize(.small)
                    Text("Clearing cache…").foregroundStyle(.secondary)
                } else if let confirmation = model.cacheConfirmation, model.cacheError == nil {
                    Label(confirmation.title, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .help(confirmation.detail)
                        .accessibilityLabel(confirmation.detail)
                        .transition(.opacity)
                } else if model.isCheckingCache {
                    ProgressView().controlSize(.small)
                    Text("Checking cache…").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refreshCacheUsage() }
                } label: {
                    Label("Refresh Cache Size", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help("Check how many downloaded files are still cached on this Mac.")
                .disabled(!model.isConnected || model.isBusy || model.isCheckingCache)

                Button("Clear Cache…") { confirmClear = true }
                    .disabled(!canClear)
                    .confirmationDialog("Clear cached downloads?", isPresented: $confirmClear) {
                        Button("Clear Cache", role: .destructive) {
                            Task { await model.clearCachedFiles() }
                        }
                    } message: {
                        Text("Remove downloaded copies from this Mac. Your originals stay on Immich and files download again when opened. Files that are in use or kept downloaded may remain.")
                    }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.cacheConfirmation?.id)
            if let error = model.cacheError {
                ErrorBanner(message: error) { model.dismissCacheError() }
                    .font(.callout)
            }
        } header: {
            SectionHeader(title: "Cache", subtitle: "Downloaded originals kept on this Mac.")
        } footer: {
            if model.isConnected {
                Text("Clearing the cache removes local copies. Files download again when you open them.")
                    .font(.caption)
            } else {
                Text("Connect to your server to see and clear downloaded files.")
                    .font(.caption)
            }
        }
    }

    private var canClear: Bool {
        model.isConnected && !model.isBusy && !model.isCheckingCache && (model.cacheUsage?.fileCount ?? 0) > 0
    }

    private var countLabel: String? {
        guard model.isConnected, let usage = model.cacheUsage else { return nil }
        let count = usage.fileCount == 1 ? "1 cached file" : "\(usage.fileCount.formatted()) cached files"
        if usage.unknownSizeCount > 0 {
            return "\(count); some file sizes are unavailable."
        }
        return count
    }

    private var sizeLabel: String {
        guard model.isConnected else { return "Not connected" }
        guard let usage = model.cacheUsage else { return model.isCheckingCache ? "Calculating…" : "Unavailable" }
        if usage.fileCount == 0 { return "0 B" }
        if usage.unknownSizeCount == usage.fileCount { return "Size unavailable" }
        let size = usage.totalBytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .decimal)
        return usage.unknownSizeCount > 0 ? "At least \(size)" : "About \(size)"
    }
}
