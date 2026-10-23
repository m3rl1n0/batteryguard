import Foundation
import SMCKit

let hysteresis = 2
// Ciclo breve: la soglia cambiata dall'app viene applicata entro pochi secondi
let pollInterval: TimeInterval = 5
let probeKeys = ["CHTE", "CH0B", "CH0C", "BCLM", "CHIE", "CH0I", "CH0J", "BUIC", "B0RM"]

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("errore: \(message)\n".utf8))
    exit(1)
}

func requireRoot() {
    if geteuid() != 0 { fail("serve root (sudo)") }
}

/// Il file è scrivibile dall'utente: un valore illeggibile o fuori range (anche una scrittura
/// a metà letta nel momento sbagliato) non deve mai cambiare la soglia, si tiene l'ultima valida.
var lastValidLimit = LimitConfig.defaultLimit

func readLimit() -> Int {
    if let value = LimitConfig.read() {
        if value != lastValidLimit { log("soglia aggiornata: \(value)%") }
        lastValidLimit = value
    }
    return lastValidLimit
}

// Battito per l'app: stato, schema e ultimo errore, riscritto a ogni ciclo
var currentScheme: String?
var lastError: String?
var statusWriteFailed = false

func recordError(_ message: String) {
    log(message)
    lastError = message
}

/// Scrittura atomica (file temporaneo + rename) nella cartella di root: l'app non legge mai un file a metà.
func writeStatus(_ state: ServiceStatus.State) {
    let status = ServiceStatus(updated: Date(), state: state, scheme: currentScheme, error: lastError)
    do {
        try Data(status.serialize().utf8).write(to: URL(fileURLWithPath: ServiceStatus.path), options: .atomic)
        chmod(ServiceStatus.path, 0o644)
        if statusWriteFailed { log("battito di nuovo scritto") }
        statusWriteFailed = false
    } catch {
        // Una riga sola, non una ogni 5 secondi
        if !statusWriteFailed { log("battito non scritto: \(error.localizedDescription)") }
        statusWriteFailed = true
    }
}

func makeControl() -> ChargingControl {
    do { return try ChargingControl() } catch { fail("\(error)") }
}

func probe() {
    let smc: SMC
    do { smc = try SMC() } catch { fail("\(error)") }
    for key in probeKeys {
        do {
            let value = try smc.read(key)
            print("\(key)  tipo=\(value.type)  byte=\(value.bytes.count)  valore=\(value.hex)")
        } catch {
            print("\(key)  \(error)")
        }
    }
}

func status() {
    let control = makeControl()
    let limit = LimitConfig.read() ?? LimitConfig.defaultLimit
    print("schema SMC:        \(control.scheme.rawValue)")
    if let enabled = try? control.isChargingEnabled() {
        print("ricarica SMC:      \(enabled ? "abilitata" : "bloccata")")
    }
    print("soglia:            \(limit)% (riprende a \(limit - hysteresis)%)")
    if let battery = Battery.read() {
        print("batteria:          \(battery.percent)%")
        print("alimentatore:      \(battery.externalConnected ? "collegato" : "scollegato")")
        print("in carica:         \(battery.isCharging ? "sì" : "no")")
    }
}

func setCharging(_ enabled: Bool) {
    requireRoot()
    let control = makeControl()
    do { try control.setChargingEnabled(enabled) } catch { fail("\(error)") }
    print("ricarica \(enabled ? "abilitata" : "bloccata") (\(control.scheme.rawValue))")
}

func tick(_ control: ChargingControl) {
    defer { writeStatus(.running) }
    guard let battery = Battery.read() else { return recordError("batteria non leggibile") }
    let limit = readLimit()
    do {
        let enabled = try control.isChargingEnabled()
        if limit >= 100 {
            if !enabled {
                try control.setChargingEnabled(true)
                log("soglia 100%: ricarica riabilitata")
            }
        } else if enabled && battery.percent >= limit {
            try control.setChargingEnabled(false)
            log("batteria \(battery.percent)% >= \(limit)%: ricarica bloccata")
        } else if !enabled && battery.percent <= limit - hysteresis {
            try control.setChargingEnabled(true)
            log("batteria \(battery.percent)% <= \(limit - hysteresis)%: ricarica ripresa")
        }
    } catch {
        recordError("errore SMC: \(error)")
    }
}

func runDaemon() -> Never {
    requireRoot()
    let control: ChargingControl
    do {
        control = try ChargingControl()
    } catch {
        // launchd lo rilancia: il motivo resta nel log e nel battito, così l'app lo può mostrare
        recordError("avvio non riuscito: \(error)")
        writeStatus(.failed)
        exit(1)
    }
    currentScheme = control.scheme.rawValue
    lastValidLimit = LimitConfig.read() ?? LimitConfig.defaultLimit
    log("avvio, schema \(control.scheme.rawValue), soglia \(lastValidLimit)%")

    // Sicurezza: qualunque uscita pulita (launchctl bootout, kill) riabilita la ricarica
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            try? control.setChargingEnabled(true)
            log("segnale \(sig): ricarica riabilitata, uscita")
            writeStatus(.stopped)
            exit(0)
        }
        source.resume()
        sources.append(source)
    }

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: pollInterval)
    timer.setEventHandler { tick(control) }
    timer.resume()

    withExtendedLifetime((sources, timer)) { dispatchMain() }
}

let usage = """
uso: batteryguard-helper <comando>
  probe              legge le chiavi SMC di ricarica (non serve root)
  status             stato batteria, ricarica e soglia
  daemon             ciclo di controllo (root, lanciato da launchd)
  enable-charging    riabilita la ricarica (root)
  disable-charging   blocca la ricarica (root, solo per test)
"""

switch CommandLine.arguments.dropFirst().first {
case "probe": probe()
case "status": status()
case "daemon": runDaemon()
case "enable-charging": setCharging(true)
case "disable-charging": setCharging(false)
default:
    print(usage)
    exit(2)
}
