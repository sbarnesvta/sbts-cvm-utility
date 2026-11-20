import Foundation
import Network

/// Minimal Telnet client: raw TCP + IAC option negotiation (refuses all options),
/// optional auto-login when the device prompts for user name / password.
@MainActor
final class TelnetClient: ObservableObject {
    enum State: Equatable { case disconnected, connecting, connected, failed(String) }

    @Published var state: State = .disconnected
    @Published var log: [LogLine] = []
    @Published var positions: [Int: String] = [:]   // channel (1-4) -> position %
    @Published var moveTargets: [Int: Double] = [:]  // channels currently driving to a target

    struct LogLine: Identifiable {
        let id = UUID()
        let date = Date()
        let direction: Direction
        let text: String
        enum Direction { case sent, received, info }
    }

    private var connection: NWConnection?
    private var rxBuffer = ""
    private var username = ""
    private var password = ""
    private var sentUser = false
    private var sentPass = false

    // Reconnect / keepalive
    private var host = ""
    private var port: UInt16 = 23
    private var userWantsConnection = false
    private var connectedAt: Date?
    private var lastActivity = Date()
    private var keepaliveTimer: Timer?
    private var reconnectTask: Task<Void, Never>?

    var lineEnding = "\r"
    /// Seconds of idle before a harmless position query is sent (0 = off).
    var keepaliveInterval: TimeInterval = 20
    var autoReconnect = true

    func connect(host: String, port: UInt16, username: String, password: String) {
        disconnect()
        userWantsConnection = true
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, NWEndpoint.Port(rawValue: port) != nil else {
            userWantsConnection = false
            state = .failed("Enter a valid IP address and port")
            return
        }
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        open()
    }

    private func open() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        sentUser = false
        sentPass = false
        warnedNoLogin = false
        rxBuffer = ""

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        connection = conn
        state = .connecting
        info("Connecting to \(host):\(port)…")

        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in self?.handle(newState) }
        }
        conn.start(queue: .main)
    }

    func disconnect() {
        userWantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        if connection != nil { info("Disconnected") }
        teardown()
        state = .disconnected
    }

    private func teardown() {
        cancelAllMoves()
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        connectedAt = nil
    }

    /// Called when the link drops without the user asking.
    private func connectionLost(_ reason: String) {
        let duration = connectedAt.map { String(format: " after %.0f s", Date().timeIntervalSince($0)) } ?? ""
        info("\(reason)\(duration)")
        teardown()
        state = .disconnected
        guard userWantsConnection, autoReconnect else { return }
        state = .connecting
        info("Reconnecting in 2 s…")
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.userWantsConnection else { return }
            self.open()
        }
    }

    private func startKeepalive() {
        keepaliveTimer?.invalidate()
        guard keepaliveInterval > 0 else { return }
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .connected, self.keepaliveInterval > 0,
                      Date().timeIntervalSince(self.lastActivity) >= self.keepaliveInterval else { return }
                // Harmless query keeps the CVM's idle timer from closing the session.
                self.rawSend(CVM.queryPosition(1) + self.lineEnding)
            }
        }
    }

    private func rawSend(_ string: String) {
        lastActivity = Date()
        connection?.send(content: Data(string.utf8), completion: .contentProcessed { [weak self] error in
            if let error { Task { @MainActor in self?.info("Send error: \(error.localizedDescription)") } }
        })
    }

    func send(_ command: String) {
        guard let connection, state == .connected else {
            info("Not connected — command not sent: \(command)")
            return
        }
        _ = connection
        appendLog(.sent, command)
        rawSend(command + lineEnding)
    }

    func clearLog() { log.removeAll() }

    // MARK: - Private

    private func handle(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            state = .connected
            connectedAt = Date()
            lastActivity = Date()
            info("Connected")
            startKeepalive()
            receive()
        case .failed(let error):
            if connectedAt != nil || (userWantsConnection && autoReconnect && state == .connecting && reconnectTask != nil) {
                connectionLost("Connection lost: \(error.localizedDescription)")
            } else {
                teardown()
                userWantsConnection = false
                state = .failed(error.localizedDescription)
                info("Connection failed: \(error.localizedDescription)")
            }
        case .waiting(let error):
            info("Waiting: \(error.localizedDescription)")
        case .cancelled:
            if state != .disconnected, case .failed = state {} else { state = .disconnected }
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.process(data) }
                if isComplete || error != nil {
                    if let error {
                        self.connectionLost("Receive error: \(error.localizedDescription)")
                    } else {
                        self.connectionLost("Connection closed by device")
                    }
                    return
                }
                self.receive()
            }
        }
    }

    /// Strip Telnet IAC sequences (answering DO→WONT, WILL→DONT) and handle text.
    private func process(_ data: Data) {
        let IAC: UInt8 = 255, DONT: UInt8 = 254, DO: UInt8 = 253, WONT: UInt8 = 252, WILL: UInt8 = 251, SB: UInt8 = 250, SE: UInt8 = 240
        var text = [UInt8]()
        var reply = [UInt8]()
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == IAC, i + 1 < bytes.count {
                let cmd = bytes[i + 1]
                switch cmd {
                case DO, DONT, WILL, WONT:
                    if i + 2 < bytes.count {
                        let opt = bytes[i + 2]
                        if cmd == DO { reply += [IAC, WONT, opt] }
                        if cmd == WILL { reply += [IAC, DONT, opt] }
                    }
                    i += 3
                case SB:
                    i += 2
                    while i + 1 < bytes.count, !(bytes[i] == IAC && bytes[i + 1] == SE) { i += 1 }
                    i += 2
                case IAC:
                    text.append(IAC); i += 2
                default:
                    i += 2
                }
            } else {
                text.append(b); i += 1
            }
        }
        if !reply.isEmpty { connection?.send(content: Data(reply), completion: .idempotent) }
        guard !text.isEmpty else { return }

        let chunk = String(decoding: text, as: UTF8.self)
        rxBuffer += chunk
        autoLogin()
        flushLines()
    }

    private var warnedNoLogin = false

    private func autoLogin() {
        let lower = rxBuffer.lowercased()
        if username.isEmpty, !warnedNoLogin, lower.contains("user") || lower.contains("login") {
            warnedNoLogin = true
            info("⚠️ Device is asking for a login — enter User and Password, then reconnect")
        }
        if !sentUser, !username.isEmpty, lower.contains("user") || lower.contains("login") {
            sentUser = true
            flushPartial()
            info("Sending user name")
            connection?.send(content: Data((username + "\r\n").utf8), completion: .idempotent)
        } else if !sentPass, !password.isEmpty, lower.contains("password") {
            sentPass = true
            flushPartial()
            info("Sending password")
            connection?.send(content: Data((password + "\r\n").utf8), completion: .idempotent)
        }
    }

    private func flushPartial() {
        let t = rxBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { appendLog(.received, t) }
        rxBuffer = ""
    }

    /// Responses are split on newlines and on ';' (CVM terminator).
    private func flushLines() {
        while let idx = rxBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == ";" }) {
            var line = String(rxBuffer[..<idx])
            if rxBuffer[idx] == ";" { line += ";" }
            rxBuffer = String(rxBuffer[rxBuffer.index(after: idx)...])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "\0" else { continue }
            appendLog(.received, trimmed)
            parsePosition(trimmed)
        }
    }

    private func parsePosition(_ line: String) {
        // e.g. "!1.1.2.MOTOR.POSITION=45;"
        let pattern = #"1\.1\.(\d)\.MOTOR\.POSITION\s*=\s*([0-9.]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let chR = Range(m.range(at: 1), in: line),
              let valR = Range(m.range(at: 2), in: line),
              let ch = Int(line[chR]) else { return }
        positions[ch] = String(line[valR])
        if let v = Double(line[valR]) {
            positionValues[ch] = v
            positionUpdated[ch] = Date()
        }
    }

    // MARK: - Go to position
    //
    // Channel A honours the CVM's GOTO command. On-site, B–D accept GOTO but don't move,
    // so for those we time an UP/DOWN run. Polling can't be used to stop on target: while a
    // motor runs, position queries return the last *stopped* value, and live updates only
    // arrive every ~2 s. Measured on channel B: ~20 %/s plus ~2.6 % coast after STOP.

    private var gotoUnsupported: Set<Int> = []
    private var positionValues: [Int: Double] = [:]
    private var positionUpdated: [Int: Date] = [:]
    private var moveTasks: [Int: Task<Void, Never>] = [:]

    /// Per channel and direction (+1 up / -1 down): speed in %/s and coast in % after STOP.
    private var motion: [Int: [Int: (speed: Double, coast: Double)]] = [:]
    private let defaultMotion = (speed: 20.0, coast: 2.6)
    private let tolerance = 1.5      // % — close enough
    private let maxRun: TimeInterval = 8

    func goTo(_ ch: Int, _ target: Double) {
        guard state == .connected else { info("Not connected — can't move channel \(CVM.name(ch))"); return }
        let target = min(max(target, 0), 100)
        cancelMove(ch)
        moveTargets[ch] = target
        moveTasks[ch] = Task { @MainActor [weak self] in
            await self?.runMove(ch, target)
            guard let self, !Task.isCancelled else { return }
            self.moveTasks[ch] = nil
            self.moveTargets[ch] = nil
        }
    }

    /// Abandon a Go-to on this channel (the user's own command takes over).
    func cancelMove(_ ch: Int) {
        moveTasks.removeValue(forKey: ch)?.cancel()
        moveTargets[ch] = nil
    }

    func cancelAllMoves() {
        for ch in Array(moveTasks.keys) { cancelMove(ch) }
    }

    private func runMove(_ ch: Int, _ target: Double) async {
        let name = CVM.name(ch)

        if !gotoUnsupported.contains(ch) {
            let before = await freshPosition(ch)
            send(CVM.goTo(ch, target))
            guard await pause(2.5) else { return }
            let after = await freshPosition(ch)
            if let a = after, let b = before, abs(a - b) > 0.2 || abs(a - target) <= tolerance {
                return  // the CVM is handling it; its own position report will follow
            }
            guard !Task.isCancelled else { return }
            gotoUnsupported.insert(ch)
            info("Channel \(name) ignored GOTO — using timed Up/Down instead")
        } else {
            info("Channel \(name) → \(fmt(target))%")
        }

        for _ in 0..<3 {
            guard let p = await freshPosition(ch) else {
                info("Channel \(name): couldn't read position — move cancelled"); return
            }
            let delta = target - p
            if abs(delta) <= tolerance { info("Channel \(name) at \(fmt(p))%"); return }
            let dir = delta > 0 ? 1 : -1
            let m = motion[ch]?[dir] ?? defaultMotion
            let minMove = m.coast + m.speed * 0.1
            if abs(delta) < minMove {
                info("Channel \(name) at \(fmt(p))% — \(fmt(abs(delta)))% is too small a step to make accurately")
                return
            }
            let run = min(max((abs(delta) - m.coast) / m.speed, 0.1), maxRun)

            send(dir > 0 ? CVM.up(ch) : CVM.down(ch))
            guard await pause(run) else { return }
            send(CVM.stop(ch))
            guard await pause(2) else { return }   // let it coast and settle

            // Learn this motor's speed from what actually happened.
            if let q = await freshPosition(ch), q < 99.9, q > 0.1 {
                let moved = abs(q - p)
                let measured = (moved - m.coast) / run
                if measured.isFinite, measured > 1, measured < 200 {
                    motion[ch, default: [:]][dir] = (speed: (m.speed + measured) / 2, coast: m.coast)
                }
            }
        }
        if let p = positionValues[ch] { info("Channel \(name) at \(fmt(p))% (target \(fmt(target))%)") }
    }

    /// Sleep; returns false if the move was cancelled meanwhile.
    private func pause(_ seconds: TimeInterval) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled && state == .connected
    }

    /// Query a channel and wait (up to 1.5 s) for a reply newer than the query.
    private func freshPosition(_ ch: Int) async -> Double? {
        let asked = Date()
        rawSend(CVM.queryPosition(ch) + lineEnding)
        for _ in 0..<15 {
            if let t = positionUpdated[ch], t >= asked { return positionValues[ch] }
            guard await pause(0.1) else { return nil }
        }
        return nil
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    private func info(_ text: String) { appendLog(.info, text) }

    private func appendLog(_ dir: LogLine.Direction, _ text: String) {
        log.append(LogLine(direction: dir, text: text))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }
}
