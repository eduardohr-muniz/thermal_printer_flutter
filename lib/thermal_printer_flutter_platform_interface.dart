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
