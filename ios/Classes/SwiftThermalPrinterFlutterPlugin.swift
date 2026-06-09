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
    /// Pending result for the in-flight BLE write; cleared after first use.
    private var writebytesResult: FlutterResult?
    /// Payload still to be written for the in-flight BLE write.
    private var pendingWriteData: Data?
    /// Offset into `pendingWriteData` already handed to CoreBluetooth.
    private var pendingWriteOffset: Int = 0
    /// `true` when the in-flight write uses `.withResponse` (ack-paced),
    /// `false` for `.withoutResponse` (flow-controlled via `canSendWriteWithoutResponse`).
    private var pendingUseResponse: Bool = false
    /// Breathing room between acked `.withResponse` chunks (caminho fallback).
    private let interChunkDelay: TimeInterval = 0.01
    /// Bytes `.withoutResponse` já enviados desde a última pausa de buffer.
    private var bytesSinceBufferPause: Int = 0
    /// `true` enquanto esperamos o ACK do "flush barrier" (último chunk de um job
    /// `.withoutResponse` enviado como `.withResponse`). Ver MARK abaixo.
    private var pendingFlushAck: Bool = false

    // MARK: - Pacing de imagem BLE
    //
    // TRÊS modos de falha ao imprimir via BLE (vazão x velocidade do printer):
    //   • TYPEWRITER (lento, imprime-para-imprime) = cabeça "passa fome": dados
    //     chegam mais devagar do que ela imprime. Causa: `.withResponse` espera
    //     ACK round-trip por chunk (~30ms = 1 connection interval BLE).
    //   • TRUNCA (imagem longa sai pela metade) = dados rápidos demais estouram o
    //     buffer RX de printers baratos.
    //   • TRAVA (texto longo/imagem não sai, texto curto sai) = mandar UM chunk e
    //     esperar `peripheralIsReady` — esse callback só dispara quando `canSend`
    //     vai de false→true; se a fila não encheu, ele nunca vem e o stream para
    //     no 1º chunk.
    //
    // Solução robusta (padrão documentado pela Apple), sem travar:
    //   1. Preferir `.withoutResponse` (mata o typewriter).
    //   2. Loop `while canSendWriteWithoutResponse`: manda chunks (tamanho do MTU)
    //      enquanto a fila aceita; PARA só quando `canSend` vira false, condição
    //      que GARANTE que `peripheralIsReady` vai disparar pra retomar → nunca trava.
    //   3. Pausa só na FRONTEIRA do buffer (a cada `bufferFlushBytes`, espera
    //      `bufferFlushDelay`) p/ o buffer RX drenar → anti-trunca. É grossa (não
    //      por chunk), então não causa picote.
    //   4. FLUSH BARRIER no fim do job: o último chunk vai como `.withResponse`.
    //      `.withoutResponse` só ENFILEIRA — `writebytes` retornaria antes de a
    //      impressora receber os dados, e o PRÓXIMO print (ex.: imagem logo após
    //      um texto longo) empilharia bytes num stream ainda não entregue →
    //      estoura o buffer no boundary e a impressora BUGA. Pela ordem do ATT, o
    //      ACK do último chunk `.withResponse` só chega após TODOS os
    //      `.withoutResponse` anteriores; só então o job completa. Custa 1 RTT por
    //      job (não por chunk), então não traz o typewriter de volta. Se a
    //      característica não tiver `.write`, caímos num drain por tempo.
    // Ajuste por hardware: PICOTANDO → +`bufferFlushBytes` / -`bufferFlushDelay`;
    // TRUNCANDO → -`bufferFlushBytes` / +`bufferFlushDelay`.
    private let bufferFlushBytes: Int = 4096
    private let bufferFlushDelay: TimeInterval = 0.020

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
        // Fail any write left in flight so its deferred result isn't leaked,
        // which would block future writes via the in-flight guard.
        if writebytesResult != nil {
            finishPendingWrite(success: false)
        }
        result(true)
    }

    /// Handles BLE `writebytes`.
    ///
    /// Accepts `FlutterStandardTypedData` (Uint8List from Dart) with a
    /// fallback to `[NSNumber]` / `[UInt8]` for legacy callers. Streams the
    /// payload via `pumpPendingWrite` and responds exactly once when the whole
    /// payload is flushed (or on error/disconnect).
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

        // Refuse to start a new write while one is still in flight — the
        // delegate callbacks below assume a single outstanding payload.
        guard writebytesResult == nil else {
            result(false)
            return
        }

        // Preferir `.withoutResponse` (mata o typewriter); `.withResponse` é só
        // fallback para o printer raro que não anuncia `.writeWithoutResponse`.
        writebytesResult = result
        pendingWriteData = data
        pendingWriteOffset = 0
        bytesSinceBufferPause = 0
        pendingFlushAck = false
        pendingUseResponse = !characteristic.properties.contains(.writeWithoutResponse)
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
            // subdata(in:) copies into a zero-based Data; a bare `data[range]`
            // slice keeps the parent's indices and is mis-sent by CoreBluetooth
            // (corrupting chunks after the first). Matches the PR's `Array(...)`.
            let chunk = data.subdata(in: pendingWriteOffset..<end)
            pendingWriteOffset = end
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
        } else {
            // `.withoutResponse`: pump enquanto a fila de TX aceitar; PARA só
            // quando `canSend` vira false (garante o peripheralIsReady → não trava).
            let canFlushWithResponse = characteristic.properties.contains(.write)
            while pendingWriteOffset < data.count {
                guard peripheral.canSendWriteWithoutResponse else {
                    // Wait for peripheralIsReady(toSendWriteWithoutResponse:).
                    return
                }
                let end = min(pendingWriteOffset + maxLen, data.count)
                // subdata(in:) copies into a zero-based Data; a bare `data[range]`
                // slice keeps the parent's indices and is mis-sent by CoreBluetooth
                // (corrupting chunks after the first). Matches the PR's `Array(...)`.
                let chunk = data.subdata(in: pendingWriteOffset..<end)
                pendingWriteOffset = end
                bytesSinceBufferPause += chunk.count
                let isLast = pendingWriteOffset >= data.count

                // Flush barrier: último chunk vai como `.withResponse` para o job
                // só completar quando a impressora confirmar o recebimento de tudo
                // (em didWriteValueFor) — assim o próximo print não empilha bytes
                // num stream ainda não entregue (boundary texto→imagem que bugava).
                if isLast && canFlushWithResponse {
                    pendingFlushAck = true
                    peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
                    return
                }

                peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)

                // Último chunk mas sem `.write` p/ ACK: não dá pra confirmar
                // recebimento; espera um drain antes de completar o job.
                if isLast {
                    DispatchQueue.main.asyncAfter(deadline: .now() + bufferFlushDelay) { [weak self] in
                        self?.finishPendingWrite(success: true)
                    }
                    return
                }

                // Fronteira do buffer: pausa p/ o buffer RX do printer drenar
                // (anti-trunca) antes de continuar. Grossa → não picota.
                if bytesSinceBufferPause >= bufferFlushBytes {
                    bytesSinceBufferPause = 0
                    DispatchQueue.main.asyncAfter(deadline: .now() + bufferFlushDelay) { [weak self] in
                        self?.pumpPendingWrite()
                    }
                    return
                }
            }
            // Inalcançável com data não-vazio (o ramo isLast sempre retorna), mas
            // mantém o método total para data vazio.
            finishPendingWrite(success: true)
        }
    }

    /// Fires the deferred `writebytes` result exactly once and clears write state.
    private func finishPendingWrite(success: Bool) {
        let pending = writebytesResult
        writebytesResult = nil
        pendingWriteData = nil
        pendingWriteOffset = 0
        pendingFlushAck = false
        pending?(success)
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

    /// Chamado para writes `.withResponse`: tanto o caminho fallback (ack por
    /// chunk) quanto o ACK do flush barrier (último chunk de um job `.withoutResponse`).
    public func peripheral(_ peripheral: CBPeripheral,
                            didWriteValueFor characteristic: CBCharacteristic,
                            error: Error?) {
        guard writebytesResult != nil else { return }

        if let error = error {
            NSLog("[ThermalPrinter] BLE write error: %@", error.localizedDescription)
            finishPendingWrite(success: false)
            return
        }

        // Flush barrier: a impressora confirmou o recebimento de todo o job.
        // Só agora completamos, para o próximo print não empilhar dados.
        if pendingFlushAck {
            finishPendingWrite(success: true)
            return
        }

        // Caminho fallback `.withResponse`: ack-paced, manda o próximo chunk.
        guard pendingUseResponse else { return }
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
