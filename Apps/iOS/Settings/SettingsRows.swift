import PhiceCore
import SwiftUI

/// A settings section as the mockup draws it: a small uppercase heading over hairline rows.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(Palette.mute)
                .padding(.bottom, 5)
            content
        }
    }
}

struct SettingRow<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            value.foregroundStyle(Palette.mute)
        }
        .font(.system(size: 17))
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title) { Toggle(title, isOn: $isOn).labelsHidden().tint(Palette.on) }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        SettingRow(title: title) {
            Slider(value: $value, in: range).frame(width: 150).tint(Palette.ink)
                .accessibilityLabel(title)
        }
    }
}

/// A choice shown as its short name on the right, picked from a menu.
struct ChoiceRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        SettingRow(title: title) {
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].1).tag(options[$0].0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Palette.mute)
        }
    }
}

/// The trackpad, in System Settings' own words. Values come from the Mac; changing one overrides it.
struct TrackpadSection: View {
    let model: AppModel

    var body: some View {
        SettingsSection(title: "Trackpad") {
            SliderRow(title: "Tracking speed", value: setting(\.trackingSpeed), range: 0 ... 3)
            ToggleRow(title: "Tap to click", isOn: setting(\.tapToClick))
            SettingRow(title: "Tap to drag") { Text("Always on") }
            ChoiceRow(title: "Dragging style", selection: dragging, options: [
                (0, "Without Drag Lock"), (1, "With Drag Lock"), (2, "Three Finger Drag"),
            ])
            ChoiceRow(title: "Secondary click", selection: setting(\.secondaryClick), options: [
                (.twoFingers, "Two fingers"), (.bottomRight, "Bottom right corner"),
                (.bottomLeft, "Bottom left corner"), (.off, "Off"),
            ])
            ToggleRow(title: "Natural scrolling", isOn: setting(\.naturalScrolling))
            ToggleRow(title: "Scroll with inertia", isOn: setting(\.momentumScroll))
            ToggleRow(title: "Zoom in or out", isOn: setting(\.pinchZoom))
            ToggleRow(title: "Smart zoom", isOn: setting(\.smartZoom))
            ChoiceRow(title: "Swipe between pages", selection: setting(\.swipePages), options: [
                (.twoFingerScroll, "Two fingers"), (.threeFingerSwipe, "Three fingers"),
                (.both, "Two or three"), (.off, "Off"),
            ])
            fingers("Swipe between full-screen apps", \.swipeSpaces)
            fingers("Mission Control", \.missionControl)
            fingers("App Exposé", \.appExpose)
            ToggleRow(title: "Notification Center", isOn: setting(\.notificationCenter))
            ToggleRow(title: "Launchpad", isOn: setting(\.launchpad))
            ToggleRow(title: "Show Desktop", isOn: setting(\.showDesktop))
            Text("Read from your Mac. Change here to override.")
                .font(.system(size: 15))
                .foregroundStyle(Palette.mute)
                .padding(.top, 8)
            if model.isOverridingMac {
                Button("Use my Mac's settings") { model.resetToMac() }
                    .font(.system(size: 15))
                    .tint(Palette.accent)
                    .padding(.top, 4)
            }
        }
    }

    private func setting<T>(_ key: WritableKeyPath<TrackpadSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: key] },
                set: { value in model.override { $0[keyPath: key] = value } })
    }

    private func fingers(_ title: String,
                         _ key: WritableKeyPath<TrackpadSettings, Set<Fingers>>) -> some View {
        ChoiceRow(title: title, selection: setting(key), options: [
            ([.three], "Three fingers"), ([.four], "Four fingers"),
            ([.three, .four], "Three or four"), ([], "Off"),
        ])
    }

    /// macOS's dragging style: drag lock and three-finger drag exclude each other.
    private var dragging: Binding<Int> {
        Binding(get: { model.settings.threeFingerDrag ? 2 : model.settings.dragLock ? 1 : 0 },
                set: { style in
                    model.override {
                        $0.dragLock = style == 1
                        $0.threeFingerDrag = style == 2
                    }
                })
    }
}
