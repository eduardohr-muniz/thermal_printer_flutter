// coverage:ignore-file
// Web implementation relies on dart:web/browser APIs that do not run in the
// Flutter test VM, so it is excluded from unit-test coverage.
//
// In order to *not* need this ignore, consider extracting the "web" version
// of your plugin as a separate package, instead of inlining it in the same
// package as the core of your plugin.
// ignore: avoid_web_libraries_in_flutter

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'thermal_printer_flutter_platform_interface.dart';

/// A web implementation of the ThermalPrinterFlutterPlatform of the ThermalPrinterFlutter plugin.
class ThermalPrinterFlutterWeb extends ThermalPrinterFlutterPlatform {
  /// Constructs a ThermalPrinterFlutterWeb
  ThermalPrinterFlutterWeb();

  static void registerWith(Registrar registrar) {
    ThermalPrinterFlutterPlatform.instance = ThermalPrinterFlutterWeb();
  }

  /// Returns a [String] containing the version of the platform.
  @override
  Future<String?> getPlatformVersion() async {
    final version = web.window.navigator.userAgent;
    return version;
  }
}
