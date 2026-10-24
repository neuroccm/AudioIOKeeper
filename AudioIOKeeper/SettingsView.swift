import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Keeping") {
                Toggle("Keep output device fixed", isOn: keepingBinding(.output))
                Toggle("Keep input device fixed", isOn: keepingBinding(.input))
                Text("When keeping is on, Audio IO Keeper restores your pinned device "
                     + "whenever macOS switches the default on its own — for example when "
                     + "AirPods are taken out or a nearby iPhone offers itself as a mic.")
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

    private func keepingBinding(_ direction: AudioDirection) -> Binding<Bool> {
        Binding(
            get: { model.keepingEnabled(for: direction) },
            set: { model.setKeepingEnabled($0, for: direction) }
        )
    }
}

private extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
