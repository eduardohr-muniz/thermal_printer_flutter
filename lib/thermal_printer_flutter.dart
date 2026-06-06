import 'package:flutter/cupertino.dart';
import 'package:thermal_printer_flutter/src/enums/printer_type.dart';
import 'package:thermal_printer_flutter/src/models/printer.dart';
import 'package:thermal_printer_flutter/src/services/screent_shot.dart';
import 'package:thermal_printer_flutter/src/repositories/network_printer_repository.dart';
import 'thermal_printer_flutter_platform_interface.dart';
export './src/models/printer.dart';
export './src/enums/printer_type.dart';
export './src/services/screent_shot.dart';
import 'package:image/image.dart' as img;
export 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

class ThermalPrinterFlutter implements ThermalPrinterFlutterPlatform {
  final NetworkPrinterRepository _networkRepository = NetworkPrinterRepository();
  @override
  Future<String?> getPlatformVersion() async {
    return await ThermalPrinterFlutterPlatform.instance.getPlatformVersion();
  }

  @override
  Future<bool> checkBluetoothPermissions() async {
    return await ThermalPrinterFlutterPlatform.instance.checkBluetoothPermissions();
  }

  @override
  Future<bool> isBluetoothEnabled() async {
    return await ThermalPrinterFlutterPlatform.instance.isBluetoothEnabled();
  }

  @override
  Future<bool> enableBluetooth() async {
    return await ThermalPrinterFlutterPlatform.instance.enableBluetooth();
  }

  @override
  Future<List<Printer>> getPrinters({required PrinterType printerType}) async {
    return await ThermalPrinterFlutterPlatform.instance.getPrinters(printerType: printerType);
  }

  /// Descobre automaticamente impressoras de rede na rede local
  ///
  /// Escaneia a rede local procurando por impressoras nas portas comuns:
  /// - 9100 (Raw TCP/IP - mais comum para impressoras térmicas)
  /// - 515 (LPR/LPD)
  /// - 631 (IPP - Internet Printing Protocol)
  ///
  /// [onProgress] - Callback opcional para receber atualizações do progresso
  ///
  /// Retorna uma lista de impressoras encontradas na rede
  Future<List<Printer>> discoverNetworkPrinters({
    Function(String)? onProgress,
  }) async {
    return await _networkRepository.discoverNetworkPrinters(onProgress: onProgress);
  }

  @override
  Future<void> printBytes({required List<int> bytes, required Printer printer}) async {
    return await ThermalPrinterFlutterPlatform.instance.printBytes(bytes: bytes, printer: printer);
  }

  @override
  Future<bool> connect({required Printer printer}) async {
    return await ThermalPrinterFlutterPlatform.instance.connect(printer: printer);
  }

  @override
  Future<void> disconnect({required Printer printer}) async {
    await ThermalPrinterFlutterPlatform.instance.disconnect(printer: printer);
  }

  @override
  Future<bool> isConnected({required Printer printer}) async {
    return await ThermalPrinterFlutterPlatform.instance.isConnected(printer: printer);
  }

  Future<img.Image> screenShotWidget(
    BuildContext context, {
    required Widget widget,
    double pixelRatio = 3.0,
    int width = 550,
    int threshold = 160,
    bool flipHorizontal = false,
    bool applyTextScaling = true,
    bool useBetterText = true,
    double textScaleFactor = 1.3,
  }) async {
    return await ThermalScreenshot.captureWidgetAsMonochromeImage(context,
        widget: widget, flipHorizontal: flipHorizontal, pixelRatio: pixelRatio, threshold: threshold, width: width, applyTextScaling: applyTextScaling, useBetterText: useBetterText, textScaleFactor: textScaleFactor);
  }
}
