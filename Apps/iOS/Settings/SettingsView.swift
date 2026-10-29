import PhiceCore
import SwiftUI

/// Settings, over the pad: the trackpad in one column, everything else in the other.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var forgetting = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                let columns = proxy.size.width > 600 ? 2 : 1
                Grid(alignment: .topLeading, horizontalSpacing: 40) {
                    if columns == 2 {
                        GridRow {
                            TrackpadSection(model: model)
                            others
                        }
                    } else {
                        TrackpadSection(model: model)
                        others
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Spacer()
                Button("Done") { model.showSettings = false }
                    .font(.system(size: 17, weight: .semibold))
                    .tint(Palette.accent)
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
        }
        .background(Color.black)
        .presentationBackground(Color.black)
        .preferredColorScheme(.dark)
        .onChange(of: model.appearance) { model.saveLook() }
        .onChange(of: model.dropAction) { model.saveLook() }
        .confirmationDialog("Forget \(model.macName ?? "this Mac")?", isPresented: $forgetting,
                            titleVisibility: .visible) {
            Button("Forget", role: .destructive, action: forget)
        } message: {
            Text("You will need to pair again from the Mac's Phice window.")
        }
    }

    private var others: some View {
        VStack(alignment: .leading, spacing: 28) {
            appearance
            dropped
            mac
            SettingsSection(title: "Debug") {
                ToggleRow(title: "Record session", isOn: $model.recording)
            }
        }
    }

    private var appearance: some View {
        SettingsSection(title: "Appearance") {
            ToggleRow(title: "Touch glow", isOn: $model.appearance.glow)
            SettingRow(title: "Glow colour") {
                HStack(spacing: 12) {
                    ForEach(GlowColor.allCases, id: \.self) { colour in
                        Button { model.appearance.glowColor = colour } label: {
                            Circle().fill(colour.swatch)
                                .frame(width: 22, height: 22)
                                .padding(3)
                                .overlay(Circle().strokeBorder(model.appearance.glowColor == colour
                                    ? Palette.accent : .clear, lineWidth: 2))
                        }
                        .accessibilityLabel(colour.name)
                        .accessibilityAddTraits(model.appearance.glowColor == colour ? .isSelected : [])
                    }
                }
            }
            SliderRow(title: "Glow intensity", value: $model.appearance.glowIntensity, range: 0.3 ... 1)
            SliderRow(title: "Border brightness", value: $model.appearance.borderBrightness,
                      range: 0.2 ... 1)
        }
    }

    private var dropped: some View {
        SettingsSection(title: "Dropped into the pill") {
            choice("Copy", .copy)
            choice("Cut", .cut)
            SettingRow(title: "Run a Shortcut") {
                Menu {
                    ForEach(model.shortcuts, id: \.self) { name in
                        Button(name) { model.dropAction = .shortcut(name: name) }
                    }
                } label: {
                    if case let .shortcut(name) = model.dropAction {
                        Label(name, systemImage: "checkmark").foregroundStyle(Palette.accent)
                    } else {
                        Text(model.shortcuts.isEmpty ? "None on your Mac" : "Choose…")
                    }
                }
                .disabled(model.shortcuts.isEmpty)
            }
        }
    }

    private func choice(_ title: String, _ action: DropAction) -> some View {
        Button { model.dropAction = action } label: {
            SettingRow(title: title) {
                if model.dropAction == action {
                    Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.dropAction == action ? .isSelected : [])
    }

    private var mac: some View {
        SettingsSection(title: "Mac") {
            SettingRow(title: model.macName ?? "No Mac") {
                Text(model.linkState.isConnected ? "Connected" : "Not connected")
                    .foregroundStyle(model.linkState.isConnected ? Palette.on : Palette.mute)
            }
            SettingRow(title: "Accessibility") {
                Text(model.accessibility ? "Granted" : "Not granted")
                    .foregroundStyle(model.accessibility ? Palette.on : Palette.off)
            }
            Button { forgetting = true } label: {
                SettingRow(title: "Forget this Mac") { EmptyView() }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func forget() {
        model.link.forget()
        UserDefaults.standard.set(false, forKey: "onboarded")
        model.showSettings = false
        model.showOnboarding = true
    }
}

extension GlowColor {
    /// What each preset looks like on the swatch. The pad draws the glow itself.
    var swatch: Color {
        switch self {
        case .warmWhite: Color(red: 1, green: 0.965, blue: 0.902)
        case .coolWhite: Color(red: 0.918, green: 0.953, blue: 1)
        case .blue: Color(red: 0.561, green: 0.776, blue: 1)
        case .green: Color(red: 0.6, green: 0.94, blue: 0.7)
        }
    }

    var name: String {
        switch self {
        case .warmWhite: "Warm white"
        case .coolWhite: "Cool white"
        case .blue: "Blue"
        case .green: "Green"
        }
    }
}
