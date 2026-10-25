import SwiftUI

/// The menu bar popover: pin (lock) a device per direction by clicking
/// the pin beside it, and see what the keeper has done recently.
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.isPaused {
                pausedBanner
            }

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
            Image(systemName: MenuBarSymbol.keeping)
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Audio IO Keeper")
                    .font(.headline)
                Text("Click the pin beside a device to lock it in. Blue pin = locked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.rescanDevices()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Re-read the connected audio devices (useful after moving between docks or hubs)")
            .accessibilityLabel("Rescan connected devices")
        }
    }

    /// Shown only while a temporary unlock (started in Settings) is active:
    /// the pins stay chosen but are not enforced until the deadline.
    @ViewBuilder
    private var pausedBanner: some View {
        if let until = model.pausedUntil {
            HStack(spacing: 6) {
                Image(systemName: "lock.open.fill")
                    .foregroundStyle(.orange)
                Text("Pins temporarily unlocked until \(until, format: .dateTime.hour().minute()) — macOS can switch freely")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Lock pins now") { model.resumeKeeping() }
                    .controlSize(.small)
                    .accessibilityLabel("Lock pins now")
            }
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
            Button("About…") { showAboutPanel() }
                .buttonStyle(.link)
            Spacer()
            Button("Quit Audio IO Keeper") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
        }
        .font(.callout)
    }

    /// Standard macOS About panel: app icon, name, version, and credits.
    /// A menu-bar-only app has no app menu to host the usual About item,
    /// so the popover footer provides it.
    private func showAboutPanel() {
        let credits = NSAttributedString(
            string: """
            Keeps your chosen audio input & output devices exactly where you put them.

            Audio IO Keeper only reads and writes the standard system default \
            input/output settings — the same ones in System Settings → Sound. \
            No private APIs, drivers, or extensions; it never records or plays audio.

            If something else keeps switching a device back, restores back off \
            gradually and the popover shows the conflict instead of fighting it.

            MIT License — https://github.com/neuroccm/AudioIOKeeper
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor
            ]
        )
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Audio IO Keeper",
            .credits: credits
        ])
    }
}

/// One direction's controls: the current status and the device list.
/// Every device has its own pin button: blue/filled means that device is
/// pinned (locked in as the one being used); grey/outline means it is not.
/// Clicking a grey pin pins and uses that device; clicking the blue pin
/// again unpins it. Right-clicking a row offers the same pin/unpin action.
private struct DirectionSection: View {
    @Environment(AppModel.self) private var model
    let direction: AudioDirection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(direction.displayName, systemImage: direction.systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
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
        case .notKeeping, .noPinSelected: "Not locked — click a pin below to lock a device in"
        case .kept: "Locked to “\(pinnedName)”"
        case .restoring: "Restoring “\(pinnedName)”…"
        case .conflicted: "Something keeps switching this — backing off and retrying periodically"
        case .waitingForPinnedDevice: "“\(pinnedName)” is disconnected — will restore on return"
        case .paused: "Temporarily unlocked — macOS may switch freely"
        }
    }

    private func statusImage(_ status: DirectionStatus) -> String {
        switch status {
        case .notKeeping: "lock.open"
        case .kept: "lock.fill"
        case .restoring: "arrow.triangle.2.circlepath"
        case .conflicted: "exclamationmark.shield.fill"
        case .waitingForPinnedDevice: "exclamationmark.triangle.fill"
        case .noPinSelected: "questionmark.circle"
        case .paused: "pause.circle"
        }
    }

    private func statusColor(_ status: DirectionStatus) -> Color {
        switch status {
        case .kept: .green
        case .conflicted: .red
        case .waitingForPinnedDevice: .orange
        case .restoring: .blue
        case .notKeeping, .noPinSelected, .paused: .secondary
        }
    }

    private func deviceRow(_ device: AudioDevice) -> some View {
        let isPinned = model.pinnedUID(for: direction) == device.uid
        let isLocked = isPinned && model.keepingEnabled(for: direction)
        let isCurrent = model.currentUID(for: direction) == device.uid
        return HStack(spacing: 4) {
            // Clicking the name uses the device now and pins it.
            Button {
                model.selectDevice(device, for: direction)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: device.transport.systemImage)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(device.name)
                        .lineLimit(1)
                        .fontWeight(isLocked ? .semibold : .regular)
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                            .accessibilityLabel("Current system default")
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Use “\(device.name)” now and pin it")
            .accessibilityLabel("\(device.name)\(isLocked ? ", pinned and locked" : "")\(isCurrent ? ", in use" : "")")

            pinButton(device, isPinned: isPinned, isLocked: isLocked)
        }
        .padding(.vertical, 3)
        .padding(.leading, 6)
        .background(
            isLocked ? Color.blue.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contextMenu {
            Button {
                model.togglePin(device, for: direction)
            } label: {
                Label(
                    isLocked ? "Unpin “\(device.name)” (unlock)" : "Pin & lock “\(device.name)”",
                    systemImage: isLocked ? "pin" : "pin.fill"
                )
            }
        }
    }

    /// The lock itself: blue and filled when this device is pinned, grey
    /// and outlined when it is not. Always visible so locking never
    /// depends on discovering a row click.
    private func pinButton(_ device: AudioDevice, isPinned: Bool, isLocked: Bool) -> some View {
        Button {
            model.togglePin(device, for: direction)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.body)
                .foregroundStyle(isLocked ? Color.blue : Color.secondary)
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isLocked
            ? "“\(device.name)” is pinned (locked in). Click to unpin."
            : "Pin & lock “\(device.name)” so it stays the \(direction.displayName.lowercased()) in use")
        .accessibilityLabel(isLocked ? "Unpin \(device.name)" : "Pin and lock \(device.name)")
        .accessibilityValue(isLocked ? "Pinned" : "Not pinned")
    }
}
