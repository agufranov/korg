import CoreBluetooth
import Foundation

let deviceNameFilter = ProcessInfo.processInfo.environment["DEVICE_NAME"]?.lowercased() ?? "nanokey"
let runLoop = RunLoop.current

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func ascii(_ data: Data) -> String {
    String(data.map { byte in
        if byte >= 0x20 && byte <= 0x7e { return Character(UnicodeScalar(byte)) }
        return "."
    })
}

func printData(_ source: String, _ data: Data?) {
    guard let data = data, !data.isEmpty else { return }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    print("[\(timestamp)] \(source)")
    print("  len:   \(data.count)")
    print("  hex:   \(hex(data))")
    print("  ascii: \(ascii(data))")
}

final class BleDumper: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("Bluetooth state: \(central.state.rawValue)")

        guard central.state == .poweredOn else {
            print("Bluetooth is not powered on/ready: \(central.state)")
            return
        }

        print("Scanning for device name containing: \(deviceNameFilter)")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = localName ?? peripheral.name ?? "<no name>"

        guard name.lowercased().contains(deviceNameFilter) else { return }

        print("Found \(name)")
        print("identifier: \(peripheral.identifier.uuidString)")
        print("rssi: \(RSSI)")

        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            print("advertised services: \(services.map { $0.uuidString }.joined(separator: ", "))")
        }

        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            printData("manufacturer data", manufacturerData)
        }

        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected. Discovering services...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
        Foundation.exit(1)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected: \(error?.localizedDescription ?? "no error")")
        Foundation.exit(0)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Service discovery failed: \(error.localizedDescription)")
            Foundation.exit(1)
        }

        let services = peripheral.services ?? []
        print("Services (\(services.count)):")
        for service in services {
            print("  \(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
            return
        }

        let characteristics = service.characteristics ?? []
        print("Characteristics for service \(service.uuid.uuidString) (\(characteristics.count)):")

        for characteristic in characteristics {
            print("  \(characteristic.uuid.uuidString) properties=\(describeProperties(characteristic.properties))")
            peripheral.discoverDescriptors(for: characteristic)

            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }

            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                print("  enabling notify for \(service.uuid.uuidString)/\(characteristic.uuid.uuidString)")
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Descriptor discovery failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }

        for descriptor in characteristic.descriptors ?? [] {
            print("    descriptor \(descriptor.uuid.uuidString) for characteristic \(characteristic.uuid.uuidString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Value update failed for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }

        let serviceUuid = characteristic.service?.uuid.uuidString ?? "<unknown service>"
        printData("value \(serviceUuid)/\(characteristic.uuid.uuidString)", characteristic.value)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let serviceUuid = characteristic.service?.uuid.uuidString ?? "<unknown service>"

        if let error = error {
            print("Notify failed \(serviceUuid)/\(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }

        print("Notify state \(serviceUuid)/\(characteristic.uuid.uuidString): \(characteristic.isNotifying)")
    }

    private func describeProperties(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties) { names.append("extendedProperties") }
        if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
        if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
        return names.isEmpty ? "-" : names.joined(separator: ",")
    }
}

let dumper = BleDumper()
print("CoreBluetooth BLE dump started. Ctrl+C to stop.")

while runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 1)) {}

_ = dumper
