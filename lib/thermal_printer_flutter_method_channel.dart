import 'dart:async';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:thermal_printer_flutter/src/helpers/platform.dart';
import 'package:thermal_printer_flutter/src/mobile_ble.dart';
import 'package:thermal_printer_flutter/src/network_printer.dart';
import 'package:thermal_printer_flutter/src/win_ble.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'thermal_printer_flutter_platform_interface.dart';

/// An implementation of [ThermalPrinterFlutterPlatform] that uses method channels.
class MethodChannelThermalPrinterFlutter implements ThermalPrinterFlutterPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('thermal_printer_flutter');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  @override
  Future<List<Printer>> getPrinters({required PrinterType printerType}) async {
    if (printerType == PrinterType.usb) {
      try {
        final List<dynamic>? printers = await methodChannel.invokeMethod<List<dynamic>>('getPrinters');
        final List<String> resultWin = printers?.cast<String>() ?? [];
        return resultWin.map((p) => Printer(type: PrinterType.usb, name: p)).toList();
      } catch (e) {
        log('Error getting USB printers: $e', name: 'THERMAL_PRINTER_FLUTTER');
        return [];
      }
    } else if (printerType == PrinterType.bluethoot) {
      try {
        if (isWindows) {
          return await WinBleManager.instance.scanPrinters();
        } else if (isAndroid || isIOS || isMacOS) {
          return await MobileBleManager.instance.scanPrinters();
        } else {
          _logPlatformNotSuported();
          return [];
        }
      } catch (e) {
        log('Error getting Bluetooth printers: $e', name: 'THERMAL_PRINTER_FLUTTER');
        return [];
      }
    } else if (printerType == PrinterType.network) {
      // For network printers, the user needs to provide IP and port manually
      return [];
    }

    return [];
  }

  @override
  Future<void> printBytes({required List<int> bytes, required Printer printer}) async {
    if (printer.type == PrinterType.usb) {
      try {
        final bool result = await methodChannel.invokeMethod<bool>(
              'printBytes',
              <String, dynamic>{
                'bytes': bytes,
                'printerName': printer.name,
              },
            ) ??
            false;
        if (!result) {
          log('Failed to print bytes', name: 'THERMAL_PRINTER_FLUTTER');
        }
      } catch (e) {
        log('Error printing: $e', name: 'THERMAL_PRINTER_FLUTTER');
        rethrow;
      }
    } else if (printer.type == PrinterType.bluethoot) {
      try {
        if (isWindows) {
          await WinBleManager.instance.printBytes(bytes: bytes, address: printer.bleAddress);
        } else if (isAndroid || isIOS || isMacOS) {
          await MobileBleManager.instance.printBytes(bytes: bytes, address: printer.bleAddress);
        } else {
          _logPlatformNotSuported();
        }
      } catch (e) {
        log('Error printing via Bluetooth: $e', name: 'THERMAL_PRINTER_FLUTTER');
        rethrow;
      }
    } else if (printer.type == PrinterType.network) {
      try {
        final networkPrinter = NetworkPrinter(
          host: printer.ip,
          port: int.tryParse(printer.port) ?? 9100,
        );
        final success = await networkPrinter.printBytes(bytes);
        if (!success) {
          log('Failed to print via network', name: 'THERMAL_PRINTER_FLUTTER');
        }
      } catch (e) {
        log('Error printing via network: $e', name: 'THERMAL_PRINTER_FLUTTER');
        rethrow;
      }
    }
  }

  @override
  Future<bool> connect({required Printer printer}) async {
    if (printer.type == PrinterType.bluethoot) {
      if (isWindows) {
        return await WinBleManager.instance.connect(printer.bleAddress);
      } else if (isAndroid || isIOS || isMacOS) {
        return await MobileBleManager.instance.connect(printer);
      } else {
        _logPlatformNotSuported();
        return false;
      }
    } else if (printer.type == PrinterType.network) {
      try {
        final networkPrinter = NetworkPrinter(
          host: printer.ip,
          port: int.tryParse(printer.port) ?? 9100,
        );
        return await networkPrinter.connect();
      } catch (e) {
        log('Error connecting network printer: $e', name: 'THERMAL_PRINTER_FLUTTER');
        return false;
      }
    }
    return false;
  }

  void _logPlatformNotSuported() {
    log('Platform not supported', name: 'THERMAL_PRINTER_FLUTTER');
  }
}
