import Foundation
import CoreBluetooth
import Combine

/// Live hartslag van elk toestel dat het standaard Bluetooth Heart Rate Profile (0x180D)
/// uitzendt: veel Garmin-, Polar-, Coros-, Wahoo-, Amazfit-watches en borstbanden
/// (in de watch vaak "hartslag uitzenden" / "broadcast HR" aanzetten).
final class BluetoothHeartRateProvider: NSObject, WearableProvider {
    let name = "Bluetooth-hartslag"
    let capabilities: WearableCapabilities = [.heartRate]
    private let subject = PassthroughSubject<WearableEvent, Never>()
    var events: AnyPublisher<WearableEvent, Never> { subject.eraseToAnyPublisher() }
    private(set) var isAvailable = false
    private(set) var connectedName: String?

    private static let hrService = CBUUID(string: "180D")
    private static let hrMeasurement = CBUUID(string: "2A37")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var wantsScan = false

    func startSession(id: UUID, settings: WatchSettings) {
        wantsScan = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil,
                                       options: [CBCentralManagerOptionRestoreIdentifierKey: "be.snoredle.ble"])
        } else { scan() }
    }

    func stopSession(id: UUID) {
        wantsScan = false
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
    }

    private func scan() {
        guard let c = central, c.state == .poweredOn, wantsScan else { return }
        // Eerst al verbonden toestellen (bv. watch gekoppeld aan iPhone) proberen.
        if let known = c.retrieveConnectedPeripherals(withServices: [Self.hrService]).first {
            connect(known)
        } else {
            c.scanForPeripherals(withServices: [Self.hrService])
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central?.stopScan()
        central?.connect(p)
    }

    /// Bluetooth SIG Heart Rate Measurement-formaat.
    static func parse(_ data: Data) -> Double? {
        guard let flags = data.first else { return nil }
        if flags & 0x01 == 0 { return data.count > 1 ? Double(data[1]) : nil }
        guard data.count > 2 else { return nil }
        return Double(UInt16(data[1]) | UInt16(data[2]) << 8)
    }
}

extension BluetoothHeartRateProvider: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) { scan() }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {}
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) { connect(p) }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        isAvailable = true; connectedName = p.name
        p.discoverServices([Self.hrService])
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        isAvailable = false
        if wantsScan { central.connect(p) }     // automatisch opnieuw verbinden
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        p.services?.forEach { p.discoverCharacteristics([Self.hrMeasurement], for: $0) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        s.characteristics?.filter { $0.uuid == Self.hrMeasurement }.forEach { p.setNotifyValue(true, for: $0) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let d = c.value, let bpm = Self.parse(d), bpm > 0 else { return }
        subject.send(.vital(.heartRate, bpm, .now))
    }
}
