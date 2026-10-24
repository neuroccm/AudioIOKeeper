import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Locked devices") {
                LabeledContent("Output pinned to", value: model.pinnedName(for: .output) ?? "Nothing (not locked)")
                LabeledContent("Input pinned to", value: model.pinnedName(for: .input) ?? "Nothing (not locked)")
                Text("A pinned device is locked in as the one being used: if macOS "
                     + "switches away on its own (AirPods taken out, a nearby iPhone "
                     + "offering itself as a mic…), Audio IO Keeper switches straight "
                     + "back. To pin or unpin, use the pin beside each device in the "
                     + "menu-bar popover — blue pin means locked. Click the blue pin "
                     + "again to unlock.")
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
                Text("“Temporarily unlock” means: for the next \(Int(AppModel.defaultPauseDuration / 60)) minutes "
                     + "macOS may switch devices freely and nothing is switched back — "
                     + "handy for one call on AirPods. When the time is up, your pins "
                     + "lock again automatically and are restored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Devices") {
                Button("Rescan connected devices") { model.rescanDevices() }
                Text("Use after moving between docks or hubs if a previously "
                     + "connected device does not show up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            }

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
                Text("Audio IO Keeper only reads and writes the standard system default "
                     + "input/output device settings — the same ones in System Settings → "
                     + "Sound. It uses no private APIs, installs no drivers or extensions, "
                     + "and never records or plays audio. If another app or automation "
                     + "keeps switching a device back, restores back off gradually and "
                     + "the popover shows the conflict instead of fighting it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

}

private extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
