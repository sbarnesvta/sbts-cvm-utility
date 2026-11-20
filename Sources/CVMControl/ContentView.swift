import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var client: TelnetClient

    @AppStorage("host") private var host = ""
    @AppStorage("port") private var port = 23
    @AppStorage("username") private var username = ""
    @AppStorage("password") private var password = ""
    @AppStorage("lineEnding") private var lineEnding = "\r"
    @AppStorage("channelCount") private var channelCount = 2

    @State private var storeMode = false
    @State private var pendingStore: Int?
    @State private var rawCommand = ""
    @State private var autoPoll = false
    @State private var pollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        motorsSection
                        presetsSection
                        querySection
                    }
                    .padding(16)
                }
                .frame(minWidth: 480)
                logPanel.frame(minWidth: 280)
            }
        }
        .onReceive(pollTimer) { _ in
            if autoPoll && client.state == .connected { queryAll() }
        }
        .onChange(of: lineEnding) { _, v in client.lineEnding = v }
        .onAppear { client.lineEnding = lineEnding }
        .confirmationDialog("Store current position as Preset \(pendingStore ?? 0)?",
                            isPresented: Binding(get: { pendingStore != nil }, set: { if !$0 { pendingStore = nil } })) {
            Button("Store Preset \(pendingStore ?? 0)", role: .destructive) {
                if let p = pendingStore { client.send(CVM.store(p)) }
                pendingStore = nil
                storeMode = false
            }
            Button("Cancel", role: .cancel) { pendingStore = nil }
        } message: {
            Text("This overwrites whatever is saved in that preset.")
        }
    }

    // MARK: Connection

    private var connectionBar: some View {
        HStack(spacing: 10) {
            statusDot
            TextField("IP address", text: $host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit(connect)
            TextField("Port", value: $port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
            TextField("User (optional)", text: $username)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            Picker("", selection: $lineEnding) {
                Text("CR").tag("\r")
                Text("CR+LF").tag("\r\n")
                Text("None").tag("")
            }
            .frame(width: 85)
            .help("Characters sent after each command")
            Spacer()
            if client.state == .connected || client.state == .connecting {
                Button("Disconnect") { client.disconnect() }
            } else {
                Button("Connect", action: connect)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    private var statusDot: some View {
        let (color, label): (Color, String) = switch client.state {
        case .connected: (.green, "Connected")
        case .connecting: (.orange, "Connecting")
        case .disconnected: (.gray, "Disconnected")
        case .failed(let msg): (.red, msg)
        }
        return Circle().fill(color).frame(width: 10, height: 10).help(label)
    }

    private func connect() {
        client.connect(host: host, port: UInt16(clamping: port), username: username, password: password)
    }

    // MARK: Motors

    private var motorsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Channels", selection: $channelCount) {
                        Text("A–B").tag(2)
                        Text("A–D").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    Spacer()
                    Button { client.send(CVM.retract) } label: { Label("Retract All (Home)", systemImage: "house") }
                    Button(role: .destructive) { client.send(CVM.stopAll) } label: {
                        Label("STOP ALL", systemImage: "stop.fill")
                    }
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space, modifiers: [])
                }
                HStack(spacing: 12) {
                    ForEach(CVM.channels.prefix(channelCount), id: \.id) { ch in
                        motorCard(ch.id, ch.name)
                    }
                }
            }
            .padding(6)
        } label: { Text("Motors").font(.headline) }
    }

    private func motorCard(_ id: Int, _ name: String) -> some View {
        VStack(spacing: 8) {
            Text("Channel \(name)").font(.subheadline.bold())
            Button { client.send(CVM.up(id)) } label: {
                Image(systemName: "arrow.up").frame(maxWidth: .infinity, minHeight: 24)
            }
            Button { client.send(CVM.stop(id)) } label: {
                Image(systemName: "stop.fill").frame(maxWidth: .infinity, minHeight: 24)
            }
            Button { client.send(CVM.down(id)) } label: {
                Image(systemName: "arrow.down").frame(maxWidth: .infinity, minHeight: 24)
            }
            Divider()
            Text(client.positions[id].map { "\($0)%" } ?? "—%")
                .font(.title3.monospacedDigit())
            Button("Query") { client.send(CVM.queryPosition(id)) }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    // MARK: Presets

    private var presetsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $storeMode) {
                    Text(storeMode ? "STORE mode — click a preset to save the current position"
                                   : "Recall mode — click a preset to move to it")
                        .foregroundStyle(storeMode ? .orange : .secondary)
                }
                .toggleStyle(.switch)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(1...24, id: \.self) { p in
                        Button {
                            if storeMode { pendingStore = p } else { client.send(CVM.recall(p)) }
                        } label: {
                            Text("\(p)").font(.body.monospacedDigit().bold())
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .tint(storeMode ? .orange : .accentColor)
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        } label: { Text("Presets").font(.headline) }
    }

    // MARK: Query

    private var querySection: some View {
        GroupBox {
            HStack {
                Button { queryAll() } label: { Label("Query All Positions", systemImage: "arrow.clockwise") }
                Toggle("Auto-refresh every 2 s", isOn: $autoPoll)
                Spacer()
            }
            .padding(6)
        } label: { Text("Query").font(.headline) }
    }

    private func queryAll() {
        for ch in CVM.channels.prefix(channelCount) { client.send(CVM.queryPosition(ch.id)) }
    }

    // MARK: Log

    private var logPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Console").font(.headline)
                Spacer()
                Button("Clear") { client.clearLog() }.controlSize(.small)
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(client.log) { line in
                            Text(prefix(line.direction) + line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(line.direction))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: client.log.count) { _, _ in
                    if let last = client.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                TextField("Raw command, e.g. #1.1.0.MOTOR=RECALL,3;", text: $rawCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(sendRaw)
                Button("Send", action: sendRaw)
            }
            .padding(8)
        }
    }

    private func sendRaw() {
        let cmd = rawCommand.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        client.send(cmd)
        rawCommand = ""
    }

    private func prefix(_ d: TelnetClient.LogLine.Direction) -> String {
        switch d { case .sent: "→ "; case .received: "← "; case .info: "• " }
    }

    private func color(_ d: TelnetClient.LogLine.Direction) -> Color {
        switch d { case .sent: .blue; case .received: .primary; case .info: .secondary }
    }
}
