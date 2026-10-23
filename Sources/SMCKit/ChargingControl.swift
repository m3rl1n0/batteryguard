import Foundation

/// Schema di controllo della ricarica: dipende dal firmware SMC del Mac.
/// Valori ricavati studiando batt e Battery Toolkit (documentazione e issue, non il codice).
public enum ChargingScheme: String {
    /// Firmware Apple Silicon recenti (macOS 15+): una chiave a 4 byte
    case chte = "CHTE"
    /// Firmware precedenti e Mac Intel con chip T2: due chiavi a 1 byte che vanno scritte insieme
    case ch0bc = "CH0B+CH0C"

    var keys: [String] {
        switch self {
        case .chte: return ["CHTE"]
        case .ch0bc: return ["CH0B", "CH0C"]
        }
    }

    func bytes(enabled: Bool) -> [UInt8] {
        switch self {
        case .chte: return enabled ? [0x00, 0x00, 0x00, 0x00] : [0x01, 0x00, 0x00, 0x00]
        case .ch0bc: return enabled ? [0x00] : [0x02]
        }
    }
}

public final class ChargingControl {
    public let smc: SMC
    public let scheme: ChargingScheme

    public init() throws {
        let smc = try SMC()
        self.smc = smc
        // CHTE ha la precedenza: sui firmware nuovi CH0B/CH0C possono esistere ma non avere effetto
        if smc.exists("CHTE") {
            scheme = .chte
        } else if smc.exists("CH0B") && smc.exists("CH0C") {
            scheme = .ch0bc
        } else {
            throw SMCError.keyNotFound("CHTE / CH0B / CH0C")
        }
    }

    public func isChargingEnabled() throws -> Bool {
        let value = try smc.read(scheme.keys[0])
        return value.bytes.allSatisfy { $0 == 0 }
    }

    public func setChargingEnabled(_ enabled: Bool) throws {
        let bytes = scheme.bytes(enabled: enabled)
        for key in scheme.keys {
            try smc.write(key, bytes: bytes)
        }
    }
}
