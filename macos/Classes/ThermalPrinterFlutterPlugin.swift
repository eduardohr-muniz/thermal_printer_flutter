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

    /// Pending result for the in-flight BLE write; cleared after first use.
    private var writebytesResult: FlutterResult?
    /// Payload still to be written for the in-flight BLE write.
    private var pendingWriteData: Data?
    /// Offset into `pendingWriteData` already handed to CoreBluetooth.
    private var pendingWriteOffset: Int = 0
    /// `true` when the in-flight write uses `.withResponse` (ack-paced),
    /// `false` for `.withoutResponse` (flow-controlled via `canSendWriteWithoutResponse`).
    private var pendingUseResponse: Bool = false
    /// Breathing room between acked `.withResponse` chunks — some thermal
    /// printers ack into their RX buffer faster than the head can drain it,
    /// so a small pause avoids overrunning slow hardware mid-print.
    private let interChunkDelay: TimeInterval = 0.01

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
        // Fail any write left in flight so its deferred result isn't leaked,
        // which would block future writes via the in-flight guard.
        if writebytesResult != nil {
            finishPendingWrite(success: false)
        }
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

        // Refuse to start a new write while one is still in flight — the
        // delegate callbacks below assume a single outstanding payload.
        guard writebytesResult == nil else {
            result(false)
            return
        }

        // Prefer `.withResponse` when the characteristic supports it: the
        // printer acks each chunk so we never outrun its buffer. Fall back to
        // `.withoutResponse` (flow-controlled) otherwise.
        writebytesResult = result
        pendingWriteData = data
        pendingWriteOffset = 0
        pendingUseResponse = characteristic.properties.contains(.write)
        pumpPendingWrite()
    }

    // MARK: - Helpers

    /// Streams `pendingWriteData` to the target characteristic.
    ///
    /// Chunk size is bounded by the link's negotiated `maximumWriteValueLength`
    /// — sending larger `.withoutResponse` writes makes CoreBluetooth silently
    /// drop the value, which corrupts the ESC/POS stream and trips the
    /// printer's error LED.
    ///
    /// - `.withResponse`: one chunk is sent here; the next is sent from
    ///   `didWriteValueFor` once the printer acknowledges, pacing the stream.
    /// - `.withoutResponse`: chunks are sent while `canSendWriteWithoutResponse`
    ///   is true; when the TX queue fills we stop and resume from
    ///   `peripheralIsReady(toSendWriteWithoutResponse:)`. No thread is blocked.
    private func pumpPendingWrite() {
        guard let peripheral = connectedPeripheral,
              let characteristic = targetCharacteristic,
              let data = pendingWriteData else {
            return
        }

        let writeType: CBCharacteristicWriteType = pendingUseResponse ? .withResponse : .withoutResponse
        // Clamp to a sane floor in case the link reports an unusable value.
        let maxLen = max(20, peripheral.maximumWriteValueLength(for: writeType))

        if pendingUseResponse {
            guard pendingWriteOffset < data.count else {
                finishPendingWrite(success: true)
                return
            }
            let end = min(pendingWriteOffset + maxLen, data.count)
            let chunk = data[pendingWriteOffset..<end]
            pendingWriteOffset = end
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
        } else {
            while pendingWriteOffset < data.count {
                guard peripheral.canSendWriteWithoutResponse else {
                    // Wait for peripheralIsReady(toSendWriteWithoutResponse:).
                    return
                }
                let end = min(pendingWriteOffset + maxLen, data.count)
                let chunk = data[pendingWriteOffset..<end]
                pendingWriteOffset = end
                peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            }
            finishPendingWrite(success: true)
        }
    }

    /// Fires the deferred `writebytes` result exactly once and clears write state.
    private func finishPendingWrite(success: Bool) {
        let pending = writebytesResult
        writebytesResult = nil
        pendingWriteData = nil
        pendingWriteOffset = 0
        pending?(success)
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
        targetCharacteristic = nil
        // An unexpected drop (e.g. printer powered off mid-print) must release
        // any in-flight write so the Dart side doesn't hang forever.
        if writebytesResult != nil {
            finishPendingWrite(success: false)
        }
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

    /// Called only for `.withResponse` writes. Sends the next chunk once the
    /// printer acknowledges the previous one, or fails the write on first error.
    public func peripheral(_ peripheral: CBPeripheral,
                            didWriteValueFor characteristic: CBCharacteristic,
                            error: Error?) {
        guard pendingUseResponse, writebytesResult != nil else { return }

        if let error = error {
            NSLog("[ThermalPrinter] BLE write error: %@", error.localizedDescription)
            finishPendingWrite(success: false)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + interChunkDelay) { [weak self] in
            self?.pumpPendingWrite()
        }
    }

    /// CoreBluetooth's TX queue drained — resume a `.withoutResponse` stream
    /// that was paused by `canSendWriteWithoutResponse` returning false.
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard !pendingUseResponse, writebytesResult != nil else { return }
        pumpPendingWrite()
    }
}
