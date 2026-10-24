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

            Section("Startup") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.shortVersion)
                Text("Audio IO Keeper only reads and writes the standard system default "
                     + "input/output device settings — the same ones in System Settings → "
                     + "Sound. It uses no private APIs, installs no drivers or extensions, "
                     + "and never records or plays audio.")
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
