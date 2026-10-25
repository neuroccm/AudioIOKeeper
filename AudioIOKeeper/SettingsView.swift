import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    // Reads of pins / temporary-unlock state go through AppModel accessors
    // that track settingsRevision, so this window refreshes on changes.
    var body: some View {
        Form {
            lockedDevicesSection
            devicesSection
            startupSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private var lockedDevicesSection: some View {
        Section("Locked devices") {
            pinnedRow(.output)
            pinnedRow(.input)
            Text(pinHelpText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.isPaused, let until = model.pausedUntil {
                LabeledContent(
                    "Pins temporarily unlocked until",
                    value: until.formatted(date: .omitted, time: .shortened)
                )
                Button("Lock pins now") { model.resumeKeeping() }
            } else {
                Button("Temporarily unlock pins for \(Int(AppModel.defaultPauseDuration / 60)) minutes") {
                    model.pauseKeeping()
                }
            }
            Text(temporaryUnlockHelpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var devicesSection: some View {
        Section("Devices") {
            Button("Rescan connected devices") { model.rescanDevices() }
            Text("Use after moving between docks or hubs if a previously "
                 + "connected device does not show up.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var startupSection: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: launchAtLoginBinding)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio IO Keeper")
                        .font(.headline)
                    Text("Keeps your chosen audio input & output devices exactly "
                         + "where you put them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Version", value: Bundle.main.shortVersion)
            LabeledContent("License", value: "MIT")
            if let home = URL(string: "https://github.com/neuroccm/AudioIOKeeper") {
                Link("Audio IO Keeper on GitHub", destination: home)
            }
            Text(safetyText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })
    }

    /// One direction's stored pin, with a permanent Unpin. Needed because a
    /// disconnected pinned device has no popover row (or pin button) to
    /// unpin from, while its stored pin would otherwise be unremovable
    /// until the device returns.
    @ViewBuilder
    private func pinnedRow(_ direction: AudioDirection) -> some View {
        let label = "\(direction.displayName) pinned to"
        if let name = model.pinnedName(for: direction) {
            HStack {
                Text(label)
                Spacer()
                Text(name)
                    .foregroundStyle(.secondary)
                Button("Unpin") { model.unpinDevice(for: direction) }
                    .accessibilityLabel("Unpin \(direction.displayName) \(name)")
            }
        } else {
            LabeledContent(label, value: "Nothing (not locked)")
        }
    }

    private var pinHelpText: String {
        "A pinned device is locked in as the one being used: if macOS "
            + "switches away on its own (AirPods taken out, a nearby iPhone "
            + "offering itself as a mic…), Audio IO Keeper switches straight "
            + "back. To pin or unpin, use the pin beside each device in the "
            + "menu-bar popover — blue pin means locked, click it again to "
            + "unlock. Unpin above also works while a pinned device is "
            + "disconnected, when its popover row is hidden."
    }

    private var temporaryUnlockHelpText: String {
        "“Temporarily unlock” means: for the next \(Int(AppModel.defaultPauseDuration / 60)) minutes "
            + "macOS may switch devices freely and nothing is switched back — "
            + "handy for one call on AirPods. When the time is up, your pins "
            + "lock again automatically and are restored."
    }

    private var safetyText: String {
        "Audio IO Keeper only reads and writes the standard system default "
            + "input/output device settings — the same ones in System Settings → "
            + "Sound. It uses no private APIs, installs no drivers or extensions, "
            + "and never records or plays audio. If another app or automation "
            + "keeps switching a device back, restores back off gradually and "
            + "the popover shows the conflict instead of fighting it."
    }
}

private extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
