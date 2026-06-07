import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';

void main() {
  group('Printer', () {
    const printer = Printer(
      type: PrinterType.network,
      name: 'Printer 1',
      ip: '192.168.0.10',
      port: '6310',
      bleAddress: 'AA:BB:CC',
      usbAddress: 'usb-001',
      isConnected: true,
    );

    test('default values are applied for optional fields', () {
      const p = Printer(type: PrinterType.usb);

      expect(p.name, '');
      expect(p.ip, '');
      expect(p.port, '9100');
      expect(p.bleAddress, '');
      expect(p.usbAddress, '');
      expect(p.isConnected, false);
      expect(p.type, PrinterType.usb);
    });

    group('toMap', () {
      test('serializes all fields and uses enum.name for type', () {
        final map = printer.toMap();

        expect(map['name'], 'Printer 1');
        expect(map['ip'], '192.168.0.10');
        expect(map['port'], '6310');
        expect(map['bleAddress'], 'AA:BB:CC');
        expect(map['usbAddress'], 'usb-001');
        expect(map['type'], 'network');
        expect(map['isConnected'], true);
      });

      test('serializes bluetooth as "bluetooth" not legacy spelling', () {
        const p = Printer(type: PrinterType.bluetooth);

        expect(p.toMap()['type'], 'bluetooth');
      });
    });

    group('fromMap', () {
      test('parses a complete map', () {
        final p = Printer.fromMap(printer.toMap());

        expect(p, printer);
      });

      test('maps legacy "bluethoot" type to PrinterType.bluetooth', () {
        final p = Printer.fromMap({'type': 'bluethoot'});

        expect(p.type, PrinterType.bluetooth);
      });

      test('maps "bluetooth" type to PrinterType.bluetooth', () {
        final p = Printer.fromMap({'type': 'bluetooth'});

        expect(p.type, PrinterType.bluetooth);
      });

      test('falls back to usb for null type', () {
        final p = Printer.fromMap({});

        expect(p.type, PrinterType.usb);
        expect(p.name, '');
        expect(p.ip, '');
        expect(p.port, '');
        expect(p.bleAddress, '');
        expect(p.usbAddress, '');
        expect(p.isConnected, false);
      });

      test('falls back to usb for unknown type', () {
        final p = Printer.fromMap({'type': 'nonsense'});

        expect(p.type, PrinterType.usb);
      });

      test('parses each known type', () {
        expect(Printer.fromMap({'type': 'usb'}).type, PrinterType.usb);
        expect(Printer.fromMap({'type': 'network'}).type, PrinterType.network);
      });
    });

    group('copyWith', () {
      test('returns an identical copy when no args given', () {
        expect(printer.copyWith(), printer);
      });

      test('overrides only provided fields', () {
        final copy = printer.copyWith(
          name: 'New',
          ip: '10.0.0.1',
          port: '515',
          bleAddress: 'XX',
          usbAddress: 'usb-2',
          type: PrinterType.usb,
          isConnected: false,
        );

        expect(copy.name, 'New');
        expect(copy.ip, '10.0.0.1');
        expect(copy.port, '515');
        expect(copy.bleAddress, 'XX');
        expect(copy.usbAddress, 'usb-2');
        expect(copy.type, PrinterType.usb);
        expect(copy.isConnected, false);
      });
    });

    group('json', () {
      test('toJson produces decodable JSON', () {
        final decoded = json.decode(printer.toJson()) as Map<String, dynamic>;

        expect(decoded['name'], 'Printer 1');
        expect(decoded['type'], 'network');
      });

      test('fromJson round-trips', () {
        final p = Printer.fromJson(printer.toJson());

        expect(p, printer);
      });
    });

    group('equality', () {
      test('identical instances are equal', () {
        expect(printer == printer, isTrue);
      });

      test('equal field values are equal and share hashCode', () {
        final other = printer.copyWith();

        expect(printer, other);
        expect(printer.hashCode, other.hashCode);
      });

      test('different field values are not equal', () {
        expect(printer == printer.copyWith(name: 'Other'), isFalse);
        expect(printer == printer.copyWith(ip: 'x'), isFalse);
        expect(printer == printer.copyWith(port: 'x'), isFalse);
        expect(printer == printer.copyWith(bleAddress: 'x'), isFalse);
        expect(printer == printer.copyWith(usbAddress: 'x'), isFalse);
        expect(printer == printer.copyWith(type: PrinterType.usb), isFalse);
        expect(printer == printer.copyWith(isConnected: false), isFalse);
      });

      test('is not equal to a different runtime type', () {
        expect(printer == Object(), isFalse);
      });
    });
  });

  group('PrinterType', () {
    test('exposes the three supported types', () {
      expect(PrinterType.values, [
        PrinterType.usb,
        PrinterType.bluetooth,
        PrinterType.network,
      ]);
    });

    test('names serialize as expected', () {
      expect(PrinterType.usb.name, 'usb');
      expect(PrinterType.bluetooth.name, 'bluetooth');
      expect(PrinterType.network.name, 'network');
    });
  });
}
