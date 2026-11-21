import SwiftUI

/// The menu bar popover: pin (lock) a device per direction by clicking
/// the pin beside it, and see what the keeper has done recently.
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    /// Above this combined row count, wrap the device list in an explicit-height
    /// `ScrollView` so large studio racks scroll without collapsing `MenuBarExtra`.
    private static let maxUnscrolledRows = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.isPaused {
                pausedBanner
            }

            devicesContainer

            Divider()
            activitySection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            model.refreshOnMenuOpen()
        }
    }

    @ViewBuilder
    private var devicesContainer: some View {
        let totalRows = model.devices(for: .output).count + model.devices(for: .input).count
        if totalRows > Self.maxUnscrolledRows {
            ScrollView {
                devicesStack
            }
            .frame(height: 360)
        } else {
            devicesStack
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var devicesStack: some View {
        VStack(alignment: .leading, spacing: 14) {
            DirectionSection(direction: .output)
            Divider()
            DirectionSection(direction: .input)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: MenuBarSymbol.keeping)
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Audio IO Keeper")
                    .font(.headline)
                Text("Click a device or its pin to lock it in. Blue pin = locked.")
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
                Text(
                    "Pins temporarily unlocked until \(until, format: .dateTime.hour().minute()) — macOS can switch"
                )
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
            Button("Settings…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            }
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
private struct DirectionSection: View {
    @Environment(AppModel.self) private var model
    let direction: AudioDirection

    var body: some View {
        let items = model.devices(for: direction)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(direction.displayName, systemImage: direction.systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            statusLine

            ForEach(items) { device in
                deviceRow(device)
            }

            if items.isEmpty {
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
            Spacer(minLength: 4)
            if status == .waitingForPinnedDevice {
                Button("Unpin") { model.unpinDevice(for: direction) }
                    .buttonStyle(.link)
            } else if status == .conflicted {
                Button("Retry") { model.retryDirection(direction) }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
    }

    private func statusText(_ status: DirectionStatus, pinnedName: String) -> String {
        switch status {
        case .notKeeping, .noPinSelected: "Not locked — click a pin below to lock a device in"
        case .kept: "Locked to “\(pinnedName)”"
        case .restoring: "Restoring “\(pinnedName)”…"
        case .conflicted: "Something keeps switching this — backing off and retrying"
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
        let label = model.displayName(for: device, direction: direction)
        let isPinned = model.pinnedUID(for: direction) == device.uid
        let isLocked = isPinned && model.keepingEnabled(for: direction)
        let isActivelyLocked = isLocked && !model.isPaused
        let isPausedPin = isLocked && model.isPaused
        let isCurrent = model.currentUID(for: direction) == device.uid
        return HStack(spacing: 4) {
            Button {
                model.selectDevice(device, for: direction)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: device.transport.systemImage)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(label)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                        .fontWeight(isActivelyLocked ? .semibold : .regular)
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                            .accessibilityLabel("Current system default")
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Use “\(label)” now and pin it")
            .accessibilityLabel(
                rowAccessibilityLabel(label, active: isActivelyLocked, paused: isPausedPin, current: isCurrent)
            )

            pinButton(
                device, label: label, isPinned: isPinned, isActivelyLocked: isActivelyLocked, isPausedPin: isPausedPin
            )
        }
        .padding(.vertical, 3)
        .padding(.leading, 6)
        .background(rowBackground(active: isActivelyLocked, paused: isPausedPin), in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            if isPausedPin {
                Button {
                    model.selectDevice(device, for: direction)
                } label: {
                    Label("Lock “\(label)” now", systemImage: "pin.fill")
                }
            }
            Button {
                if isLocked { model.unpinDevice(for: direction) } else { model.selectDevice(device, for: direction) }
            } label: {
                Label(
                    isLocked ? "Unpin “\(label)” (unlock)" : "Pin & lock “\(label)”",
                    systemImage: isLocked ? "pin" : "pin.fill"
                )
            }
        }
    }

    private func rowBackground(active: Bool, paused: Bool) -> Color {
        if active { return Color.blue.opacity(0.10) }
        if paused { return Color.orange.opacity(0.08) }
        return Color.clear
    }

    private func rowAccessibilityLabel(_ label: String, active: Bool, paused: Bool, current: Bool) -> String {
        let pinState = active ? ", pinned and locked" : (paused ? ", pinned, temporarily unlocked" : "")
        return "\(label)\(pinState)\(current ? ", in use" : "")"
    }

    private func pinButton(
        _ device: AudioDevice, label: String, isPinned: Bool, isActivelyLocked: Bool, isPausedPin: Bool
    ) -> some View {
        let pinColor: Color = isActivelyLocked ? .blue : (isPausedPin ? .orange : .secondary)
        let helpText: String = if isActivelyLocked {
            "“\(label)” is pinned (locked in). Click to unpin."
        } else if isPausedPin {
            "“\(label)” is pinned but temporarily unlocked. Click to lock now."
        } else {
            "Pin & lock “\(label)” so it stays the \(direction.displayName.lowercased()) in use"
        }
        return Button {
            model.togglePin(device, for: direction)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.body)
                .foregroundStyle(pinColor)
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(helpText)
        .accessibilityLabel(isActivelyLocked ? "Unpin \(label)" : "Pin and lock \(label)")
        .accessibilityValue(isActivelyLocked ? "Pinned" : (isPausedPin ? "Paused" : "Not pinned"))
    }
}
