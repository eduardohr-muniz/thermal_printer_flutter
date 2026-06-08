import 'dart:async';
import 'package:flutter/services.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'package:thermal_printer_flutter/src/repositories/bluetooth_printer_repository.dart';
import 'package:thermal_printer_flutter/src/repositories/network_printer_repository.dart';
import 'package:thermal_printer_flutter/src/repositories/usb_printer_repository.dart';
import 'thermal_printer_flutter_platform_interface.dart';

/// An implementation of [ThermalPrinterFlutterPlatform] that uses method channels.
class MethodChannelThermalPrinterFlutter
    implements ThermalPrinterFlutterPlatform {
  /// Cria a implementação baseada em [MethodChannel].
  ///
  /// Os repositórios são seams de testabilidade (opcionais): em produção usam
  /// os defaults reais. O roteamento é uniforme em todas as plataformas
  /// (Android, iOS, macOS, Windows, Linux, Web) — inclusive Bluetooth, que
  /// agora tem implementação nativa também no Windows (RFCOMM/Winsock).
  MethodChannelThermalPrinterFlutter({
    BluetoothPrinterRepository? bluetoothRepository,
    UsbPrinterRepository? usbRepository,
    NetworkPrinterRepository? networkRepository,
  })  : _bluetoothRepository =
            bluetoothRepository ?? BluetoothPrinterRepository(),
        _usbRepository = usbRepository ?? UsbPrinterRepository(),
        _networkRepository = networkRepository ?? NetworkPrinterRepository();

  final MethodChannel _channel = const MethodChannel('thermal_printer_flutter');
  final BluetoothPrinterRepository _bluetoothRepository;
  final UsbPrinterRepository _usbRepository;
  final NetworkPrinterRepository _networkRepository;

  @override
  Future<String?> getPlatformVersion() async {
    return _channel.invokeMethod<String>('getPlatformVersion');
  }

  @override
  Future<bool> checkBluetoothPermissions() async {
    try {
      final bool result =
          await _channel.invokeMethod<bool>('checkBluetoothPermissions') ??
              false;
      return result;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> isBluetoothEnabled() async {
    try {
      final bool result =
          await _channel.invokeMethod<bool>('isBluetoothEnabled') ?? false;
      return result;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> enableBluetooth() async {
    try {
      final bool result =
          await _channel.invokeMethod<bool>('enableBluetooth') ?? false;
      return result;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<List<Printer>> getPrinters({required PrinterType printerType}) async {
    switch (printerType) {
      case PrinterType.usb:
        return _usbRepository.getPrinters();
      case PrinterType.bluetooth:
        return _bluetoothRepository.getPrinters();
      case PrinterType.network:
        return _networkRepository.getPrinters();
    }
  }

  @override
  Future<void> printBytes(
      {required List<int> bytes, required Printer printer}) async {
    switch (printer.type) {
      case PrinterType.usb:
        await _usbRepository.printBytes(bytes: bytes, printer: printer);
        break;
      case PrinterType.bluetooth:
        await _bluetoothRepository.printBytes(bytes: bytes, printer: printer);
        break;
      case PrinterType.network:
        await _networkRepository.printBytes(bytes: bytes, printer: printer);
        break;
    }
  }

  @override
  Future<bool> connect({required Printer printer}) async {
    switch (printer.type) {
      case PrinterType.usb:
        return _usbRepository.connect(printer);
      case PrinterType.bluetooth:
        return _bluetoothRepository.connect(printer);
      case PrinterType.network:
        return _networkRepository.connect(printer);
    }
  }

  @override
  Future<void> disconnect({required Printer printer}) async {
    switch (printer.type) {
      case PrinterType.usb:
        await _usbRepository.disconnect(printer);
        break;
      case PrinterType.bluetooth:
        await _bluetoothRepository.disconnect(printer);
        break;
      case PrinterType.network:
        await _networkRepository.disconnect(printer);
        break;
    }
  }

  @override
  Future<bool> isConnected({required Printer printer}) async {
    switch (printer.type) {
      case PrinterType.bluetooth:
        return _bluetoothRepository.isConnected(printer);
      case PrinterType.usb:
        return _usbRepository.isConnected(printer);
      case PrinterType.network:
        return _networkRepository.isConnected(printer);
    }
  }

  @override
  Future<PrinterStatus> getPrinterStatus({required Printer printer}) async {
    if (printer.type != PrinterType.usb) return PrinterStatus.unknown;

    try {
      final Map<dynamic, dynamic>? response = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getPrinterStatus',
        <String, dynamic>{'printerName': printer.name},
      );
      return PrinterStatus.fromMap(response);
    } catch (_) {
      return PrinterStatus.unknown;
    }
  }

  @override
  Future<void> dispose() async {
    await _networkRepository.dispose();
  }
}
