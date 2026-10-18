import Foundation
import UIKit
import SwiftUI
import WeatherKit
import CoreLocation
import Darwin

// LiveSkyRenderer: a one-shot Mac Catalyst helper. LiveSky launches it once per update with the
// weather inputs as arguments; it renders Apple's WeatherUI sky once into a transparent,
// non-interactive window, captures it to a PNG, prints one LIVESKY_STATUS line and exits.

private func log(_ message: String) { fputs(message + "\n", stderr) }
private struct MetadataResponse { let pointer: UnsafeRawPointer; let state: UInt }
private typealias MetadataAccessor = @convention(thin) (UInt) -> MetadataResponse

private struct LocationIdentifierLayout {
    var id: String
    var name: String
    var coordinate: CLLocationCoordinate2D
}
private struct LocationLayout {
    var identifier: LocationIdentifierLayout
    var timeZone: TimeZone
    var lastRefreshDate: Date?
    var searchTitle: String?
    var searchSubtitle: String?
    var preciseName: String?
    var secondaryName: String?
}

struct RenderRequest {
    var output = ""
    var date = Date()
    var condition = "clear"
    var cloudCover = 0.0
    var windSpeed = 2.0
    var latitude = 0.0
    var longitude = 0.0
    var timeZone = "UTC"
    var city = ""
    var sunrise: Date?
    var sunset: Date?
    // Verified composition size. Bigger views and 2x renderers lost the sun, moon and other
    // celestial effects during research, so the app scales this frame up per display instead.
    var width: CGFloat = 1826
    var height: CGFloat = 1344
    var visible = false
    var simulateIncompatible = false
    var simulateCrash = false

    static func parse(_ arguments: [String]) -> RenderRequest {
        var request = RenderRequest()
        let flags: Set<String> = ["visible", "simulate-incompatible", "simulate-crash"]
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                if flags.contains(key) {
                    values[key] = "1"
                } else if index + 1 < arguments.count {
                    values[key] = arguments[index + 1]
                    index += 1
                }
            }
            index += 1
        }
        let iso = ISO8601DateFormatter()
        func number(_ key: String) -> Double? { values[key].flatMap(Double.init) }
        func date(_ key: String) -> Date? { values[key].flatMap { iso.date(from: $0) } }
        guard let output = values["output"], output.hasPrefix("/") else { livesky_fail("ARGUMENTS", "missing --output") }
        guard let when = date("date") else { livesky_fail("ARGUMENTS", "missing or invalid --date") }
        guard let latitude = number("latitude"), let longitude = number("longitude"),
              abs(latitude) <= 90, abs(longitude) <= 180 else { livesky_fail("ARGUMENTS", "missing or invalid coordinates") }
        request.output = output
        request.date = when
        request.latitude = latitude
        request.longitude = longitude
        request.condition = values["condition"] ?? "clear"
        request.cloudCover = min(1, max(0, number("cloud-cover") ?? 0))
        request.windSpeed = max(0, number("wind-speed") ?? 2)
        request.timeZone = values["timezone"] ?? "UTC"
        request.city = values["city"] ?? ""
        request.sunrise = date("sunrise")
        request.sunset = date("sunset")
        if let width = number("width"), let height = number("height"), width >= 320, height >= 240, width <= 4096, height <= 4096 {
            request.width = CGFloat(width)
            request.height = CGFloat(height)
        }
        request.visible = values["visible"] != nil
        request.simulateIncompatible = values["simulate-incompatible"] != nil
        request.simulateCrash = values["simulate-crash"] != nil
        return request
    }
}

livesky_install_crash_handlers()
setvbuf(stdout, nil, _IOLBF, 0)
private let request = RenderRequest.parse(CommandLine.arguments)
livesky_simulate(request.simulateIncompatible ? 1 : 0, request.simulateCrash ? 1 : 0)
// Backstop in case WeatherUI hangs; LiveSky also enforces its own timeout.
DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
    livesky_fail("TIMEOUT", "the renderer did not finish within 45 seconds")
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    var window: UIWindow?
    var polls = 0

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        log("APP started Catalyst=\(ProcessInfo.processInfo.isMacCatalystApp)")
        livesky_stage("window")
        if !request.visible, livesky_conceal_windows(1) == 0 {
            livesky_fail("WINDOW", "could not make the AppKit host window invisible")
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: request.width, height: request.height))
        window.rootViewController = UIHostingController(rootView: Color.black)
        self.window = window
        if request.visible {
            window.makeKeyAndVisible()
        } else {
            // Transparent, non-interactive and never key: nothing appears on screen and the
            // frontmost app keeps focus.
            window.alpha = 0
            window.isUserInteractionEnabled = false
            window.isHidden = false
            livesky_conceal_existing_windows("shown")
        }
        livesky_stage("weather inputs")
        guard var condition = WeatherCondition(rawValue: request.condition) else {
            livesky_fail("ARGUMENTS", "unknown weather condition \(request.condition)")
        }
        guard MemoryLayout<WeatherCondition>.size == 1 else {
            livesky_fail("SIZE MISMATCH", "WeatherKit.WeatherCondition is \(MemoryLayout<WeatherCondition>.size) bytes, expected 1")
        }
        let byte = withUnsafeBytes(of: &condition) { $0[0] }
        let emptyArray = unsafeBitCast([String](), to: UnsafeRawPointer.self)
        guard let zone = TimeZone(identifier: request.timeZone) else { livesky_fail("ARGUMENTS", "invalid time zone \(request.timeZone)") }
        let city = request.city.isEmpty ? "LiveSky" : request.city
        var location = LocationLayout(
            identifier: LocationIdentifierLayout(id: "\(request.latitude),\(request.longitude)", name: city,
                                                 coordinate: .init(latitude: request.latitude, longitude: request.longitude)),
            timeZone: zone, lastRefreshDate: request.date, searchTitle: city, searchSubtitle: nil,
            preciseName: city, secondaryName: nil
        )
        guard MemoryLayout<LocationLayout>.size == 144,
              MemoryLayout<LocationIdentifierLayout>.size == 48 else {
            livesky_fail("SIZE MISMATCH", "local Location layout is \(MemoryLayout<LocationLayout>.size) bytes, expected 144")
        }
        withUnsafePointer(to: &location) { pointer in
            weather_frame_prepare(byte, emptyArray, request.date.timeIntervalSinceReferenceDate,
                                  request.cloudCover, request.windSpeed,
                                  UnsafeRawPointer(pointer), Double(request.width), Double(request.height),
                                  request.sunrise?.timeIntervalSinceReferenceDate ?? .nan,
                                  request.sunset?.timeIntervalSinceReferenceDate ?? .nan)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.checkLoaded() }
        return true
    }

    func checkLoaded() {
        polls += 1
        if weather_frame_loaded() != 0 {
            log("BACKGROUND loaded after \(Double(polls) * 0.25)s")
            showOriginalView()
        } else if polls < 80 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.checkLoaded() }
        } else {
            livesky_fail("TIMEOUT", "WeatherUI background did not load within 20 seconds")
        }
    }

    func showOriginalView() {
        guard let raw = weather_frame_view() else { livesky_fail("VIEW", "WeatherUI returned no background effect model") }
        livesky_stage("composing view")
        guard let h = dlopen("/System/iOSSupport/System/Library/PrivateFrameworks/WeatherUI.framework/WeatherUI", RTLD_NOW),
              let accessorSymbol = dlsym(h, "$s9WeatherUI0A7VFXViewVMa") else {
            livesky_fail("MISSING SYMBOL", "$s9WeatherUI0A7VFXViewVMa")
        }
        let accessor = unsafeBitCast(accessorSymbol, to: MetadataAccessor.self)
        let type = unsafeBitCast(accessor(0).pointer, to: Any.Type.self)
        guard let viewType = type as? any View.Type else { livesky_fail("TYPE MISMATCH", "WeatherVFXView is not a SwiftUI View") }
        func wrap<V: View>(_ type: V.Type) -> AnyView {
            AnyView(raw.load(as: type))
        }
        let original = wrap(viewType)
        guard let gradientPointer = weather_frame_gradient() else { livesky_fail("GRADIENT", "no sky gradient") }
        let gradient = gradientPointer.load(as: Gradient.self)
        guard !gradient.stops.isEmpty else { livesky_fail("GRADIENT", "sky gradient has no stops") }
        for (index, stop) in gradient.stops.enumerated() {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            let resolved = UIColor(stop.color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            log("GRADIENT stop=\(index) at=\(stop.location) rgba=\(red),\(green),\(blue),\(alpha) resolved=\(resolved)")
        }
        let root = ZStack {
            LinearGradient(gradient: gradient, startPoint: .top, endPoint: .bottom)
            original
        }.ignoresSafeArea()
        window?.rootViewController = UIHostingController(rootView: root)
        if !request.visible { livesky_conceal_existing_windows("composed") }
        livesky_stage("rendering")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.capture() }
    }

    func capture() {
        livesky_stage("capturing")
        if !request.visible { livesky_conceal_existing_windows("capture") }
        guard let view = window?.rootViewController?.view else { livesky_fail("CAPTURE", "missing root view") }
        view.layoutIfNeeded()
        func describe(_ view: UIView, _ depth: Int = 0) {
            log(String(repeating: " ", count: depth) + "\(type(of: view)) \(view.bounds) layer=\(type(of: view.layer))")
            for child in view.subviews { describe(child, depth + 1) }
        }
        describe(view)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        // The automatic range picks a 16-bit extended context on wide-gamut displays, and
        // drawHierarchy then gamma-encodes the sRGB snapshot a second time (sRGB 0.5 -> 188/255),
        // which washes out WeatherUI's sky. An 8-bit sRGB context keeps the values intact.
        format.preferredRange = .standard
        var didDraw = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: request.width, height: request.height), format: format).image { _ in
            didDraw = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard didDraw else { livesky_fail("CAPTURE", "drawHierarchy returned false") }
        livesky_stage("writing PNG")
        guard let png = image.pngData() else { livesky_fail("CAPTURE", "PNG encoding failed") }
        do {
            try png.write(to: URL(fileURLWithPath: request.output), options: .atomic)
        } catch {
            livesky_fail("WRITE", "\(error.localizedDescription)")
        }
        log("CAPTURE drawHierarchy=\(didDraw) size=\(image.size) bytes=\(png.count)")
        var status: [String: Any] = ["status": "ok", "width": Int(image.size.width * image.scale),
                                     "height": Int(image.size.height * image.scale), "bytes": png.count]
        let sun = weather_frame_sun_elevation()
        if sun.isFinite { status["sunElevation"] = sun }
        let moon = weather_frame_moon_phase()
        if moon.isFinite { status["moonPhaseAngle"] = moon }
        let json = (try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])) ?? Data("{\"status\":\"ok\"}".utf8)
        print("LIVESKY_STATUS " + String(decoding: json, as: UTF8.self))
        fflush(stdout)
        exit(0)
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
