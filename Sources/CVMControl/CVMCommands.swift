import Foundation

/// Command syntax from the Stewart CVM Owners Manual, page 14.
enum CVM {
    /// Factory-default Telnet login (CVM web page → TELNET; users Telnet 1–4 / Password 1–4).
    static let defaultUsername = "Telnet 1"
    static let defaultPassword = "Password 1"

    static let channels: [(id: Int, name: String)] = [(1, "A"), (2, "B"), (3, "C"), (4, "D")]

    static func name(_ ch: Int) -> String { channels.first { $0.id == ch }?.name ?? "\(ch)" }

    static func up(_ ch: Int) -> String { "#1.1.\(ch).MOTOR=UP;" }
    static func down(_ ch: Int) -> String { "#1.1.\(ch).MOTOR=DOWN;" }
    static func stop(_ ch: Int) -> String { "#1.1.\(ch).MOTOR=STOP;" }
    static let stopAll = "#1.1.0.MOTOR=STOP;"
    static let retract = "#1.1.0.MOTOR=RETRACT;"
    static func recall(_ preset: Int) -> String { "#1.1.0.MOTOR=RECALL,\(preset);" }
    static func store(_ preset: Int) -> String { "#1.1.0.MOTOR=STORE,\(preset);" }
    /// Move channel to a position in % (undocumented in the Stewart manual; verified on-site).
    static func goTo(_ ch: Int, _ percent: Double) -> String {
        let p = min(max(percent, 0), 100)
        let s = p == p.rounded() ? String(Int(p)) : String(format: "%.2f", p)
        return "#1.1.\(ch).MOTOR=GOTO,\(s);"
    }
    static func queryPosition(_ ch: Int) -> String { "#1.1.\(ch).MOTOR.POSITION=?;" }
}
