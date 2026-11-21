import ContainerKit
import Foundation
import SwiftUI

enum Format {
    static func bytes<T: BinaryInteger>(_ value: T?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }

    static func percent(_ fractionOfCore: Double?) -> String {
        guard let fractionOfCore else { return "—" }
        return (fractionOfCore * 100).formatted(.number.precision(.fractionLength(fractionOfCore < 0.1 ? 1 : 0))) + "%"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.relative(presentation: .named))
    }

    static func uptime(since date: Date?) -> String {
        guard let date else { return "—" }
        let interval = max(0, Date().timeIntervalSince(date))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval < 3600 ? [.minute, .second] : [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? "—"
    }

    static func shortDigest(_ digest: String) -> String {
        let hex = digest.split(separator: ":").last.map(String.init) ?? digest
        return String(hex.prefix(12))
    }

    /// Drop the implicit `docker.io/library/` so common images read like users type them.
    static func friendlyImage(_ reference: String) -> String {
        for prefix in ["docker.io/library/", "docker.io/"] where reference.hasPrefix(prefix) {
            return String(reference.dropFirst(prefix.count))
        }
        return reference
    }
}

extension ContainerState {
    var label: String {
        switch self {
        case .running: "Running"
        case .stopped: "Stopped"
        case .stopping: "Stopping"
        case .unknown: "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .stopping: .orange
        case .stopped: .secondary
        case .unknown: .yellow
        }
    }
}

struct StateBadge: View {
    let state: ContainerState

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state.tint).frame(width: 7, height: 7)
            Text(state.label)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// Empty-state view used across lists.
struct EmptyStateView<Actions: View>: View {
    let title: String
    let symbol: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            actions
        }
    }
}
