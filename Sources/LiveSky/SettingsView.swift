import AppKit
import CoreLocation
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var windowIsFirstRun = false
    private let controller: LiveSkyController

    init(controller: LiveSkyController) {
        self.controller = controller
    }

    var windowNumber: Int? { window?.isVisible == true ? window?.windowNumber : nil }

    func show() {
        let firstRun = !controller.settings.setupComplete
        if window == nil || windowIsFirstRun != firstRun {
            window?.close()
            let view = SettingsView(controller: controller, firstRun: firstRun) { [weak self] in self?.window?.close() }
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.title = firstRun ? L("settings.welcomeTitle") : L("settings.title")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            windowIsFirstRun = firstRun
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

@MainActor
private final class CitySearch: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [Place] = []
    @Published private(set) var searching = false
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?

    func schedule(_ text: String, immediately: Bool = false) {
        task?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            message = nil
            searching = false
            return
        }
        task = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard !Task.isCancelled else { return }
            self?.searching = true
            do {
                let found = try await OpenMeteo().searchCities(trimmed, language: OpenMeteo.searchLanguage)
                guard !Task.isCancelled else { return }
                self?.results = found
                self?.message = found.isEmpty ? L("settings.city.none") : nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.results = []
                self?.message = L("settings.city.error", error.localizedDescription)
            }
            self?.searching = false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: LiveSkyController
    let firstRun: Bool
    let close: () -> Void

    @State private var mode: LocationMode?
    @State private var place: Place?
    @State private var interval: Int
    @State private var launchAtLogin: Bool
    @StateObject private var search = CitySearch()

    init(controller: LiveSkyController, firstRun: Bool, close: @escaping () -> Void) {
        self.controller = controller
        self.firstRun = firstRun
        self.close = close
        _mode = State(initialValue: controller.settings.locationMode)
        _place = State(initialValue: controller.settings.manualPlace)
        _interval = State(initialValue: controller.settings.intervalMinutes)
        _launchAtLogin = State(initialValue: controller.settings.launchAtLogin)
    }

    private var canStart: Bool { mode == .system || (mode == .manual && place != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if firstRun {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("settings.welcome")).font(.title2.weight(.semibold))
                    Text(L("settings.welcomeDetail")).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            GroupBox(label: Text(L("settings.location")).font(.headline)) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(selection: modeBinding, label: EmptyView()) {
                        Text(L("settings.location.system")).tag(Optional(LocationMode.system))
                        Text(L("settings.location.manual")).tag(Optional(LocationMode.manual))
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if mode == .system { systemLocation }
                    if mode == .manual { citySearch }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            GroupBox(label: Text(L("settings.updates")).font(.headline)) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(L("settings.interval"), selection: intervalBinding) {
                        ForEach(Settings.intervals, id: \.self) { minutes in
                            Text(L("settings.minutes", minutes)).tag(minutes)
                        }
                    }
                    .frame(maxWidth: 260)
                    Toggle(L("settings.launchAtLogin"), isOn: launchBinding)
                    if !firstRun, let note = controller.loginItemNote {
                        Text(note).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(L("settings.attribution"))
                        Link("Open-Meteo", destination: URL(string: "https://open-meteo.com")!)
                    }
                    Text(L("settings.version", SystemInfo.appVersion, SystemInfo.versionDescription))
                }
                .font(.caption)
                .foregroundColor(.secondary)
                Spacer()
                if firstRun {
                    Button(L("settings.start")) {
                        guard let mode else { return }
                        controller.completeSetup(mode: mode, place: place, intervalMinutes: interval, launchAtLogin: launchAtLogin)
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
                } else {
                    Button(L("settings.done")) { close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    @ViewBuilder private var systemLocation: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !CLLocationManager.locationServicesEnabled() {
                Text(L("settings.location.disabled")).foregroundColor(.orange)
                Button(L("settings.location.openSettings")) { openLocationSettings() }
            } else {
                switch controller.locationAuthorization {
                case .notDetermined:
                    Text(L("settings.location.notDetermined")).foregroundColor(.secondary)
                    Button(L("settings.location.allow")) { controller.location.requestAuthorization() }
                case .denied, .restricted:
                    Text(L("settings.location.denied")).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                    Button(L("settings.location.openSettings")) { openLocationSettings() }
                default:
                    if controller.settings.locationMode == .system, let name = controller.currentPlaceName {
                        Label(L("settings.location.current", name), systemImage: "location.fill")
                    } else {
                        Label(L("settings.location.granted"), systemImage: "location.fill")
                    }
                }
            }
            Text(L("settings.location.note")).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 20)
    }

    @ViewBuilder private var citySearch: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(L("settings.city.placeholder"), text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search.schedule(search.query, immediately: true) }
                if search.searching { ProgressView().controlSize(.small) }
            }
            .onChange(of: search.query) { text in search.schedule(text) }
            if let place {
                Label(L("settings.city.selected", place.displayName), systemImage: "mappin.and.ellipse")
            }
            if let message = search.message {
                Text(message).font(.caption).foregroundColor(.secondary)
            }
            if !search.results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(search.results, id: \.self) { result in
                            Button { select(result) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.name)
                                    Text(result.displayName).font(.caption).foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(result == place ? Color.accentColor.opacity(0.15) : Color.clear)
                            .cornerRadius(4)
                        }
                    }
                }
                .frame(height: min(CGFloat(search.results.count) * 38, 170))
            }
        }
        .padding(.leading, 20)
    }

    private func select(_ result: Place) {
        place = result
        search.query = ""
        if !firstRun { controller.setManualPlace(result) }
    }

    private var modeBinding: Binding<LocationMode?> {
        Binding(get: { mode }, set: { newValue in
            mode = newValue
            if newValue == .system { controller.location.requestAuthorization() }
            guard !firstRun, let newValue else { return }
            if newValue == .manual {
                if let place { controller.setManualPlace(place) }
            } else {
                controller.setLocationMode(.system)
            }
        })
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { interval }, set: { newValue in
            interval = newValue
            if !firstRun { controller.setInterval(newValue) }
        })
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { launchAtLogin }, set: { newValue in
            launchAtLogin = newValue
            if !firstRun { controller.setLaunchAtLogin(newValue) }
        })
    }

    private func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}
