import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_printer_flutter/src/repositories/network_printer_repository.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';

void main() {
  late NetworkPrinterRepository repository;

  setUp(() {
    repository = NetworkPrinterRepository();
  });

  group('getPrinters', () {
    test('returns empty list (network printers are added manually)', () async {
      expect(await repository.getPrinters(), isEmpty);
    });
  });

  group('connect', () {
    test('returns false when the printer has no IP', () async {
      final result =
          await repository.connect(const Printer(type: PrinterType.network));

      expect(result, isFalse);
    });
  });

  group('isConnected', () {
    test('returns false for a printer that was never connected', () async {
      final result = await repository.isConnected(
        const Printer(type: PrinterType.network, ip: '1.2.3.4'),
      );

      expect(result, isFalse);
    });
  });

  group('disconnect', () {
    test('is a no-op for an unknown printer', () async {
      // Should not throw.
      await repository.disconnect(
        const Printer(type: PrinterType.network, ip: '1.2.3.4'),
      );
    });
  });
}
