import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    private static let unlockedSelectionTag = "__unlocked__"

    var body: some View {
        Form {
            lockedDevicesSection
            devicesSection
            startupSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            model.refreshOnMenuOpen()
            model.refreshLoginItemStatus()
        }
    }

    private var lockedDevicesSection: some View {
        Section("Locked devices") {
            pinnedRow(.output)
            pinnedRow(.input)
            Toggle("Also lock system sound effects to output", isOn: lockSystemOutputBinding)
            Text("Keeps macOS alert sounds and dictation chimes on your locked output device when supported.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .disabled(!model.isKeepingAnything)
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
            if model.loginItemNeedsApproval {
                HStack {
                    Text("Requires approval in System Settings → General → Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Login Items…") { model.openLoginItemsSettings() }
                        .controlSize(.small)
                }
            }
            if let error = model.loginItemError {
                Text("Could not update login item: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
        Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })
    }

    private var lockSystemOutputBinding: Binding<Bool> {
        Binding(get: { model.lockSystemOutput }, set: { model.setLockSystemOutput($0) })
    }

    private func pinPickerBinding(for direction: AudioDirection) -> Binding<String> {
        Binding(
            get: {
                guard model.keepingEnabled(for: direction), let uid = model.pinnedUID(for: direction) else {
                    return Self.unlockedSelectionTag
                }
                return uid
            },
            set: { newTag in
                if newTag == Self.unlockedSelectionTag {
                    model.unpinDevice(for: direction)
                } else if let device = model.devices(for: direction).first(where: { $0.uid == newTag }) {
                    model.selectDevice(device, for: direction)
                }
            }
        )
    }

    @ViewBuilder
    private func pinnedRow(_ direction: AudioDirection) -> some View {
        let available = model.devices(for: direction)
        let pinnedUID = model.pinnedUID(for: direction)
        let isLocked = pinnedUID != nil && model.keepingEnabled(for: direction)
        let isDisconnectedPin = pinnedUID != nil && !available.contains { $0.uid == pinnedUID }
        HStack {
            Picker("\(direction.displayName) lock", selection: pinPickerBinding(for: direction)) {
                Text("Not locked (macOS switches freely)")
                    .tag(Self.unlockedSelectionTag)
                if !available.isEmpty || isDisconnectedPin {
                    Divider()
                }
                if isDisconnectedPin, let uid = pinnedUID {
                    let stored = model.pinnedName(for: direction) ?? uid
                    Text("\(stored) (disconnected)")
                        .tag(uid)
                }
                ForEach(available) { device in
                    let label = model.displayName(for: device, direction: direction)
                    let currentSuffix = model.currentUID(for: direction) == device.uid ? " — in use" : ""
                    Text("\(label)\(currentSuffix)")
                        .tag(device.uid)
                }
            }
            if isLocked || pinnedUID != nil {
                Button("Unpin") { model.unpinDevice(for: direction) }
                    .controlSize(.small)
                    .accessibilityLabel("Unpin \(direction.displayName)")
            }
        }
    }

    private var pinHelpText: String {
        "Choose a device above or click its pin in the menu-bar popover to "
            + "lock it in: if macOS switches away on its own (AirPods taken out, "
            + "a nearby iPhone offering itself as a mic…), Audio IO Keeper "
            + "switches straight back."
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
