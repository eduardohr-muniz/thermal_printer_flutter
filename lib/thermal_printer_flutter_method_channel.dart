import 'dart:async';
import 'package:flutter/services.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'package:thermal_printer_flutter/src/repositories/bluetooth_printer_repository.dart';
import 'package:thermal_printer_flutter/src/repositories/network_printer_repository.dart';
import 'package:thermal_printer_flutter/src/repositories/usb_printer_repository.dart';
import 'thermal_printer_flutter_platform_interface.dart';

/// An implementation of [ThermalPrinterFlutterPlatform] that uses method channels.
class MethodChannelThermalPrinterFlutter implements ThermalPrinterFlutterPlatform {
  final MethodChannel _channel = const MethodChannel('thermal_printer_flutter');
  final BluetoothPrinterRepository _bluetoothRepository = BluetoothPrinterRepository();
  final UsbPrinterRepository _usbRepository = UsbPrinterRepository();
  final NetworkPrinterRepository _networkRepository = NetworkPrinterRepository();

  @override
  Future<String?> getPlatformVersion() async {
    final version = await _usbRepository.getPrinters();
    return version.isNotEmpty ? version.first.name : null;
  }

  @override
  Future<bool> checkBluetoothPermissions() async {
    try {
      final bool result = await _channel.invokeMethod<bool>('checkBluetoothPermissions') ?? false;
      return result;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> isBluetoothEnabled() async {
    try {
      final bool result = await _channel.invokeMethod<bool>('isBluetoothEnabled') ?? false;
      return result;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> enableBluetooth() async {
    try {
      final bool result = await _channel.invokeMethod<bool>('enableBluetooth') ?? false;
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
      case PrinterType.bluethoot:
        return _bluetoothRepository.getPrinters();
      case PrinterType.network:
        return _networkRepository.getPrinters();
    }
  }

  @override
  Future<void> printBytes({required List<int> bytes, required Printer printer}) async {
    switch (printer.type) {
      case PrinterType.usb:
        await _usbRepository.printBytes(bytes: bytes, printer: printer);
        break;
      case PrinterType.bluethoot:
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
      case PrinterType.bluethoot:
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
      case PrinterType.bluethoot:
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
      case PrinterType.bluethoot:
        return _bluetoothRepository.isConnected(printer);
      case PrinterType.usb:
        return _usbRepository.isConnected(printer);
      case PrinterType.network:
        return _networkRepository.isConnected(printer);
    }
  }
}
