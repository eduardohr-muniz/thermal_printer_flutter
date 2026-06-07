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

  /// Hook opcional executado dentro de [printBytes]; permite os testes
  /// controlarem timing (para validar serialização) e erros.
  Future<void> Function(List<int> bytes)? onPrintBytes;

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
    if (onPrintBytes != null) await onPrintBytes!(bytes);
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

  @override
  Future<PrinterStatus> getPrinterStatus({required Printer printer}) async {
    calls.add('getPrinterStatus');
    lastPrinter = printer;
    return PrinterStatus.unknown;
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
      expect(
          () => base.getPrinterStatus(
              printer: const Printer(type: PrinterType.usb)),
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

    test('printBytes default sends the payload exactly once', () async {
      const printer = Printer(type: PrinterType.usb, name: 'USB');
      await plugin.printBytes(bytes: const [9, 9], printer: printer);

      expect(mock.lastBytes, [9, 9]);
    });

    test('printBytes repeats the payload for multiple copies', () async {
      const printer = Printer(type: PrinterType.usb, name: 'USB');
      await plugin.printBytes(
          bytes: const [1, 2, 3], printer: printer, copies: 3);

      // Cópias são montadas no próprio stream (um único job).
      expect(mock.lastBytes, [1, 2, 3, 1, 2, 3, 1, 2, 3]);
    });

    test('printBytes asserts copies >= 1', () {
      const printer = Printer(type: PrinterType.usb, name: 'USB');
      expect(
        () => plugin.printBytes(
            bytes: const [1], printer: printer, copies: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('concurrent prints are serialized in call order', () async {
      final completionOrder = <int>[];
      mock.onPrintBytes = (bytes) async {
        final id = bytes.first;
        // Primeiro job é mais lento que o segundo: se houver sobreposição,
        // o segundo terminaria antes e a ordem seria [2, 1].
        await Future<void>.delayed(
            Duration(milliseconds: id == 1 ? 60 : 10));
        completionOrder.add(id);
      };

      const printer = Printer(type: PrinterType.usb, name: 'USB');
      final f1 = plugin.printBytes(bytes: const [1], printer: printer);
      final f2 = plugin.printBytes(bytes: const [2], printer: printer);
      await Future.wait([f1, f2]);

      expect(completionOrder, [1, 2]);
    });

    test('a failing print does not block subsequent jobs', () async {
      final completionOrder = <int>[];
      mock.onPrintBytes = (bytes) async {
        final id = bytes.first;
        if (id == 1) throw Exception('boom');
        completionOrder.add(id);
      };

      const printer = Printer(type: PrinterType.usb, name: 'USB');
      final f1 = plugin.printBytes(bytes: const [1], printer: printer);
      final f2 = plugin.printBytes(bytes: const [2], printer: printer);

      await expectLater(f1, throwsException);
      await f2;

      expect(completionOrder, [2]);
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

    test('getPrinterStatus forwards the printer', () async {
      const printer = Printer(type: PrinterType.usb, name: 'USB');
      final status = await plugin.getPrinterStatus(printer: printer);
      expect(status, isA<PrinterStatus>());
      expect(mock.calls, contains('getPrinterStatus'));
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
