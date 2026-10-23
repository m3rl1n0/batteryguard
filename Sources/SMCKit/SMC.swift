import Foundation
import IOKit

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound(String)
    case smcResult(String, UInt8)
    case sizeMismatch(String, expected: Int, got: Int)

    public var description: String {
        switch self {
        case .serviceNotFound: return "servizio AppleSMC non trovato"
        case .openFailed(let kr): return "IOServiceOpen fallito (\(String(format: "0x%x", kr)))"
        case .callFailed(let kr): return "chiamata SMC fallita (\(String(format: "0x%x", kr)))"
        case .keyNotFound(let key): return "chiave \(key) assente"
        case .smcResult(let key, let code): return "SMC ha risposto \(String(format: "0x%02x", code)) per \(key)"
        case .sizeMismatch(let key, let expected, let got):
            return "chiave \(key): attesi \(expected) byte, scritti \(got)"
        }
    }
}

public struct SMCValue {
    public let key: String
    public let type: String
    public let bytes: [UInt8]

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
}

/// Accesso minimo all'SMC tramite la user client di AppleSMC.
/// La struttura scambiata col kernel è SMCKeyData_t (80 byte): la gestiamo come buffer
/// a offset fissi invece che con una struct Swift, così il layout non dipende dal padding del compilatore.
public final class SMC {
    // Offset dentro SMCKeyData_t
    private enum Offset {
        static let key = 0
        static let keyInfoSize = 28
        static let keyInfoType = 32
        static let result = 40
        static let command = 42
        static let index = 44
        static let bytes = 48
    }

    private enum Command: UInt8 {
        case readBytes = 5
        case writeBytes = 6
        case readKeyInfo = 9
        case readIndex = 8
    }

    private static let structSize = 80
    private static let kernelIndex: UInt32 = 2
    private static let resultKeyNotFound: UInt8 = 0x84

    private var connection: io_connect_t = 0

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == KERN_SUCCESS else { throw SMCError.openFailed(kr) }
    }

    deinit {
        IOServiceClose(connection)
    }

    public func read(_ key: String) throws -> SMCValue {
        let (size, type) = try keyInfo(key)
        var input = [UInt8](repeating: 0, count: Self.structSize)
        put(fourCC(key), at: Offset.key, in: &input)
        put(size, at: Offset.keyInfoSize, in: &input)
        input[Offset.command] = Command.readBytes.rawValue
        let output = try call(input, key: key)
        let bytes = Array(output[Offset.bytes..<(Offset.bytes + Int(size))])
        return SMCValue(key: key, type: string(fromFourCC: type), bytes: bytes)
    }

    /// Nomi di tutte le chiavi SMC, nell'ordine dell'indice (la chiave #KEY ne contiene il numero).
    public func allKeys() throws -> [String] {
        let count = try read("#KEY").bytes.reduce(0) { ($0 << 8) | Int($1) }
        var names: [String] = []
        for index in 0..<count {
            var input = [UInt8](repeating: 0, count: Self.structSize)
            input[Offset.command] = Command.readIndex.rawValue
            put(UInt32(index), at: Offset.index, in: &input)
            guard let output = try? call(input, key: "#\(index)") else { continue }
            names.append(string(fromFourCC: get(at: Offset.key, in: output)))
        }
        return names
    }

    public func exists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    /// Scrive i byte grezzi; la dimensione deve coincidere con quella dichiarata dall'SMC per la chiave.
    public func write(_ key: String, bytes: [UInt8]) throws {
        let (size, _) = try keyInfo(key)
        guard Int(size) == bytes.count else {
            throw SMCError.sizeMismatch(key, expected: Int(size), got: bytes.count)
        }
        var input = [UInt8](repeating: 0, count: Self.structSize)
        put(fourCC(key), at: Offset.key, in: &input)
        put(size, at: Offset.keyInfoSize, in: &input)
        input[Offset.command] = Command.writeBytes.rawValue
        for (index, byte) in bytes.enumerated() {
            input[Offset.bytes + index] = byte
        }
        _ = try call(input, key: key)
    }

    private func keyInfo(_ key: String) throws -> (size: UInt32, type: UInt32) {
        var input = [UInt8](repeating: 0, count: Self.structSize)
        put(fourCC(key), at: Offset.key, in: &input)
        input[Offset.command] = Command.readKeyInfo.rawValue
        let output = try call(input, key: key)
        return (get(at: Offset.keyInfoSize, in: output), get(at: Offset.keyInfoType, in: output))
    }

    private func call(_ input: [UInt8], key: String) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let kr = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(
                    connection, Self.kernelIndex,
                    inPtr.baseAddress, Self.structSize,
                    outPtr.baseAddress, &outputSize
                )
            }
        }
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr) }
        let result = output[Offset.result]
        if result == Self.resultKeyNotFound { throw SMCError.keyNotFound(key) }
        guard result == 0 else { throw SMCError.smcResult(key, result) }
        return output
    }

    // I campi UInt32 della struct sono in ordine nativo (little-endian su arm64)
    private func put(_ value: UInt32, at offset: Int, in buffer: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { raw in
            for index in 0..<4 { buffer[offset + index] = raw[index] }
        }
    }

    private func get(at offset: Int, in buffer: [UInt8]) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(buffer[offset + index]) << (8 * index) }
        return value
    }

    private func fourCC(_ key: String) -> UInt32 {
        key.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func string(fromFourCC value: UInt32) -> String {
        let chars = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        return String(decoding: chars, as: UTF8.self)
    }
}
