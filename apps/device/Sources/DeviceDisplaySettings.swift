import SwiftUI
import UIKit
import ScreenpunkCore
import ScreenpunkApple

/// Device preferences are independent of cloud accounts and screen packages.
@MainActor
final class DeviceDisplayPreferences: ObservableObject {
    @Published private(set) var settings: DeviceBrightnessSettings
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let key = "screenpunk.device.brightness.v1"
    private let controller = DeviceBrightnessController()
    private var settingsBrightness: CGFloat?
    private var readabilityBrightness: CGFloat?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let value = try? JSONDecoder().decode(DeviceBrightnessSettings.self, from: data),
           (try? value.validate()) != nil {
            settings = value
        } else { settings = .init() }
        controller.update(settings: settings)
    }

    @discardableResult func save(_ value: DeviceBrightnessSettings) -> Bool {
        do {
            try value.validate()
            defaults.set(try JSONEncoder().encode(value), forKey: key)
            settings = value
            controller.update(settings: value)
            error = nil
            return true
        } catch {
            self.error = "Use unique schedule times and add at least one time."
            return false
        }
    }

    func setActive(_ active: Bool, settingsPresented: Bool) {
        // Release the screen override before making settings readable. Capture only
        // our temporary readability adjustment, never change system Auto-Brightness.
        if active && settingsPresented {
            controller.setActive(false)
            if settingsBrightness == nil {
                settingsBrightness = UIScreen.main.brightness
                let readable = max(UIScreen.main.brightness, 0.35)
                readabilityBrightness = readable
                UIScreen.main.brightness = readable
            }
        } else {
            if let previous = settingsBrightness {
                // Keep a manual Control Center change made while settings were open.
                if let requested = readabilityBrightness, abs(UIScreen.main.brightness - requested) < 0.005 {
                    UIScreen.main.brightness = previous
                }
                settingsBrightness = nil
                readabilityBrightness = nil
            }
            controller.setActive(active)
        }
    }
}

struct DeviceDisplaySettings: View {
    @ObservedObject var preferences: DeviceDisplayPreferences
    @State private var draft = DeviceBrightnessSettings()
    @State private var saved = false

    var body: some View {
        Form {
            Section("Brightness") {
                Picker("Control", selection: $draft.mode) {
                    Text("System").tag(DeviceBrightnessMode.system)
                    Text("Fixed level").tag(DeviceBrightnessMode.fixed)
                    Text("Time of day").tag(DeviceBrightnessMode.schedule)
                }
                if draft.mode == .fixed { levelSlider($draft.fixedLevel) }
                if draft.mode == .schedule {
                    ForEach(draft.schedule.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                DatePicker("From", selection: timeBinding(index), displayedComponents: .hourAndMinute)
                                Button(role: .destructive) { draft.schedule.remove(at: index) } label: {
                                    Image(systemName: "minus.circle")
                                }.accessibilityLabel("Remove brightness time")
                            }
                            levelSlider(levelBinding(index))
                        }.padding(.vertical, 4)
                    }
                    Button {
                        let used = Set(draft.schedule.map(\.minuteOfDay))
                        if let minute = stride(from: 0, to: 1440, by: 30).first(where: { !used.contains($0) }) {
                            draft.schedule.append(.init(minuteOfDay: minute, level: 0.5))
                        }
                    } label: { Label("Add time", systemImage: "plus") }
                    .disabled(draft.schedule.count >= 48)
                    Text("The most recent time stays in effect overnight. Times follow this device’s local time zone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text(draft.mode == .system
                     ? "Uses the device’s brightness and Auto-Brightness settings, including manual changes in Control Center."
                     : "Applies while Screenpunk is active and restores your previous brightness when you leave. Scheduling cannot wake, lock, or turn off the iPad.")
                Text("Settings remain readable while you edit. Saved brightness takes effect when you close settings.")
            }.font(.footnote).foregroundStyle(.secondary)
            Section {
                Button("Save display settings") { saved = preferences.save(draft) }
                    .disabled((try? draft.validate()) == nil)
                if saved { Text("Saved").foregroundStyle(.secondary) }
                if let error = preferences.error { Text(error).foregroundStyle(.red) }
                if draft.mode == .schedule && (try? draft.validate()) == nil {
                    Text("Add at least one time and keep each time unique.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Display")
        .onAppear { draft = preferences.settings }
        .onChange(of: draft) { _ in saved = false }
    }

    private func levelSlider(_ value: Binding<Double>) -> some View {
        HStack {
            Slider(value: value, in: 0...1) { Text("Brightness") }
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit().frame(minWidth: 44, alignment: .trailing)
        }
    }
    private func timeBinding(_ index: Int) -> Binding<Date> {
        Binding(get: {
            let minute = draft.schedule.indices.contains(index) ? draft.schedule[index].minuteOfDay : 0
            return Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: minute / 60, minute: minute % 60)) ?? Date()
        }, set: { date in
            guard draft.schedule.indices.contains(index) else { return }
            let time = Calendar.current.dateComponents([.hour, .minute], from: date)
            draft.schedule[index].minuteOfDay = (time.hour ?? 0) * 60 + (time.minute ?? 0)
        })
    }
    private func levelBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { draft.schedule.indices.contains(index) ? draft.schedule[index].level : 0.5 },
                set: { value in if draft.schedule.indices.contains(index) { draft.schedule[index].level = value } })
    }
}
