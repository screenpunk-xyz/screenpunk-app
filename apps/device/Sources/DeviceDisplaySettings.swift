import SwiftUI
import UIKit
import ScreenpunkCore
import ScreenpunkApple

/// Device preferences are independent of cloud accounts and screen packages.
@MainActor
final class DeviceDisplayPreferences: ObservableObject {
    @Published private(set) var settings: DeviceBrightnessSettings
    private let defaults: UserDefaults
    private let key = "screenpunk.device.brightness.v1"
    private let controller = DeviceBrightnessController()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let value = try? JSONDecoder().decode(DeviceBrightnessSettings.self, from: data),
           (try? value.validate()) != nil {
            settings = value
        } else { settings = .init() }
        controller.update(settings: settings)
    }

    func preview(_ value: DeviceBrightnessSettings) {
        guard (try? value.validate()) != nil else { return }
        controller.update(settings: value)
    }

    func save(_ value: DeviceBrightnessSettings) {
        guard (try? value.validate()) != nil else {
            controller.update(settings: settings)
            return
        }
        if value != settings, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
            settings = value
        }
        controller.update(settings: settings)
    }

    func setActive(_ active: Bool) { controller.setActive(active) }
}

struct DeviceDisplaySettings: View {
    @ObservedObject var preferences: DeviceDisplayPreferences
    @ObservedObject var device: DeviceModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var nameFocused: Bool
    @State private var deviceName = ""
    @State private var nameAccountID: String?
    @State private var draft = DeviceBrightnessSettings()
    @State private var editingLevel = false
    @State private var duplicateTime = false

    var body: some View {
        Form {
            Section {
                TextField("Device name", text: $deviceName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit(finishNameEditing)
                    .disabled(device.accountOperationInProgress)
                    .accessibilityIdentifier("deviceName")
                if deviceName != device.displayName, (try? DeviceNameStore.normalized(deviceName)) == nil {
                    Text("Enter a valid device name.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Device Name")
            }
            Section("Brightness") {
                Picker("Control", selection: Binding(get: { draft.mode }, set: changeMode)) {
                    Text("System").tag(DeviceBrightnessMode.system)
                    Text("Fixed Level").tag(DeviceBrightnessMode.fixed)
                    Text("Time of Day").tag(DeviceBrightnessMode.schedule)
                }
                if draft.mode == .fixed { levelSlider($draft.fixedLevel) }
                if draft.mode == .schedule {
                    ForEach(draft.schedule.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                DatePicker("From", selection: timeBinding(index), displayedComponents: .hourAndMinute)
                                Button(role: .destructive) {
                                    guard draft.schedule.indices.contains(index), draft.schedule.count > 1 else { return }
                                    draft.schedule.remove(at: index)
                                    duplicateTime = false
                                    preferences.save(draft)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .disabled(draft.schedule.count <= 1)
                                .accessibilityLabel("Remove brightness time")
                            }
                            levelSlider(levelBinding(index))
                        }.padding(.vertical, 4)
                    }
                    Button {
                        let used = Set(draft.schedule.map(\.minuteOfDay))
                        if let minute = stride(from: 0, to: 1440, by: 30).first(where: { !used.contains($0) }) {
                            draft.schedule.append(.init(minuteOfDay: minute, level: 0.5))
                            duplicateTime = false
                            preferences.save(draft)
                        }
                    } label: { Label("Add time", systemImage: "plus") }
                    .disabled(draft.schedule.count >= 48)
                    if duplicateTime {
                        Text("Choose a different time for each brightness level.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("General")
        .onAppear {
            draft = preferences.settings
            resetNameEditing()
        }
        .onChange(of: nameFocused) { if !$0 { saveDeviceName() } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            if nameFocused { finishNameEditing() }
        }
        .onChange(of: device.displayName) { if !nameFocused { deviceName = $0 } }
        .onChange(of: device.cloud.localAccountID) { _ in resetNameEditing() }
        .onChange(of: device.accountOperationInProgress) { if $0 { resetNameEditing() } }
        .onChange(of: scenePhase) { if $0 != .active { finishLevelEditing() } }
        .onDisappear {
            saveDeviceName()
            finishLevelEditing()
        }
    }

    private func finishNameEditing() {
        saveDeviceName()
        nameFocused = false
    }

    private func resetNameEditing() {
        nameAccountID = device.cloud.localAccountID
        deviceName = device.displayName
        nameFocused = false
    }

    private func saveDeviceName() {
        guard !device.accountOperationInProgress, nameAccountID == device.cloud.localAccountID,
              let normalized = try? DeviceNameStore.normalized(deviceName) else { return }
        if normalized != device.displayName { device.updateDeviceName(normalized) }
        deviceName = device.displayName
    }

    private func changeMode(_ mode: DeviceBrightnessMode) {
        duplicateTime = false
        draft.mode = mode
        if mode == .schedule, draft.schedule.isEmpty {
            draft.schedule = [.init(minuteOfDay: 0, level: draft.fixedLevel)]
        }
        preferences.save(draft)
    }

    private func finishLevelEditing() {
        guard editingLevel else { return }
        editingLevel = false
        preferences.save(draft)
    }

    private func levelSlider(_ value: Binding<Double>) -> some View {
        HStack {
            Slider(value: Binding(get: { value.wrappedValue }, set: { level in
                value.wrappedValue = level
                if editingLevel { preferences.preview(draft) }
                else { preferences.save(draft) }
            }), in: 0...1) { Text("Brightness") } onEditingChanged: { editing in
                if editing { editingLevel = true }
                else { finishLevelEditing() }
            }
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
            let minute = (time.hour ?? 0) * 60 + (time.minute ?? 0)
            if draft.schedule.indices.contains(where: { $0 != index && draft.schedule[$0].minuteOfDay == minute }) {
                duplicateTime = true
                return
            }
            duplicateTime = false
            draft.schedule[index].minuteOfDay = minute
            preferences.save(draft)
        })
    }
    private func levelBinding(_ index: Int) -> Binding<Double> {
        Binding(get: { draft.schedule.indices.contains(index) ? draft.schedule[index].level : 0.5 },
                set: { value in if draft.schedule.indices.contains(index) { draft.schedule[index].level = value } })
    }
}
