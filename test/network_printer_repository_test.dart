import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:thermal_printer_flutter/src/repositories/network_printer_repository.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';

class _MockSocket extends Mock implements Socket {}

void main() {
  late NetworkPrinterRepository repository;

  setUpAll(() {
    registerFallbackValue(<int>[]);
  });

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

    test('prunes a dead connection from the pool', () async {
      final socket = _MockSocket();
      // O envio falha, fazendo o NetworkPrinter se desconectar internamente,
      // mas a entrada permanece no pool até ser podada por isConnected.
      when(() => socket.add(any())).thenThrow(const SocketException('down'));
      when(() => socket.flush()).thenAnswer((_) async {});
      when(() => socket.close()).thenAnswer((_) async {});

      final repo = NetworkPrinterRepository(
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            socket,
      );
      const printer = Printer(type: PrinterType.network, ip: '1.2.3.4');

      expect(await repo.connect(printer), isTrue);
      await expectLater(
        repo.printBytes(bytes: const [1], printer: printer),
        throwsA(isA<Exception>()),
      );

      expect(await repo.isConnected(printer), isFalse);
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

  group('dispose', () {
    test('closes pooled connections and clears the pool', () async {
      final socket = _MockSocket();
      when(() => socket.add(any())).thenReturn(null);
      when(() => socket.flush()).thenAnswer((_) async {});
      when(() => socket.close()).thenAnswer((_) async {});

      final repo = NetworkPrinterRepository(
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            socket,
      );
      const printer = Printer(type: PrinterType.network, ip: '1.2.3.4');

      expect(await repo.connect(printer), isTrue);
      expect(await repo.isConnected(printer), isTrue);

      await repo.dispose();

      expect(await repo.isConnected(printer), isFalse);
      verify(() => socket.close()).called(greaterThanOrEqualTo(1));
    });

    test('is safe with an empty pool', () async {
      await repository.dispose();
    });
  });
}
