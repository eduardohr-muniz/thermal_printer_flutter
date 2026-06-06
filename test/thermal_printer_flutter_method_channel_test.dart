import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('thermal_printer_flutter');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MethodChannelThermalPrinterFlutter platform;
  final List<MethodCall> calls = [];

  void mockHandler(Future<Object?> Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    calls.clear();
    platform = MethodChannelThermalPrinterFlutter();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('getPlatformVersion', () {
    test('returns the version reported by the channel', () async {
      mockHandler((call) async {
        expect(call.method, 'getPlatformVersion');
        return 'macOS 14';
      });

      expect(await platform.getPlatformVersion(), 'macOS 14');
    });
  });

  group('bluetooth toggles', () {
    test('checkBluetoothPermissions returns channel result', () async {
      mockHandler((call) async {
        expect(call.method, 'checkBluetoothPermissions');
        return true;
      });

      expect(await platform.checkBluetoothPermissions(), isTrue);
    });

    test('checkBluetoothPermissions returns false on error', () async {
      mockHandler((_) async => throw PlatformException(code: 'ERR'));

      expect(await platform.checkBluetoothPermissions(), isFalse);
    });

    test('isBluetoothEnabled returns channel result', () async {
      mockHandler((call) async {
        expect(call.method, 'isBluetoothEnabled');
        return true;
      });

      expect(await platform.isBluetoothEnabled(), isTrue);
    });

    test('isBluetoothEnabled returns false on error', () async {
      mockHandler((_) async => throw PlatformException(code: 'ERR'));

      expect(await platform.isBluetoothEnabled(), isFalse);
    });

    test('enableBluetooth returns channel result', () async {
      mockHandler((call) async {
        expect(call.method, 'enableBluetooth');
        return true;
      });

      expect(await platform.enableBluetooth(), isTrue);
    });

    test('enableBluetooth returns false on error', () async {
      mockHandler((_) async => throw PlatformException(code: 'ERR'));

      expect(await platform.enableBluetooth(), isFalse);
    });
  }, skip: Platform.isWindows);

  group('getPrinters', () {
    test('usb delegates to usbprinters', () async {
      mockHandler((call) async {
        expect(call.method, 'usbprinters');
        return [
          {'name': 'USB', 'usbAddress': 'u1'},
        ];
      });

      final printers = await platform.getPrinters(printerType: PrinterType.usb);

      expect(printers.single.type, PrinterType.usb);
      expect(printers.single.name, 'USB');
    });

    test('bluetooth delegates to pairedbluetooths', () async {
      mockHandler((call) async {
        expect(call.method, 'pairedbluetooths');
        return [
          {'name': 'BLE', 'bleAddress': 'b1'},
        ];
      });

      final printers =
          await platform.getPrinters(printerType: PrinterType.bluetooth);

      expect(printers.single.type, PrinterType.bluetooth);
      expect(printers.single.name, 'BLE');
    }, skip: Platform.isWindows);

    test('network returns an empty list', () async {
      mockHandler((_) async => null);

      expect(await platform.getPrinters(printerType: PrinterType.network),
          isEmpty);
    });
  });

  group('printBytes', () {
    test('usb printer sends a Uint8List payload with printerName', () async {
      mockHandler((call) async {
        expect(call.method, 'writebytes');
        final args = call.arguments as Map;
        expect(args['bytes'], isA<Uint8List>());
        expect(args['printerName'], 'USB');
        return true;
      });

      await platform.printBytes(
        bytes: [1, 2, 3],
        printer: const Printer(type: PrinterType.usb, name: 'USB'),
      );
    });

    test('bluetooth printer sends a raw Uint8List payload', () async {
      mockHandler((call) async {
        expect(call.method, 'writebytes');
        expect(call.arguments, isA<Uint8List>());
        return null;
      });

      await platform.printBytes(
        bytes: [1, 2, 3],
        printer: const Printer(type: PrinterType.bluetooth),
      );
    }, skip: Platform.isWindows);
  });

  group('connect / disconnect / isConnected', () {
    test('usb connect returns true without channel call', () async {
      mockHandler((_) async => null);

      expect(
          await platform.connect(printer: const Printer(type: PrinterType.usb)),
          isTrue);
    });

    test('bluetooth connect delegates to the channel', () async {
      mockHandler((call) async => call.method == 'connect' ? true : null);

      final result = await platform.connect(
        printer: const Printer(type: PrinterType.bluetooth, bleAddress: 'b1'),
      );

      expect(result, isTrue);
    }, skip: Platform.isWindows);

    test('network connect returns false without an IP', () async {
      mockHandler((_) async => null);

      expect(
          await platform.connect(
              printer: const Printer(type: PrinterType.network)),
          isFalse);
    });

    test('usb disconnect is a no-op', () async {
      mockHandler((_) async => null);

      await platform.disconnect(printer: const Printer(type: PrinterType.usb));
    });

    test('bluetooth disconnect delegates to the channel', () async {
      mockHandler((_) async => null);

      await platform.disconnect(
          printer: const Printer(type: PrinterType.bluetooth));

      expect(calls.map((c) => c.method), contains('disconnect'));
    }, skip: Platform.isWindows);

    test('network disconnect is a no-op for unknown printers', () async {
      mockHandler((_) async => null);

      await platform.disconnect(
        printer: const Printer(type: PrinterType.network, ip: '1.2.3.4'),
      );
    });

    test('usb isConnected delegates to the channel', () async {
      mockHandler((call) async {
        expect(call.method, 'isConnected');
        return true;
      });

      expect(
        await platform.isConnected(
            printer: const Printer(type: PrinterType.usb, usbAddress: 'u1')),
        isTrue,
      );
    });

    test('bluetooth isConnected delegates to the channel', () async {
      mockHandler((_) async => true);

      expect(
        await platform.isConnected(
            printer:
                const Printer(type: PrinterType.bluetooth, bleAddress: 'b1')),
        isTrue,
      );
    }, skip: Platform.isWindows);

    test('network isConnected returns false when not connected', () async {
      mockHandler((_) async => null);

      expect(
        await platform.isConnected(
            printer: const Printer(type: PrinterType.network, ip: '1.2.3.4')),
        isFalse,
      );
    });
  });
}
