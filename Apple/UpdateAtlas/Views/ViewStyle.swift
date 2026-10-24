import AppKit
import SwiftUI

private struct AdaptiveGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
        #else
        content.background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        #endif
    }
}

private struct AdaptiveGlassProminentButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
        #else
        content.buttonStyle(.borderedProminent)
        #endif
    }
}

extension View {
    func adaptiveGlassPanel(cornerRadius: CGFloat = 16) -> some View {
        modifier(AdaptiveGlassPanelModifier(cornerRadius: cornerRadius))
    }

    func adaptiveGlassProminentButtonStyle() -> some View {
        modifier(AdaptiveGlassProminentButtonModifier())
    }
}

extension UpdateSupportStatus {
    var color: Color {
        switch self {
        case .supported: .green
        case .managedExternally: .blue
        case .needsCatalog: .orange
        case .unsupported: .orange
        case .checkFailed: .red
        }
    }
}

extension UpdateAvailability {
    var color: Color {
        switch self {
        case .notChecked: .secondary
        case .checking: .blue
        case .upToDate: .green
        case .updateAvailable: .blue
        case .checkFailed: .orange
        case .sourcePending: .orange
        case .managedExternally: .blue
        case .managedBySystem: .blue
        }
    }
}

extension EvidenceLevel {
    var color: Color {
        switch self {
        case .confirmed: .green
        case .informational: .blue
        case .warning: .orange
        }
    }
}

extension ReleaseChannel {
    var color: Color {
        switch kind {
        case .stable: .secondary
        case .lts: .green
        case .releaseCandidate: .indigo
        case .beta: .purple
        case .alpha: .orange
        case .canary: .pink
        case .nightly: .blue
        case .custom: .secondary
        }
    }
}

struct BetaFeatureBadge: View {
    var body: some View {
        Text(String(localized: "Beta", bundle: AppL10n.bundle, locale: AppL10n.locale).uppercased(with: AppL10n.locale))
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

struct ChannelBadge: View {
    let channel: ReleaseChannel
    var compact = false

    var body: some View {
        Text(channel.title)
            .font(.system(size: compact ? 8 : 9, weight: .semibold, design: .rounded))
            .foregroundStyle(channel.color)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 2 : 3)
            .background(channel.color.opacity(0.13), in: Capsule())
            .overlay {
                Capsule().stroke(channel.color.opacity(0.24), lineWidth: 0.5)
            }
            .fixedSize()
            .accessibilityLabel(String(localized: "Release channel:", bundle: AppL10n.bundle, locale: AppL10n.locale) + " \(channel.title)")
    }
}

struct ApplicationIcon: View {
    let application: InstalledApplication
    var size: CGFloat = 34

    var body: some View {
        Group {
            if application.kind == .extension {
                sfSymbolIcon
            } else if let icon = ApplicationIconImage.installedImage(for: application) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                sfSymbolIcon
            }
        }
        .frame(width: size, height: size)
    }

    private var sfSymbolIcon: some View {
        Image(systemName: application.kind.symbolName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .padding(size * 0.18)
            .foregroundStyle(application.kind == .commandLineTool ? .blue : .secondary)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.22))
    }
}


struct StatusLabel: View {
    let status: UpdateSupportStatus

    var body: some View {
        Label(status.title, systemImage: status.symbolName)
            .font(.callout)
            .foregroundStyle(status.color)
            .lineLimit(1)
    }
}

struct UpdateAvailabilityLabel: View {
    let result: UpdateCheckResult

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(result.availability.title, systemImage: result.availability.symbolName)
                .font(.callout)
                .foregroundStyle(result.availability.color)
                .lineLimit(1)
            if result.availability == .updateAvailable,
               let latestVersion = result.latestVersion {
                HStack(spacing: 5) {
                    Text(
                        (result.source == .steamManifest
                            ? String(localized: "Target Steam build:", bundle: AppL10n.bundle, locale: AppL10n.locale) : String(localized: "Latest:", bundle: AppL10n.bundle, locale: AppL10n.locale))
                        + " \(latestVersion)"
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let releaseChannel = result.releaseChannel {
                        ChannelBadge(channel: releaseChannel, compact: true)
                    }
                }
            }
        }
    }
}

/// Resolve the same local icon for hosted rows and native menu items.
@MainActor
enum ApplicationIconImage {
    static func installedImage(for application: InstalledApplication) -> NSImage? {
        guard application.kind != .extension else { return nil }
        if let path = application.iconPath, let image = NSImage(contentsOfFile: path) { return image }
        guard application.path.hasSuffix(".app") || application.path.hasSuffix(".utm"),
              [.application, .game, .virtualMachine].contains(application.kind),
              FileManager.default.fileExists(atPath: application.path) else { return nil }
        return NSWorkspace.shared.icon(forFile: application.path)
    }

    static func menuImage(for application: InstalledApplication) -> NSImage? {
        // Copy before resizing: Workspace may share a cached image with the main list.
        let installed = installedImage(for: application)
        let image = (installed ?? NSImage(systemSymbolName: application.kind.symbolName,
            accessibilityDescription: application.kind.title))?.copy() as? NSImage
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = installed == nil
        return image
    }

    static func menuTitle(for application: InstalledApplication, text: String) -> NSAttributedString {
        guard let icon = menuImage(for: application) else { return NSAttributedString(string: text) }
        let attachment = NSTextAttachment()
        attachment.image = icon
        attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
        let title = NSMutableAttributedString(attachment: attachment)
        title.append(NSAttributedString(string: "  " + text))
        return title
    }
}
