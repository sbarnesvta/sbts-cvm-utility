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

    var lineEnding = "\r"

    func connect(host: String, port: UInt16, username: String, password: String) {
        disconnect()
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed("Enter a valid IP address and port")
            return
        }
        self.username = username
        self.password = password
        sentUser = false
        sentPass = false
        rxBuffer = ""

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
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
        if connection != nil { info("Disconnected") }
        connection?.cancel()
        connection = nil
        state = .disconnected
    }

    func send(_ command: String) {
        guard let connection, state == .connected else {
            info("Not connected — command not sent: \(command)")
            return
        }
        appendLog(.sent, command)
        let data = Data((command + lineEnding).utf8)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { Task { @MainActor in self?.info("Send error: \(error.localizedDescription)") } }
        })
    }

    func clearLog() { log.removeAll() }

    // MARK: - Private

    private func handle(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            state = .connected
            info("Connected")
            receive()
        case .failed(let error):
            state = .failed(error.localizedDescription)
            info("Connection failed: \(error.localizedDescription)")
            connection?.cancel()
            connection = nil
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
                    if let error { self.info("Receive error: \(error.localizedDescription)") }
                    self.info("Connection closed by device")
                    self.connection?.cancel()
                    self.connection = nil
                    self.state = .disconnected
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

    private func autoLogin() {
        let lower = rxBuffer.lowercased()
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
            guard !trimmed.isEmpty else { continue }
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
    }

    private func info(_ text: String) { appendLog(.info, text) }

    private func appendLog(_ dir: LogLine.Direction, _ text: String) {
        log.append(LogLine(direction: dir, text: text))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }
}
