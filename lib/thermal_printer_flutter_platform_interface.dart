import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'thermal_printer_flutter_method_channel.dart';

abstract class ThermalPrinterFlutterPlatform extends PlatformInterface {
  /// Constructs a ThermalPrinterFlutterPlatform.
  ThermalPrinterFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static ThermalPrinterFlutterPlatform _instance = MethodChannelThermalPrinterFlutter();

  /// The default instance of [ThermalPrinterFlutterPlatform] to use.
  ///
  /// Defaults to [MethodChannelThermalPrinterFlutter].
  static ThermalPrinterFlutterPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [ThermalPrinterFlutterPlatform] when
  /// they register themselves.
  static set instance(ThermalPrinterFlutterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  Future<bool> checkBluetoothPermissions() {
    throw UnimplementedError('checkBluetoothPermissions() has not been implemented.');
  }

  Future<bool> isBluetoothEnabled() {
    throw UnimplementedError('isBluetoothEnabled() has not been implemented.');
  }

  Future<bool> enableBluetooth() {
    throw UnimplementedError('enableBluetooth() has not been implemented.');
  }

  Future<List<Printer>> getPrinters({required PrinterType printerType}) {
    throw UnimplementedError('getPrinters() has not been implemented.');
  }

  /// Abre o seletor de dispositivos da plataforma para o usuário autorizar uma
  /// impressora, retornando-a já pronta para uso.
  ///
  /// Hoje só faz sentido na **Web/USB** (WebUSB `requestDevice`): por restrição
  /// de segurança do browser não há como varrer dispositivos silenciosamente, e
  /// [getPrinters] na web retorna apenas os já autorizados. Em plataformas
  /// nativas o default é `null` — use [getPrinters]. Retorna `null` se não for
  /// suportado, se o usuário cancelar ou se nada for selecionado.
  Future<Printer?> requestPrinter({required PrinterType printerType}) async {
    return null;
  }

  /// Indica se o ambiente atual suporta impressão USB via **WebUSB**.
  ///
  /// Só retorna `true` na Web em navegadores Chromium (Chrome/Edge/Opera) com
  /// `navigator.usb` disponível. Fora da Web (e em Safari/Firefox) é `false`.
  /// Útil para a UI decidir entre orientar o usuário ou abrir o chooser via
  /// [requestPrinter].
  Future<bool> isWebUsbSupported() async => false;

  /// Indica se o ambiente atual suporta impressão Bluetooth **BLE** via
  /// **Web Bluetooth**.
  ///
  /// Só retorna `true` na Web em navegadores Chromium com `navigator.bluetooth`.
  /// Fora da Web (e em Safari/Firefox) é `false`. Bluetooth clássico (RFCOMM)
  /// não é suportado no browser.
  Future<bool> isWebBluetoothSupported() async => false;

  /// Emite um evento sempre que um dispositivo USB é conectado ou desconectado
  /// (apenas Web, via eventos `connect`/`disconnect` do `navigator.usb`).
  ///
  /// Use para **auto-reconectar** impressoras já autorizadas: ao plugar o
  /// dispositivo, reconsulte [getPrinters]/[requestPrinter] (que reaproveitam a
  /// permissão existente sem abrir o chooser). Fora da Web é um stream vazio.
  Stream<void> get onWebUsbConnectionChange => const Stream<void>.empty();

  Future<void> printBytes({required List<int> bytes, required Printer printer}) {
    throw UnimplementedError('printBytes() has not been implemented.');
  }

  Future<bool> connect({required Printer printer}) {
    throw UnimplementedError('connect() has not been implemented.');
  }

  Future<void> disconnect({required Printer printer}) {
    throw UnimplementedError('disconnect() has not been implemented.');
  }

  Future<bool> isConnected({required Printer printer}) {
    throw UnimplementedError('isConnected() has not been implemented.');
  }

  Future<PrinterStatus> getPrinterStatus({required Printer printer}) {
    throw UnimplementedError('getPrinterStatus() has not been implemented.');
  }

  /// Libera recursos retidos (ex.: conexões de rede em pool).
  ///
  /// Default no-op; implementações que mantêm estado devem sobrescrever.
  Future<void> dispose() async {}
}
