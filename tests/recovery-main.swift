import Foundation
import CoreGraphics

enum ConfigStore {
    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}
enum Log { static func info(_ message: String) {} }

@main struct RecoveryTests {
    static func main() throws {
        try FileManager.default.createDirectory(at: ConfigStore.dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ConfigStore.dir) }
        func record(_ ids: [UInt32]) throws {
            try JSONEncoder().encode(ids).write(to: PhysicalDisplays.markerURL)
        }
        try record([1])
        precondition(PhysicalDisplays.restore(reason: "test", isActive: { _ in true }, enable: { _ in
            preconditionFailure("Already active display must never enter a CG transaction")
        }))
        precondition(PhysicalDisplays.pending == nil)
        try record([1, 2])
        precondition(!PhysicalDisplays.restore(reason: "test", isActive: { $0 == 1 }, enable: {
            precondition($0 == [2]); return .failure
        }))
        precondition(PhysicalDisplays.pending == [1, 2], "Failed recovery must preserve its safety record")
        precondition(PhysicalDisplays.restore(reason: "test", isActive: { $0 == 1 }, enable: {
            precondition($0 == [2]); return .success
        }))
        precondition(PhysicalDisplays.pending == nil)
        precondition(PhysicalDisplays.restore(reason: "test", isActive: { _ in false }, enable: { _ in
            preconditionFailure("No record needs no transaction")
        }))
        print("PASS: already-active recovery, mixed displays, failure preserves marker, successful retry")
    }
}
