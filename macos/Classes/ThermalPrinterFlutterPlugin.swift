import FlutterMacOS
import AppKit
import CoreBluetooth

/// Main Flutter plugin class for macOS.
///
/// Handles Bluetooth (BLE) printing and delegates USB printing to `CupsPrinter`.
public class ThermalPrinterFlutterPlugin: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, FlutterPlugin {

    // MARK: - State

    private var centralManager: CBCentralManager?
    private var discoveredDevices: [String] = []
    /// Optional — force-unwrap removed (task 5).
    private var connectedPeripheral: CBPeripheral?
    private var targetService: CBService?
    private var targetCharacteristic: CBCharacteristic?

    /// Pending result for `.withResponse` BLE writes; cleared after first use.
    private var writebytesResult: FlutterResult?
    /// Number of `.withResponse` chunks still awaiting confirmation.
    private var pendingWriteChunks: Int = 0

    // UUIDs for thermal printers
    private let printerServiceUUID = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
    private let printerCharacteristicUUID = CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616")

    // MARK: - FlutterPlugin

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "thermal_printer_flutter", binaryMessenger: registrar.messenger)
        let instance = ThermalPrinterFlutterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }

        switch call.method {

        case "getPlatformVersion":
            let v = ProcessInfo.processInfo.operatingSystemVersion
            result("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")

        case "isBluetoothEnabled":
            result(centralManager?.state == .poweredOn)

        case "checkBluetoothPermissions":
            result(true)

        case "enableBluetooth":
            result(false)

        case "pairedbluetooths":
            handlePairedBluetooths(result: result)

        case "usbprinters":
            result(CupsPrinter.listPrinters())

        case "getPrinterStatus":
            handleGetPrinterStatus(call: call, result: result)

        case "connect":
            handleConnect(call: call, result: result)

        case "isConnected":
            result(connectedPeripheral?.state == .connected)

        case "disconnect":
            handleDisconnect(result: result)

        case "writebytes":
            handleWritebytes(call: call, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Method Handlers

    /// Returns the CUPS state of a USB/spooler printer. Dart only calls this
    /// for USB printers; Bluetooth/network return `PrinterStatus.unknown`.
    private func handleGetPrinterStatus(call: FlutterMethodCall, result: @escaping FlutterResult) {
        var printerName = ""
        if let args = call.arguments as? [String: Any], let name = args["printerName"] as? String {
            printerName = name
        } else if let name = call.arguments as? String {
            printerName = name
        }
        result(CupsPrinter.status(forPrinter: printerName))
    }

    private func handlePairedBluetooths(result: @escaping FlutterResult) {
        discoveredDevices.removeAll()
        centralManager?.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            self.centralManager?.stopScan()
            result(self.buildBluetoothDeviceList(from: self.discoveredDevices))
        }
    }

    private func handleConnect(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let bleAddress = call.arguments as? String,
              let uuid = UUID(uuidString: bleAddress) else {
            result(false)
            return
        }

        let peripherals = centralManager?.retrievePeripherals(withIdentifiers: [uuid])
        guard let peripheral = peripherals?.first else {
            result(false)
            return
        }

        centralManager?.connect(peripheral, options: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            if peripheral.state == .connected {
                self.connectedPeripheral = peripheral
                peripheral.delegate = self
                peripheral.discoverServices(nil)
                result(true)
            } else {
                result(false)
            }
        }
    }

    private func handleDisconnect(result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripheral else {
            result(false)
            return
        }
        centralManager?.cancelPeripheralConnection(peripheral)
        targetCharacteristic = nil
        result(true)
    }

    /// Handles `writebytes`.
    ///
    /// - USB path: argument is `Map { "bytes": Uint8List, "printerName": String }`.
    ///   Delegates to `CupsPrinter` and responds once synchronously.
    /// - BLE path: argument is `Uint8List` (FlutterStandardTypedData) or legacy
    ///   `[NSNumber]`. For `.withResponse` characteristics, the result is deferred
    ///   until all chunk confirmations arrive from the delegate.
    private func handleWritebytes(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // USB path
        if let args = call.arguments as? [String: Any],
           let printerName = args["printerName"] as? String {
            let data = Self.dataFromBytesArgument(args["bytes"])
            guard !data.isEmpty else {
                result(false)
                return
            }
            do {
                try CupsPrinter.printRawData(data, toPrinter: printerName)
                result(true)
            } catch {
                NSLog("[ThermalPrinter] USB/CUPS print failed: %@", error.localizedDescription)
                result(false)
            }
            return
        }

        // BLE path
        guard let characteristic = targetCharacteristic else {
            result(false)
            return
        }

        let data = Self.dataFromBytesArgument(call.arguments)
        guard !data.isEmpty else {
            result(false)
            return
        }

        let useResponse = characteristic.properties.contains(.write)
        if useResponse {
            writebytesResult = result
            pendingWriteChunks = 0
            writeChunked(data: data, characteristic: characteristic, useResponse: true)
        } else {
            writeChunked(data: data, characteristic: characteristic, useResponse: false)
            result(true)
        }
    }

    // MARK: - Helpers

    /// Chunks `data` into 512-byte pieces and writes each to `characteristic`.
    private func writeChunked(data: Data, characteristic: CBCharacteristic, useResponse: Bool) {
        let chunkSize = 512
        let writeType: CBCharacteristicWriteType = useResponse ? .withResponse : .withoutResponse
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]
            if useResponse { pendingWriteChunks += 1 }
            connectedPeripheral?.writeValue(chunk, for: characteristic, type: writeType)
            offset = end
            if !useResponse {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    /// Decodes the `bytes` argument received over the method channel into `Data`.
    ///
    /// Dart sends `Uint8List` as `FlutterStandardTypedData`; legacy callers may
    /// send a plain `List<int>` decoded as `[NSNumber]`.
    static func dataFromBytesArgument(_ argument: Any?) -> Data {
        if let typed = argument as? FlutterStandardTypedData {
            return typed.data
        }
        if let numbers = argument as? [NSNumber] {
            return Data(numbers.map { $0.uint8Value })
        }
        if let ints = argument as? [Int] {
            return Data(ints.map { UInt8(truncatingIfNeeded: $0) })
        }
        return Data()
    }

    /// Maps "Name#UUID" strings to Dart-compatible printer maps.
    private func buildBluetoothDeviceList(from devices: [String]) -> [[String: Any]] {
        return devices.compactMap { deviceString in
            let components = deviceString.split(separator: "#")
            guard components.count >= 2 else { return nil }
            return [
                "name": String(components[0]),
                "bleAddress": String(components[1]),
                "type": "bluetooth",
                "isConnected": false
            ]
        }
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // State is read on demand.
    }

    public func centralManager(_ central: CBCentralManager,
                                didDiscover peripheral: CBPeripheral,
                                advertisementData: [String: Any],
                                rssi RSSI: NSNumber) {
        guard let name = peripheral.name else { return }
        let device = "\(name)#\(peripheral.identifier.uuidString)"
        if !discoveredDevices.contains(device) {
            discoveredDevices.append(device)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Handled by the asyncAfter in handleConnect.
    }

    public func centralManager(_ central: CBCentralManager,
                                didFailToConnect peripheral: CBPeripheral,
                                error: Error?) {
        // handleConnect asyncAfter will respond with false on timeout.
    }

    public func centralManager(_ central: CBCentralManager,
                                didDisconnectPeripheral peripheral: CBPeripheral,
                                error: Error?) {
        // Disconnect was already answered in handleDisconnect.
        connectedPeripheral = nil
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                            didDiscoverCharacteristicsFor service: CBService,
                            error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        let possibleUUIDs: Set<String> = [
            "49535343-1E4D-4BD9-BA61-23C647249616",
            "49535343-ACA3-481C-91EC-D85E28A60318",
            "49535343-8841-43F4-A8D4-ECBE34729BB3"
        ]
        for characteristic in characteristics where possibleUUIDs.contains(characteristic.uuid.uuidString) {
            targetCharacteristic = characteristic
        }
    }

    /// Called only for `.withResponse` writes.
    ///
    /// Counts down `pendingWriteChunks` and fires `writebytesResult` exactly once
    /// when all chunks are acknowledged or on first error.
    public func peripheral(_ peripheral: CBPeripheral,
                            didWriteValueFor characteristic: CBCharacteristic,
                            error: Error?) {
        guard pendingWriteChunks > 0 else { return }

        if let error = error {
            NSLog("[ThermalPrinter] BLE write error: %@", error.localizedDescription)
            let pending = writebytesResult
            writebytesResult = nil
            pendingWriteChunks = 0
            pending?(false)
            return
        }

        pendingWriteChunks -= 1
        if pendingWriteChunks == 0 {
            let pending = writebytesResult
            writebytesResult = nil
            pending?(true)
        }
    }
}
