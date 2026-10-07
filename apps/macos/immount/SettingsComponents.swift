import SwiftUI

/// White SF Symbol on a colored rounded square, like System Settings.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The app icon, as the system renders it (including the Icon Composer glass).
struct AppBadge: View {
    var size: CGFloat = 44

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// An (i) glyph: hover for a tooltip, click for a popover.
struct InfoButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        // The tooltip carries the same text; skipping it keeps Tab on the actual settings.
        .focusable(false)
        .help(text)
        .accessibilityLabel("More information")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}

/// A row title with an optional (i) and subtitle.
struct SettingLabel: View {
    let title: String
    var subtitle: String? = nil
    var info: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                if let info { InfoButton(text: info) }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A bold section title with a regular secondary subtitle.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A row that opens a web page. `Link` would tint the whole row blue.
struct LinkRow: View {
    let title: String
    var subtitle: String? = nil
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(url) } label: {
            HStack {
                SettingLabel(title: title, subtitle: subtitle)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

/// "Just now" for the first few seconds after `date`, then "12 seconds ago", "2 minutes
/// ago" and so on, counting up every second while shown.
struct RelativeTimeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: date, by: 1)) { context in
            Text(Self.describe(date, now: context.date))
                .monospacedDigit()
        }
    }

    static func describe(_ date: Date, now: Date = .now) -> String {
        // Also covers a completion time a moment ahead of this process's clock.
        if now.timeIntervalSince(date) < 5 { return String(localized: "Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

/// Sidebar header: the app and a glance at its connection. Never shows who is signed in.
struct AppIdentityHeader: View {
    let status: ConnectionStatus

    var body: some View {
        HStack(spacing: 10) {
            AppBadge(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Immount").font(.headline)
                HStack(spacing: 5) {
                    StatusDot(color: Color(nsColor: status.color))
                    Text(status.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// An error at the top of a pane, with a close button.
struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }
}
