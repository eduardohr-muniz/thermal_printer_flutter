import 'dart:developer';
import 'package:flutter/services.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'printer_repository.dart';

class UsbPrinterRepository implements PrinterRepository {
  final MethodChannel _channel = const MethodChannel('thermal_printer_flutter');

  @override
  Future<List<Printer>> getPrinters() async {
    try {
      final List<dynamic>? devices =
          await _channel.invokeMethod<List<dynamic>>('usbprinters');
      return devices?.map((device) {
            if (device is Map) {
              return Printer(
                type: PrinterType.usb,
                name: device['name'] ?? '',
                usbAddress: device['usbAddress'] ?? '',
                isConnected: device['isConnected'] ?? false,
              );
            }
            return Printer(
              type: PrinterType.usb,
            );
          }).toList() ??
          [];
    } catch (e) {
      log('Error getting USB printers: $e', name: 'THERMAL_PRINTER_FLUTTER');
      return [];
    }
  }

  @override
  Future<bool> connect(Printer printer) async {
    // USB printers don't need explicit connection
    return true;
  }

  @override
  Future<void> disconnect(Printer printer) async {
    // USB printers don't need explicit disconnection
  }

  @override
  Future<void> printBytes(
      {required List<int> bytes, required Printer printer}) async {
    try {
      final bool result = await _channel.invokeMethod<bool>(
            'writebytes',
            <String, dynamic>{
              'bytes': Uint8List.fromList(bytes),
              'printerName': printer.name,
            },
          ) ??
          false;

      if (!result) {
        log('Failed to print via USB', name: 'THERMAL_PRINTER_FLUTTER');
      }
    } catch (e) {
      log('Error printing via USB: $e', name: 'THERMAL_PRINTER_FLUTTER');
      rethrow;
    }
  }

  @override
  Future<bool> isConnected(Printer printer) async {
    try {
      final bool result = await _channel.invokeMethod<bool>(
            'isConnected',
            printer.usbAddress,
          ) ??
          false;
      return result;
    } catch (e) {
      log('Error checking USB connection: $e', name: 'THERMAL_PRINTER_FLUTTER');
      return false;
    }
  }
}
