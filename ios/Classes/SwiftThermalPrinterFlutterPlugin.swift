import Flutter
import UIKit
import CoreBluetooth

/// Main Flutter plugin class for iOS.
///
/// Registered by the ObjC shim (`ThermalPrinterFlutterPlugin.m`) which
/// delegates `+registerWithRegistrar:` to this class.
public class SwiftThermalPrinterFlutterPlugin: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, FlutterPlugin {

    // MARK: - State

    private var centralManager: CBCentralManager?
    private var discoveredDevices: [String] = []
    /// Optional — force-unwrap removed (task 5).
    private var connectedPeripheral: CBPeripheral?
    private var targetService: CBService?
    private var targetCharacteristic: CBCharacteristic?

    /// Pending result for the `connect` call only (set once, cleared after use).
    private var connectResult: FlutterResult?
    /// Pending result for the `writebytes` call when using .withResponse writes.
    private var writebytesResult: FlutterResult?
    /// Remaining chunks that still need a didWriteValueFor confirmation.
    private var pendingWriteChunks: Int = 0

    // UUIDs for thermal printers
    private let printerServiceUUID = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
    private let printerCharacteristicUUID = CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616")

    // MARK: - FlutterPlugin

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "thermal_printer_flutter", binaryMessenger: registrar.messenger())
        let instance = SwiftThermalPrinterFlutterPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }

        switch call.method {

        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)

        case "isBluetoothEnabled":
            result(centralManager?.state == .poweredOn)

        case "checkBluetoothPermissions":
            result(centralManager?.state == .poweredOn)

        case "enableBluetooth":
            result(false)

        case "pairedbluetooths":
            // Dart's Bluetooth repository lists printers via `pairedbluetooths`.
            // On iOS there are no "paired" BLE devices, so we run a short scan.
            scanForBluetoothPrinters(result: result)

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

    /// Scans for nearby BLE peripherals for ~5s and returns them as printer maps.
    private func scanForBluetoothPrinters(result: @escaping FlutterResult) {
        discoveredDevices.removeAll()
        centralManager?.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self else { return }
            self.centralManager?.stopScan()
            let printers = self.buildBluetoothDeviceList(from: self.discoveredDevices)
            result(printers)
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            if peripheral.state == .connected {
                self.connectedPeripheral = peripheral
                peripheral.delegate = self
                peripheral.discoverServices([self.printerServiceUUID])
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

    /// Handles BLE `writebytes`.
    ///
    /// Accepts `FlutterStandardTypedData` (Uint8List from Dart) with a
    /// fallback to `[NSNumber]` / `[UInt8]` for legacy callers.
    /// Responds exactly once via `result` — the delegate callback
    /// (`didWriteValueFor`) is only used for `.withResponse` writes.
    private func handleWritebytes(call: FlutterMethodCall, result: @escaping FlutterResult) {
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
            // For .withResponse writes we must wait for the delegate before
            // answering Flutter — store the result and count pending chunks.
            writebytesResult = result
            pendingWriteChunks = 0
            writeChunked(data: data, characteristic: characteristic, useResponse: true)
        } else {
            // .withoutResponse: fire-and-forget, respond immediately.
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

    /// Decodes the bytes argument from the method channel into `Data`.
    ///
    /// Dart sends `Uint8List` as `FlutterStandardTypedData`; older callers may
    /// send a plain `List<int>` decoded as `[NSNumber]`.
    private static func dataFromBytesArgument(_ argument: Any?) -> Data {
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

    /// Maps a list of "Name#UUID" strings to Dart-compatible printer maps.
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
        // No action needed; state is read on demand.
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
        // Connection confirmed — handled by the asyncAfter in handleConnect.
    }

    public func centralManager(_ central: CBCentralManager,
                                didFailToConnect peripheral: CBPeripheral,
                                error: Error?) {
        // connectResult is consumed by the asyncAfter timeout in handleConnect;
        // nothing extra to do here (avoids double-result).
    }

    public func centralManager(_ central: CBCentralManager,
                                didDisconnectPeripheral peripheral: CBPeripheral,
                                error: Error?) {
        // Disconnect is fire-and-forget from handleDisconnect which already responded.
        connectedPeripheral = nil
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services where service.uuid == printerServiceUUID {
            targetService = service
            peripheral.discoverCharacteristics([printerCharacteristicUUID], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                            didDiscoverCharacteristicsFor service: CBService,
                            error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == printerCharacteristicUUID {
            targetCharacteristic = characteristic
        }
    }

    /// Called only for `.withResponse` writes.
    ///
    /// We count down `pendingWriteChunks` and fire `writebytesResult` exactly
    /// once when all chunks have been acknowledged (or on first error).
    public func peripheral(_ peripheral: CBPeripheral,
                            didWriteValueFor characteristic: CBCharacteristic,
                            error: Error?) {
        guard pendingWriteChunks > 0 else { return }

        if let error = error {
            // Respond once with failure and reset so subsequent confirmations
            // (for already-queued chunks) are silently ignored.
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
