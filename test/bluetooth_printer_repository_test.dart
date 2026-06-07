
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_printer_flutter/src/repositories/bluetooth_printer_repository.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('thermal_printer_flutter');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late BluetoothPrinterRepository repository;
  final List<MethodCall> calls = [];

  void mockHandler(Future<Object?> Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    calls.clear();
    repository = BluetoothPrinterRepository();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('getPrinters', () {
    test('maps map devices into bluetooth printers', () async {
      mockHandler((call) async {
        expect(call.method, 'pairedbluetooths');
        return [
          {'name': 'BLE Printer', 'bleAddress': 'AA:BB', 'isConnected': true},
        ];
      });

      final printers = await repository.getPrinters();

      expect(printers, hasLength(1));
      expect(printers.first.type, PrinterType.bluetooth);
      expect(printers.first.name, 'BLE Printer');
      expect(printers.first.bleAddress, 'AA:BB');
      expect(printers.first.isConnected, true);
    });

    test('parses "name#address" string devices', () async {
      mockHandler((_) async => ['My Printer#11:22:33']);

      final printers = await repository.getPrinters();

      expect(printers, hasLength(1));
      expect(printers.first.type, PrinterType.bluetooth);
      expect(printers.first.name, 'My Printer');
      expect(printers.first.bleAddress, '11:22:33');
    });

    test('returns a default bluetooth printer for other entry types', () async {
      mockHandler((_) async => [42]);

      final printers = await repository.getPrinters();

      expect(printers, hasLength(1));
      expect(printers.first.type, PrinterType.bluetooth);
      expect(printers.first.name, '');
    });

    test('returns empty list when channel returns null', () async {
      mockHandler((_) async => null);

      expect(await repository.getPrinters(), isEmpty);
    });

    test('returns empty list on PlatformException', () async {
      mockHandler((_) async => throw PlatformException(code: 'ERR'));

      expect(await repository.getPrinters(), isEmpty);
    });
  });

  group('connect', () {
    test('disconnects first then connects with the ble address', () async {
      mockHandler((call) async {
        if (call.method == 'connect') {
          expect(call.arguments, 'AA:BB');
          return true;
        }
        return null;
      });

      final result = await repository.connect(
        const Printer(type: PrinterType.bluetooth, bleAddress: 'AA:BB'),
      );

      expect(result, isTrue);
      expect(calls.map((c) => c.method),
          containsAllInOrder(['disconnect', 'connect']));
    });

    test('returns false when connect returns null', () async {
      mockHandler((call) async => call.method == 'connect' ? null : null);

      final result =
          await repository.connect(const Printer(type: PrinterType.bluetooth));

      expect(result, isFalse);
    });

    test('returns false on PlatformException', () async {
      mockHandler((call) async {
        if (call.method == 'connect') throw PlatformException(code: 'ERR');
        return null;
      });

      final result =
          await repository.connect(const Printer(type: PrinterType.bluetooth));

      expect(result, isFalse);
    });
  });

  group('disconnect', () {
    test('invokes disconnect on the channel', () async {
      mockHandler((_) async => null);

      await repository.disconnect(const Printer(type: PrinterType.bluetooth));

      expect(calls.single.method, 'disconnect');
    });

    test('swallows PlatformException', () async {
      mockHandler((_) async => throw PlatformException(code: 'ERR'));

      // Should not throw.
      await repository.disconnect(const Printer(type: PrinterType.bluetooth));
    });
  });

  group('printBytes', () {
    test('sends Uint8List bytes to writebytes', () async {
      mockHandler((call) async {
        expect(call.method, 'writebytes');
        expect(call.arguments, isA<Uint8List>());
        expect(call.arguments, Uint8List.fromList([10, 20, 30]));
        return null;
      });

      await repository.printBytes(
        bytes: [10, 20, 30],
        printer: const Printer(type: PrinterType.bluetooth),
      );

      expect(calls.single.method, 'writebytes');
    });

    test('rethrows on PlatformException', () async {
      mockHandler((_) async => throw PlatformException(code: 'ERR'));

      expect(
        () => repository.printBytes(
            bytes: [1], printer: const Printer(type: PrinterType.bluetooth)),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('isConnected', () {
    test('returns the channel result for the ble address', () async {
      mockHandler((call) async {
        expect(call.method, 'isConnected');
        expect(call.arguments, 'AA:BB');
        return true;
      });

      final result = await repository.isConnected(
        const Printer(type: PrinterType.bluetooth, bleAddress: 'AA:BB'),
      );

      expect(result, isTrue);
    });

    test('returns false when channel returns null', () async {
      mockHandler((_) async => null);

      expect(
          await repository
              .isConnected(const Printer(type: PrinterType.bluetooth)),
          isFalse);
    });

    test('returns false on PlatformException', () async {
      mockHandler((_) async => throw PlatformException(code: 'ERR'));

      expect(
          await repository
              .isConnected(const Printer(type: PrinterType.bluetooth)),
          isFalse);
    });
  });
}
