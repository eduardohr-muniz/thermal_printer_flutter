import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter_method_channel.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter_platform_interface.dart';

class _MockPlatform
    with MockPlatformInterfaceMixin
    implements ThermalPrinterFlutterPlatform {
  final List<String> calls = [];
  Printer? lastPrinter;
  List<int>? lastBytes;
  PrinterType? lastPrinterType;

  @override
  Future<String?> getPlatformVersion() async {
    calls.add('getPlatformVersion');
    return '42';
  }

  @override
  Future<bool> checkBluetoothPermissions() async {
    calls.add('checkBluetoothPermissions');
    return true;
  }

  @override
  Future<bool> isBluetoothEnabled() async {
    calls.add('isBluetoothEnabled');
    return true;
  }

  @override
  Future<bool> enableBluetooth() async {
    calls.add('enableBluetooth');
    return true;
  }

  @override
  Future<List<Printer>> getPrinters({required PrinterType printerType}) async {
    calls.add('getPrinters');
    lastPrinterType = printerType;
    return [Printer(type: printerType, name: 'p')];
  }

  @override
  Future<void> printBytes(
      {required List<int> bytes, required Printer printer}) async {
    calls.add('printBytes');
    lastBytes = bytes;
    lastPrinter = printer;
  }

  @override
  Future<bool> connect({required Printer printer}) async {
    calls.add('connect');
    lastPrinter = printer;
    return true;
  }

  @override
  Future<void> disconnect({required Printer printer}) async {
    calls.add('disconnect');
    lastPrinter = printer;
  }

  @override
  Future<bool> isConnected({required Printer printer}) async {
    calls.add('isConnected');
    lastPrinter = printer;
    return true;
  }
}

void main() {
  group('ThermalPrinterFlutterPlatform', () {
    test('default instance is MethodChannelThermalPrinterFlutter', () {
      expect(
        ThermalPrinterFlutterPlatform.instance,
        isInstanceOf<MethodChannelThermalPrinterFlutter>(),
      );
    });

    test('base implementation throws UnimplementedError for each method', () {
      final base = _BarePlatform();

      expect(base.getPlatformVersion, throwsUnimplementedError);
      expect(base.checkBluetoothPermissions, throwsUnimplementedError);
      expect(base.isBluetoothEnabled, throwsUnimplementedError);
      expect(base.enableBluetooth, throwsUnimplementedError);
      expect(() => base.getPrinters(printerType: PrinterType.usb),
          throwsUnimplementedError);
      expect(
        () => base.printBytes(
            bytes: const [], printer: const Printer(type: PrinterType.usb)),
        throwsUnimplementedError,
      );
      expect(() => base.connect(printer: const Printer(type: PrinterType.usb)),
          throwsUnimplementedError);
      expect(
          () => base.disconnect(printer: const Printer(type: PrinterType.usb)),
          throwsUnimplementedError);
      expect(
          () => base.isConnected(printer: const Printer(type: PrinterType.usb)),
          throwsUnimplementedError);
    });
  });

  group('ThermalPrinterFlutter delegates to the platform', () {
    late _MockPlatform mock;
    late ThermalPrinterFlutter plugin;

    setUp(() {
      mock = _MockPlatform();
      ThermalPrinterFlutterPlatform.instance = mock;
      plugin = ThermalPrinterFlutter();
    });

    test('getPlatformVersion', () async {
      expect(await plugin.getPlatformVersion(), '42');
      expect(mock.calls, contains('getPlatformVersion'));
    });

    test('checkBluetoothPermissions', () async {
      expect(await plugin.checkBluetoothPermissions(), isTrue);
      expect(mock.calls, contains('checkBluetoothPermissions'));
    });

    test('isBluetoothEnabled', () async {
      expect(await plugin.isBluetoothEnabled(), isTrue);
      expect(mock.calls, contains('isBluetoothEnabled'));
    });

    test('enableBluetooth', () async {
      expect(await plugin.enableBluetooth(), isTrue);
      expect(mock.calls, contains('enableBluetooth'));
    });

    test('getPrinters passes through the printer type', () async {
      final printers =
          await plugin.getPrinters(printerType: PrinterType.bluetooth);

      expect(printers.single.type, PrinterType.bluetooth);
      expect(mock.lastPrinterType, PrinterType.bluetooth);
    });

    test('printBytes forwards bytes and printer', () async {
      const printer = Printer(type: PrinterType.usb, name: 'USB');
      await plugin.printBytes(bytes: const [1, 2], printer: printer);

      expect(mock.lastBytes, [1, 2]);
      expect(mock.lastPrinter, printer);
    });

    test('connect forwards the printer', () async {
      const printer = Printer(type: PrinterType.network, ip: '1.2.3.4');
      expect(await plugin.connect(printer: printer), isTrue);
      expect(mock.lastPrinter, printer);
    });

    test('disconnect forwards the printer', () async {
      const printer = Printer(type: PrinterType.network, ip: '1.2.3.4');
      await plugin.disconnect(printer: printer);
      expect(mock.calls, contains('disconnect'));
      expect(mock.lastPrinter, printer);
    });

    test('isConnected forwards the printer', () async {
      const printer = Printer(type: PrinterType.bluetooth, bleAddress: 'b1');
      expect(await plugin.isConnected(printer: printer), isTrue);
      expect(mock.lastPrinter, printer);
    });

    testWidgets('screenShotWidget captures the given widget', (tester) async {
      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );

      late img.Image image;
      await tester.runAsync(() async {
        final future = plugin.screenShotWidget(
          capturedContext,
          width: 64,
          pixelRatio: 1.0,
          widget: Container(width: 64, height: 32, color: Colors.black),
        );

        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        image = await future;
      });

      expect(image.width, greaterThan(0));
    });
  });
}

class _BarePlatform extends ThermalPrinterFlutterPlatform {}
