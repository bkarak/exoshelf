import ExoShelfCore
import SwiftUI

/// Upscaling and display choices, for the shelf-wide defaults and for one game.
struct GraphicsForm: View {
    @Binding var settings: GraphicsSettings

    var body: some View {
        Section {
            Picker("Upscaling", selection: $settings.style) {
                ForEach(UpscaleStyle.Family.allCases, id: \.self) { family in
                    let styles = UpscaleStyle.allCases.filter { $0.family == family }
                    if !styles.isEmpty {
                        Section(family.rawValue) {
                            ForEach(styles) { Text($0.title).tag($0) }
                        }
                    }
                }
            }
            Text(settings.style.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section("Picture") {
            Picker("Aspect ratio", selection: $settings.aspect) {
                ForEach(AspectMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("Integer scaling", selection: $settings.integerScaling) {
                ForEach(IntegerScaling.allCases) { Text($0.title).tag($0) }
            }
            Picker("Window size", selection: $settings.windowSize) {
                ForEach(WindowSize.allCases) { Text($0.title).tag($0) }
            }
        }

        Section {
            LabeledContent("Dedithering") {
                HStack {
                    Slider(value: Binding(get: { Double(settings.dedithering) }, set: { settings.dedithering = Int($0.rounded()) }),
                           in: 0...100, step: 10)
                        .frame(maxWidth: 180)
                    Text(settings.dedithering == 0 ? "Off" : "\(settings.dedithering)%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
            Picker("Deinterlacing", selection: $settings.deinterlacing) {
                ForEach(Deinterlacing.allCases) { Text($0.title).tag($0) }
            }
            Picker("Colour profile", selection: $settings.colorProfile) {
                ForEach(ColorProfile.allCases) { Text($0.title).tag($0) }
            }
            Picker("CGA palette", selection: $settings.cgaPalette) {
                ForEach(CGAPalette.allCases) { Text($0.title).tag($0) }
            }
            Picker("Monochrome monitor", selection: $settings.monochromePalette) {
                ForEach(MonochromePalette.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Retro display")
        } footer: {
            Text("Dedithering blends the checkerboard patterns CGA and EGA games used for extra colours into solid shades. Deinterlacing fills in the black lines of interlaced video scenes. The CGA palette and monochrome monitor apply only to games in those modes.")
                .footnoteStyle()
        }

        Section {
            Picker("Scale factor", selection: $settings.scaleFactor) {
                Text("2×").tag(2)
                Text("3×").tag(3)
                Text("4×").tag(4)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("ScummVM")
        } footer: {
            Text("ScummVM games use ScummVM's own scalers: Edge for xBR, AdvMAME for Scale3x, HQ for AdvInterp, TV for the CRT styles. Each caps the factor at what it supports.")
                .footnoteStyle()
        }
    }
}

/// Settings → Graphics: the defaults every game starts with.
struct GraphicsSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            GraphicsForm(settings: $model.preferences.graphics)
            Section {
                HStack {
                    Text("Games can have their own settings: Graphics… in a game's detail view.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { model.preferences.graphics = GraphicsSettings() }
                        .disabled(model.preferences.graphics == GraphicsSettings())
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }
}

/// Graphics settings for one game, replacing the defaults while it is on.
struct GameGraphicsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var custom = false
    @State private var settings = GraphicsSettings()
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Use its own graphics settings", isOn: $custom)
                } header: {
                    Text(game.title).font(.headline)
                } footer: {
                    if !custom {
                        Text("Uses the defaults from Settings → Graphics: \(model.preferences.graphics.style.title).")
                            .footnoteStyle()
                    }
                }
                if custom {
                    GraphicsForm(settings: $settings)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if model.running.contains(game.id) {
                    Text("Takes effect the next time the game starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    Task {
                        await model.setGraphicsOverride(custom ? settings : nil, for: game)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!loaded)
            }
            .padding(14)
        }
        .frame(width: 500, height: custom ? 680 : 220)
        .task {
            if let own = await model.graphicsOverride(for: game) {
                settings = own
                custom = true
            } else {
                settings = model.preferences.graphics
            }
            loaded = true
        }
    }
}

extension View {
    /// Section footers read left to right like the rows above them.
    func footnoteStyle() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
