import SwiftUI

/// The menu bar popover: pick the devices to keep, toggle keeping per
/// direction, and see what the keeper has done recently.
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            DirectionSection(direction: .output)
            Divider()
            DirectionSection(direction: .input)
            Divider()
            activitySection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.badge.lock")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Audio IO Keeper")
                    .font(.headline)
                Text("Your chosen input & output stay put.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        if !model.activityLog.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.activityLog.prefix(5)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(entry.message)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { openSettings() }
                .buttonStyle(.link)
            Spacer()
            Button("Quit Audio IO Keeper") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
        }
        .font(.callout)
    }
}

/// One direction's controls: a keeping toggle, the current status, and the
/// list of devices to pin. Selecting a device pins it and makes it the
/// system default immediately.
private struct DirectionSection: View {
    @Environment(AppModel.self) private var model
    let direction: AudioDirection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(direction.displayName, systemImage: direction.systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("Keep", isOn: keepingBinding)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("Keep \(direction.displayName) fixed")
                Text("Keep")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            statusLine

            ForEach(model.devices(for: direction)) { device in
                deviceRow(device)
            }

            if model.devices(for: direction).isEmpty {
                Text("No \(direction.displayName.lowercased()) devices found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var keepingBinding: Binding<Bool> {
        Binding(
            get: { model.keepingEnabled(for: direction) },
            set: { model.setKeepingEnabled($0, for: direction) }
        )
    }

    private var statusLine: some View {
        let status = model.status(for: direction)
        let pinned = model.pinnedName(for: direction) ?? "—"
        return HStack(spacing: 5) {
            Image(systemName: statusImage(status))
                .foregroundStyle(statusColor(status))
            Text(statusText(status, pinnedName: pinned))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func statusText(_ status: DirectionStatus, pinnedName: String) -> String {
        switch status {
        case .notKeeping: "Keeping off — macOS may switch freely"
        case .kept: "Keeping “\(pinnedName)”"
        case .restoring: "Restoring “\(pinnedName)”…"
        case .waitingForPinnedDevice: "“\(pinnedName)” is disconnected — will restore on return"
        case .noPinSelected: "Pick a device below to keep it"
        }
    }

    private func statusImage(_ status: DirectionStatus) -> String {
        switch status {
        case .notKeeping: "lock.open"
        case .kept: "lock.fill"
        case .restoring: "arrow.triangle.2.circlepath"
        case .waitingForPinnedDevice: "exclamationmark.triangle.fill"
        case .noPinSelected: "questionmark.circle"
        }
    }

    private func statusColor(_ status: DirectionStatus) -> Color {
        switch status {
        case .kept: .green
        case .waitingForPinnedDevice: .orange
        case .restoring: .blue
        case .notKeeping, .noPinSelected: .secondary
        }
    }

    private func deviceRow(_ device: AudioDevice) -> some View {
        let isPinned = model.pinnedUID(for: direction) == device.uid
        let isCurrent = model.currentUID(for: direction) == device.uid
        return Button {
            model.selectDevice(device, for: direction)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: device.transport.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(device.name)
                    .lineLimit(1)
                Spacer()
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Pinned")
                }
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                        .accessibilityLabel("Current system default")
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(device.name)\(isPinned ? ", pinned" : "")\(isCurrent ? ", current default" : "")")
    }
}
