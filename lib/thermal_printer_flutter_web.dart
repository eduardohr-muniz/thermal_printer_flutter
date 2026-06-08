// coverage:ignore-file
// Implementação web do plugin. Imprime via WebUSB (navigator.usb) e Web
// Bluetooth/BLE (navigator.bluetooth); rede não é suportada no browser.
// Depende de APIs do navegador que não rodam na VM de teste, por isso é
// excluída da cobertura de testes.
// ignore: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'package:thermal_printer_flutter/src/enums/printer_type.dart';
import 'package:thermal_printer_flutter/src/models/printer.dart';
import 'package:thermal_printer_flutter/src/models/printer_status.dart';
import 'package:thermal_printer_flutter/src/web/web_bluetooth.dart';
import 'package:thermal_printer_flutter/src/web/web_usb.dart';
import 'thermal_printer_flutter_platform_interface.dart';

/// Implementação web do [ThermalPrinterFlutterPlatform].
///
/// Transportes na web: **USB via WebUSB** e **Bluetooth BLE via Web Bluetooth**.
/// Por restrição do browser não é possível varrer dispositivos: [getPrinters]
/// retorna apenas os já autorizados e [requestPrinter] abre o chooser nativo
/// para autorizar um novo. Rede não funciona no browser (retorna vazio).
class ThermalPrinterFlutterWeb extends ThermalPrinterFlutterPlatform {
  /// Constrói a implementação web.
  ThermalPrinterFlutterWeb();

  /// Registro dos `USBDevice` autorizados, indexados por [usbDeviceKey]
  /// (gravado em `Printer.usbAddress`).
  final Map<String, USBDevice> _usbDevices = {};

  /// Registro dos `BluetoothDevice` autorizados, indexados por [bleDeviceKey]
  /// (gravado em `Printer.bleAddress`).
  final Map<String, BluetoothDevice> _bleDevices = {};

  /// Emite quando um dispositivo USB conecta/desconecta (eventos do
  /// `navigator.usb`). Broadcast e lazy: os listeners nativos do navegador só
  /// são registrados quando alguém assina [onWebUsbConnectionChange].
  final StreamController<void> _usbConnChanges =
      StreamController<void>.broadcast();
  JSFunction? _usbConnListener;

  static void registerWith(Registrar registrar) {
    ThermalPrinterFlutterPlatform.instance = ThermalPrinterFlutterWeb();
  }

  @override
  Stream<void> get onWebUsbConnectionChange {
    // Registra os listeners nativos uma única vez (lazy), na 1ª assinatura.
    _usbConnListener ??= registerUsbConnectionListeners(() {
      if (!_usbConnChanges.isClosed) _usbConnChanges.add(null);
    });
    return _usbConnChanges.stream;
  }

  @override
  Future<void> dispose() async {
    removeUsbConnectionListeners(_usbConnListener);
    _usbConnListener = null;
    await _usbConnChanges.close();
    await super.dispose();
  }

  /// Retorna a `userAgent` do navegador.
  @override
  Future<String?> getPlatformVersion() async {
    return web.window.navigator.userAgent;
  }

  // --- Mapeamento device JS <-> Printer ---------------------------------------

  Printer _usbToPrinter(USBDevice device) {
    final key = usbDeviceKey(device);
    _usbDevices[key] = device;
    return Printer(
      type: PrinterType.usb,
      name: usbDeviceName(device),
      usbAddress: key,
      isConnected: device.opened,
    );
  }

  Printer _bleToPrinter(BluetoothDevice device) {
    final key = bleDeviceKey(device);
    _bleDevices[key] = device;
    return Printer(
      type: PrinterType.bluetooth,
      name: bleDeviceName(device),
      bleAddress: key,
      isConnected: bleConnected(device),
    );
  }

  USBDevice? _usbLookup(Printer p) => _usbDevices[p.usbAddress];
  BluetoothDevice? _bleLookup(Printer p) => _bleDevices[p.bleAddress];

  // --- Descoberta -------------------------------------------------------------

  @override
  Future<List<Printer>> getPrinters({required PrinterType printerType}) async {
    switch (printerType) {
      case PrinterType.usb:
        return (await usbGetDevices()).map(_usbToPrinter).toList();
      case PrinterType.bluetooth:
        return (await bleGetDevices()).map(_bleToPrinter).toList();
      case PrinterType.network:
        // Rede crua (TCP 9100) não é possível no browser.
        return [];
    }
  }

  @override
  Future<Printer?> requestPrinter({required PrinterType printerType}) async {
    // Padrão recomendado pela WebUSB/Web Bluetooth: reusa um dispositivo já
    // autorizado (getDevices) e só abre o chooser se nenhum estiver pareado.
    switch (printerType) {
      case PrinterType.usb:
        final device = await usbEnsureDevice();
        return device == null ? null : _usbToPrinter(device);
      case PrinterType.bluetooth:
        final device = await bleEnsureDevice();
        return device == null ? null : _bleToPrinter(device);
      case PrinterType.network:
        return null;
    }
  }

  @override
  Future<bool> isWebUsbSupported() async => webUsbAvailable();

  @override
  Future<bool> isWebBluetoothSupported() async => webBluetoothAvailable();

  // --- Impressão / conexão ----------------------------------------------------

  @override
  Future<void> printBytes(
      {required List<int> bytes, required Printer printer}) async {
    switch (printer.type) {
      case PrinterType.usb:
        final device = _usbLookup(printer);
        if (device == null) {
          throw StateError(
              'Impressora USB não autorizada. Chame requestPrinter() (a partir '
              'de um gesto do usuário) antes de imprimir.');
        }
        await usbPrint(device, bytes);
      case PrinterType.bluetooth:
        final device = _bleLookup(printer);
        if (device == null) {
          throw StateError(
              'Impressora BLE não autorizada. Chame requestPrinter() (a partir '
              'de um gesto do usuário) antes de imprimir.');
        }
        await blePrint(device, bytes);
      case PrinterType.network:
        throw UnsupportedError('Impressão de rede não é suportada na web.');
    }
  }

  @override
  Future<bool> connect({required Printer printer}) async {
    switch (printer.type) {
      case PrinterType.usb:
        final device = _usbLookup(printer);
        return device == null ? false : usbOpen(device);
      case PrinterType.bluetooth:
        final device = _bleLookup(printer);
        return device == null ? false : bleConnect(device);
      case PrinterType.network:
        return false;
    }
  }

  @override
  Future<void> disconnect({required Printer printer}) async {
    switch (printer.type) {
      case PrinterType.usb:
        final device = _usbLookup(printer);
        if (device != null) await usbClose(device);
      case PrinterType.bluetooth:
        final device = _bleLookup(printer);
        if (device != null) bleDisconnect(device);
      case PrinterType.network:
        break;
    }
  }

  @override
  Future<bool> isConnected({required Printer printer}) async {
    switch (printer.type) {
      case PrinterType.usb:
        return _usbLookup(printer)?.opened ?? false;
      case PrinterType.bluetooth:
        final device = _bleLookup(printer);
        return device == null ? false : bleConnected(device);
      case PrinterType.network:
        return false;
    }
  }

  @override
  Future<PrinterStatus> getPrinterStatus({required Printer printer}) async {
    // WebUSB/Web Bluetooth não expõem status de forma padronizada.
    return PrinterStatus.unknown;
  }
}
