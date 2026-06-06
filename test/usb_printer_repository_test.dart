
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_printer_flutter/src/repositories/usb_printer_repository.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('thermal_printer_flutter');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late UsbPrinterRepository repository;
  final List<MethodCall> calls = [];

  void mockHandler(Future<Object?> Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    calls.clear();
    repository = UsbPrinterRepository();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('getPrinters', () {
    test('maps a list of device maps into USB printers', () async {
      mockHandler((call) async {
        expect(call.method, 'usbprinters');
        return [
          {'name': 'USB Printer', 'usbAddress': 'usb-1', 'isConnected': true},
        ];
      });

      final printers = await repository.getPrinters();

      expect(printers, hasLength(1));
      expect(printers.first.type, PrinterType.usb);
      expect(printers.first.name, 'USB Printer');
      expect(printers.first.usbAddress, 'usb-1');
      expect(printers.first.isConnected, true);
    });

    test('returns a default usb printer for non-map entries', () async {
      mockHandler((_) async => ['unexpected']);

      final printers = await repository.getPrinters();

      expect(printers, hasLength(1));
      expect(printers.first.type, PrinterType.usb);
      expect(printers.first.name, '');
    });

    test('returns empty list when channel returns null', () async {
      mockHandler((_) async => null);

      expect(await repository.getPrinters(), isEmpty);
    });

    test('returns empty list and logs on PlatformException', () async {
      mockHandler((_) async => throw PlatformException(code: 'ERR'));

      expect(await repository.getPrinters(), isEmpty);
    });
  });

  group('connect / disconnect', () {
    test('connect always returns true without touching the channel', () async {
      final result =
          await repository.connect(const Printer(type: PrinterType.usb));

      expect(result, isTrue);
      expect(calls, isEmpty);
    });

    test('disconnect is a no-op', () async {
      await repository.disconnect(const Printer(type: PrinterType.usb));

      expect(calls, isEmpty);
    });
  });

  group('printBytes', () {
    test('sends Uint8List bytes and printerName to writebytes', () async {
      mockHandler((call) async {
        expect(call.method, 'writebytes');
        final args = call.arguments as Map;
        expect(args['bytes'], isA<Uint8List>());
        expect(args['bytes'], Uint8List.fromList([1, 2, 3]));
        expect(args['printerName'], 'My USB');
        return true;
      });

      await repository.printBytes(
        bytes: [1, 2, 3],
        printer: const Printer(type: PrinterType.usb, name: 'My USB'),
      );

      expect(calls, hasLength(1));
    });

    test('logs when channel reports failure (returns false)', () async {
      mockHandler((_) async => false);

      // Should complete without throwing.
      await repository.printBytes(
        bytes: [1],
        printer: const Printer(type: PrinterType.usb),
      );
    });

    test('rethrows on PlatformException', () async {
      mockHandler((_) async => throw PlatformException(code: 'ERR'));

      expect(
        () => repository.printBytes(
            bytes: [1], printer: const Printer(type: PrinterType.usb)),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('isConnected', () {
    test('returns the channel result', () async {
      mockHandler((call) async {
        expect(call.method, 'isConnected');
        expect(call.arguments, 'usb-addr');
        return true;
      });

      final result = await repository.isConnected(
        const Printer(type: PrinterType.usb, usbAddress: 'usb-addr'),
      );

      expect(result, isTrue);
    });

    test('returns false when channel returns null', () async {
      mockHandler((_) async => null);

      expect(await repository.isConnected(const Printer(type: PrinterType.usb)),
          isFalse);
    });

    test('returns false on PlatformException', () async {
      mockHandler((_) async => throw PlatformException(code: 'ERR'));

      expect(await repository.isConnected(const Printer(type: PrinterType.usb)),
          isFalse);
    });
  });
}
