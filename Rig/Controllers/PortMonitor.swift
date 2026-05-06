import Foundation

/// A detected listening server inside a Rig session.
struct DetectedServer: Identifiable, Equatable, Sendable {
    let id: String
    let port: UInt16
    let processName: String

    var url: URL { URL(string: "http://localhost:\(port)")! }
    var displayLabel: String { "localhost:\(port)" }
}

/// Polls for listening TCP ports and attributes them to Rig sessions.
///
/// Primary attribution is via `RIG_SESSION_ID`, which Rig injects into every
/// Ghostty terminal it creates. That survives common server launch patterns
/// where the server backgrounds and is reparented to launchd.
@MainActor
final class PortMonitor: ObservableObject {
    nonisolated static let sessionEnvironmentKey = "RIG_SESSION_ID"

    @Published private(set) var serversBySession: [UUID: [DetectedServer]] = [:]

    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration = .seconds(1)

    private var sessionIDs: Set<UUID> = []

    func startMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(1))
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    func registerSession(_ sessionID: UUID) {
        sessionIDs.insert(sessionID)
        Task { [weak self] in
            await self?.refresh()
        }
    }

    func removeSession(_ sessionID: UUID) {
        sessionIDs.remove(sessionID)
        serversBySession.removeValue(forKey: sessionID)
    }

    func removeAll() {
        sessionIDs.removeAll()
        serversBySession.removeAll()
    }

    // MARK: - Polling

    private func refresh() async {
        let sessionSnapshot = sessionIDs
        guard !sessionSnapshot.isEmpty else { return }

        let detected = await Task.detached(priority: .utility) {
            Self.detectServers(for: sessionSnapshot)
        }.value

        let filtered = detected.filter { sessionIDs.contains($0.key) }

        if filtered != serversBySession {
            serversBySession = filtered
        }
    }

    private nonisolated static func detectServers(
        for sessionIDs: Set<UUID>
    ) -> [UUID: [DetectedServer]] {
        let listeners = fetchListeningPorts()
        guard !listeners.isEmpty else { return [:] }

        var serversByPortBySession: [UUID: [UInt16: DetectedServer]] = [:]
        var envSessionCache: [pid_t: UUID] = [:]
        var checkedEnvironmentPIDs: Set<pid_t> = []

        for listener in listeners {
            if !checkedEnvironmentPIDs.contains(listener.pid) {
                checkedEnvironmentPIDs.insert(listener.pid)
                if let sessionID = processEnvironmentSessionID(pid: listener.pid) {
                    envSessionCache[listener.pid] = sessionID
                }
            }

            if let sessionID = envSessionCache[listener.pid],
               sessionIDs.contains(sessionID) {
                add(listener, to: sessionID, in: &serversByPortBySession)
            }
        }

        return serversByPortBySession.mapValues { serversByPort in
            serversByPort.values.sorted { $0.port < $1.port }
        }
    }

    private nonisolated static func add(
        _ listener: Listener,
        to sessionID: UUID,
        in serversByPortBySession: inout [UUID: [UInt16: DetectedServer]]
    ) {
        var serversByPort = serversByPortBySession[sessionID, default: [:]]
        serversByPort[listener.port] = DetectedServer(
            id: "\(sessionID)|\(listener.port)",
            port: listener.port,
            processName: listener.name
        )
        serversByPortBySession[sessionID] = serversByPort
    }

    // MARK: - lsof / ps parsing

    struct Listener: Sendable {
        let pid: pid_t
        let port: UInt16
        let name: String
    }

    nonisolated static func fetchListeningPorts() -> [Listener] {
        guard let output = runProcess(
            executable: "/usr/sbin/lsof",
            arguments: ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "-Fpcn"]
        ) else { return [] }

        var results: [Listener] = []
        var currentPID: pid_t = 0
        var currentName = ""

        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                currentPID = pid_t(line.dropFirst()) ?? 0
                currentName = ""
            } else if line.hasPrefix("c") {
                currentName = String(line.dropFirst())
            } else if line.hasPrefix("n") {
                let addr = String(line.dropFirst())
                if let colonIdx = addr.lastIndex(of: ":"),
                   let port = UInt16(addr[addr.index(after: colonIdx)...]),
                   currentPID > 0 {
                    results.append(Listener(
                        pid: currentPID,
                        port: port,
                        name: currentName
                    ))
                }
            }
        }

        return results
    }

    private nonisolated static func processEnvironmentSessionID(pid: pid_t) -> UUID? {
        guard let output = runProcess(
            executable: "/bin/ps",
            arguments: ["eww", "-p", String(pid)]
        ) else { return nil }

        let prefix = "\(sessionEnvironmentKey)="
        for token in output.split(whereSeparator: \.isWhitespace) {
            guard token.hasPrefix(prefix) else { continue }
            return UUID(uuidString: String(token.dropFirst(prefix.count)))
        }

        return nil
    }

    private nonisolated static func runProcess(
        executable: String,
        arguments: [String]
    ) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
