import Foundation

struct RenderJob {
    var weather: WeatherSnapshot
    var date: Date
    var output: URL
    var simulateIncompatible = false
    var simulateCrash = false
}

struct RenderResult {
    var output: URL
    var sunElevation: Double?
}

enum RenderOutcome {
    case success(RenderResult)
    case failure(FailureRecord)
}

/// Runs Contents/Helpers/LiveSkyRenderer.app once per update. The helper is a separate process so
/// that a WeatherUI incompatibility can never take LiveSky itself down.
final class RendererRunner: @unchecked Sendable {
    static let timeout: TimeInterval = 60
    private let lock = NSLock()
    private var running: Process?

    func render(_ job: RenderJob) async -> RenderOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.run(job))
            }
        }
    }

    /// Stops a render in progress (quit, pause or restore). The caller discards the outcome.
    func cancel() {
        lock.lock()
        let process = running
        lock.unlock()
        if let process, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// The weather inputs, shared by wallpaper renders and the live sky.
    static func weatherArguments(_ weather: WeatherSnapshot, date: Date) -> [String] {
        let iso = ISO8601DateFormatter()
        var arguments = [
            "--date", iso.string(from: date),
            "--condition", weather.condition,
            "--cloud-cover", String(weather.cloudCover),
            "--wind-speed", String(weather.windSpeed),
            "--latitude", String(weather.latitude),
            "--longitude", String(weather.longitude),
            "--timezone", weather.timeZone,
            "--city", weather.placeName,
            "--width", "1826", "--height", "1344",
        ]
        if let sunrise = weather.sunrise { arguments += ["--sunrise", iso.string(from: sunrise)] }
        if let sunset = weather.sunset { arguments += ["--sunset", iso.string(from: sunset)] }
        return arguments
    }

    private func arguments(_ job: RenderJob) -> [String] {
        var arguments = ["--output", job.output.path] + Self.weatherArguments(job.weather, date: job.date)
        if job.simulateIncompatible { arguments.append("--simulate-incompatible") }
        if job.simulateCrash { arguments.append("--simulate-crash") }
        return arguments
    }

    private func run(_ job: RenderJob) -> RenderOutcome {
        let process = Process()
        process.executableURL = Paths.renderer
        process.arguments = arguments(job)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let outputData = Box(Data()), errorData = Box(Data())
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData.value = output.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData.value = errors.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let started = Date()
        do {
            try process.run()
        } catch {
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            readers.wait()
            return .failure(record(kind: "launch", check: "LAUNCH", detail: error.localizedDescription, stage: "launch",
                                   exit: "not started", stdout: "", stderr: ""))
        }
        lock.lock()
        running = process
        lock.unlock()
        let timedOut = Box(false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.value = true
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        exited.wait()
        watchdog.cancel()
        readers.wait()
        lock.lock()
        running = nil
        lock.unlock()

        let stdout = String(decoding: outputData.value, as: UTF8.self)
        let stderr = String(decoding: errorData.value, as: UTF8.self)
        let exit = process.terminationReason == .uncaughtSignal
            ? "signal \(process.terminationStatus)" : "exit \(process.terminationStatus)"
        Log.info("renderer finished in \(String(format: "%.1f", Date().timeIntervalSince(started))) s with \(exit)")
        let status = Self.statusLine(stdout)
        let state = status?["status"] as? String ?? ""
        let stage = status?["stage"] as? String ?? Self.lastStage(stderr)

        if timedOut.value {
            return .failure(record(kind: "timeout", check: "TIMEOUT", detail: "no result after \(Int(Self.timeout)) s",
                                   stage: stage, exit: exit, stdout: stdout, stderr: stderr))
        }
        switch state {
        case "ok" where process.terminationReason == .exit && process.terminationStatus == 0:
            guard FileManager.default.fileExists(atPath: job.output.path) else {
                return .failure(record(kind: "output", check: "OUTPUT", detail: "the renderer reported success but wrote no PNG",
                                       stage: stage, exit: exit, stdout: stdout, stderr: stderr))
            }
            return .success(RenderResult(output: job.output, sunElevation: status?["sunElevation"] as? Double))
        case "fail":
            return .failure(record(kind: "check", check: status?["check"] as? String ?? "UNKNOWN",
                                   detail: status?["detail"] as? String ?? "", stage: stage, exit: exit,
                                   stdout: stdout, stderr: stderr))
        case "crash":
            let signal = status?["signal"] as? Int ?? 0
            return .failure(record(kind: "crash", check: "CRASH", detail: "signal \(signal) (\(Self.signalName(signal)))",
                                   stage: stage, exit: exit, stdout: stdout, stderr: stderr))
        default:
            if process.terminationReason == .uncaughtSignal {
                let signal = Int(process.terminationStatus)
                return .failure(record(kind: "killed", check: "TERMINATED", detail: "signal \(signal) (\(Self.signalName(signal)))",
                                       stage: stage, exit: exit, stdout: stdout, stderr: stderr))
            }
            return .failure(record(kind: "exit", check: "EXIT", detail: "the renderer exited without a result (\(exit))",
                                   stage: stage, exit: exit, stdout: stdout, stderr: stderr))
        }
    }

    private func record(kind: String, check: String, detail: String, stage: String, exit: String,
                        stdout: String, stderr: String) -> FailureRecord {
        FailureRecord(kind: kind, check: check, detail: detail, stage: stage,
                      osVersion: SystemInfo.osVersion, osBuild: SystemInfo.osBuild, date: Date(),
                      exitDescription: exit, stdout: String(stdout.suffix(20_000)), stderr: String(stderr.suffix(60_000)))
    }

    private static func statusLine(_ stdout: String) -> [String: Any]? {
        for line in stdout.split(separator: "\n").reversed() where line.hasPrefix("LIVESKY_STATUS ") {
            let json = line.dropFirst("LIVESKY_STATUS ".count)
            return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        }
        return nil
    }

    private static func lastStage(_ stderr: String) -> String {
        for line in stderr.split(separator: "\n").reversed() where line.hasPrefix("STAGE ") {
            return String(line.dropFirst(6))
        }
        return "launch"
    }

    static func signalName(_ signal: Int) -> String {
        switch Int32(signal) {
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGABRT: return "SIGABRT"
        case SIGFPE: return "SIGFPE"
        case SIGKILL: return "SIGKILL"
        case SIGTERM: return "SIGTERM"
        default: return "signal \(signal)"
        }
    }
}
