import Foundation

/// Command syntax from the Stewart CVM Owners Manual, page 14.
enum CVM {
    static let channels: [(id: Int, name: String)] = [(1, "A"), (2, "B"), (3, "C"), (4, "D")]

    static func up(_ ch: Int) -> String { "#1.1.\(ch).MOTOR=UP;" }
    static func down(_ ch: Int) -> String { "#1.1.\(ch).MOTOR=DOWN;" }
    static func stop(_ ch: Int) -> String { "#1.1.\(ch).MOTOR=STOP;" }
    static let stopAll = "#1.1.0.MOTOR=STOP;"
    static let retract = "#1.1.0.MOTOR=RETRACT;"
    static func recall(_ preset: Int) -> String { "#1.1.0.MOTOR=RECALL,\(preset);" }
    static func store(_ preset: Int) -> String { "#1.1.0.MOTOR=STORE,\(preset);" }
    static func queryPosition(_ ch: Int) -> String { "#1.1.\(ch).MOTOR.POSITION=?;" }
}
