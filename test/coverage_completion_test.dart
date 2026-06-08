import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter_method_channel.dart';
import 'package:thermal_printer_flutter/src/network_printer.dart';
import 'package:thermal_printer_flutter/src/repositories/network_printer_repository.dart';

class _MockSocket extends Mock implements Socket {}

class _FakeInternetAddress extends Fake implements InternetAddress {
  _FakeInternetAddress(this.address);

  @override
  final String address;
  @override
  InternetAddressType get type => InternetAddressType.IPv4;
  @override
  bool get isLoopback => false;
}

class _FakeNetworkInterface extends Fake implements NetworkInterface {
  _FakeNetworkInterface(this.name, this.addresses);

  @override
  final String name;
  @override
  final List<InternetAddress> addresses;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => registerFallbackValue(<int>[]));

  _MockSocket buildSocket() {
    final socket = _MockSocket();
    when(() => socket.add(any())).thenReturn(null);
    when(() => socket.flush()).thenAnswer((_) async {});
    when(() => socket.close()).thenAnswer((_) async {});
    when(() => socket.listen(
          any(),
          onError: any(named: 'onError'),
          onDone: any(named: 'onDone'),
          cancelOnError: any(named: 'cancelOnError'),
        )).thenAnswer((invocation) {
      final onData =
          invocation.positionalArguments[0] as void Function(Uint8List)?;
      final onError = invocation.namedArguments[#onError] as Function?;
      final onDone = invocation.namedArguments[#onDone] as void Function()?;
      final cancelOnError = invocation.namedArguments[#cancelOnError] as bool?;
      return const Stream<Uint8List>.empty().listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
    });
    return socket;
  }

  SocketConnector connectorTo(_MockSocket socket) =>
      (host, port, {timeout = const Duration(seconds: 5)}) async => socket;

  SocketConnector failingConnector() =>
      (host, port, {timeout = const Duration(seconds: 5)}) async =>
          throw const SocketException('refused');

  // ---- NetworkPrinter real (non-injected) defaults --------------------------

  group('NetworkPrinter real defaults', () {
    test('default socket connector connects to a real local server', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((s) => s.destroy());
      addTearDown(() async => server.close());

      final printer = NetworkPrinter(host: '127.0.0.1', port: server.port);

      expect(await printer.connect(), isTrue);
      await printer.disconnect();
    });

    test('default interface lister is used when none is injected', () async {
      // No subnet and no interfaceLister => the real NetworkInterface.list()
      // default is exercised. The injected failing connector guarantees no real
      // network traffic during the scan.
      final printers = await NetworkPrinter.discoverPrinters(
        ports: const [9100],
        connector: failingConnector(),
      );

      expect(printers, isA<List<NetworkPrinterInfo>>());
    });
  });

  // ---- NetworkPrinterRepository --------------------------------------------

  group('NetworkPrinterRepository', () {
    final printer = Printer(type: PrinterType.network, ip: '1.2.3.4');

    test('getPrinters returns an empty list', () async {
      expect(await NetworkPrinterRepository().getPrinters(), isEmpty);
    });

    test('discoverNetworkPrinters maps discovered printers', () async {
      final repo = NetworkPrinterRepository(
        interfaceLister: () async => [
          _FakeNetworkInterface('en0', [_FakeInternetAddress('192.168.1.5')]),
        ],
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async {
          if (host == '192.168.1.5') return buildSocket();
          throw const SocketException('refused');
        },
      );

      final found = await repo.discoverNetworkPrinters();

      expect(found, isNotEmpty);
      expect(found.first.type, PrinterType.network);
      expect(found.first.ip, '192.168.1.5');
    });

    test('discoverNetworkPrinters with requireConfirmation filters unconfirmed',
        () async {
      final repo = NetworkPrinterRepository(
        interfaceLister: () async => [
          _FakeNetworkInterface('en0', [_FakeInternetAddress('192.168.1.5')]),
        ],
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async {
          // Conecta mas o stream nunca responde => não confirmado.
          if (host == '192.168.1.5') return buildSocket();
          throw const SocketException('refused');
        },
      );

      final found = await repo.discoverNetworkPrinters(
        requireConfirmation: true,
        onProgress: (_) {},
      );

      expect(found, isEmpty);
    });

    test('connect returns false when the IP is empty', () async {
      final repo = NetworkPrinterRepository(connector: connectorTo(buildSocket()));

      expect(await repo.connect(Printer(type: PrinterType.network)), isFalse);
    });

    test('connect succeeds and replaces an existing connection', () async {
      final repo = NetworkPrinterRepository(
        connector: connectorTo(buildSocket()),
      );

      expect(await repo.connect(printer), isTrue);
      // Second connect hits the "remove previous connection" branch.
      expect(await repo.connect(printer), isTrue);
    });

    test('connect returns false when the socket cannot be opened', () async {
      final repo = NetworkPrinterRepository(connector: failingConnector());

      expect(await repo.connect(printer), isFalse);
    });

    test('printBytes auto-connects and writes', () async {
      final socket = buildSocket();
      final repo = NetworkPrinterRepository(connector: connectorTo(socket));

      await repo.printBytes(bytes: [1, 2, 3], printer: printer);

      verify(() => socket.add([1, 2, 3])).called(1);
    });

    test('printBytes reuses an already-open connection', () async {
      final socket = buildSocket();
      final repo = NetworkPrinterRepository(connector: connectorTo(socket));

      await repo.connect(printer);
      await repo.printBytes(bytes: [9], printer: printer);

      verify(() => socket.add([9])).called(1);
    });

    test('printBytes throws when it cannot connect', () async {
      final repo = NetworkPrinterRepository(connector: failingConnector());

      expect(
        () => repo.printBytes(bytes: [1], printer: printer),
        throwsA(isA<Exception>()),
      );
    });

    test('printBytes throws when the write fails', () async {
      final socket = buildSocket();
      when(() => socket.add(any())).thenThrow(const SocketException('broken'));
      final repo = NetworkPrinterRepository(connector: connectorTo(socket));

      expect(
        () => repo.printBytes(bytes: [1], printer: printer),
        throwsA(isA<Exception>()),
      );
    });

    test('disconnect closes a known connection', () async {
      final socket = buildSocket();
      final repo = NetworkPrinterRepository(connector: connectorTo(socket));

      await repo.connect(printer);
      await repo.disconnect(printer);

      verify(() => socket.close()).called(greaterThanOrEqualTo(1));
    });

    test('disconnect is a no-op for an unknown printer', () async {
      await NetworkPrinterRepository().disconnect(printer);
    });

    test('isConnected reflects the stored connection state', () async {
      final repo =
          NetworkPrinterRepository(connector: connectorTo(buildSocket()));

      expect(await repo.isConnected(printer), isFalse);
      await repo.connect(printer);
      expect(await repo.isConnected(printer), isTrue);
    });
  });

  // ---- MethodChannel Windows + network branches -----------------------------

  group('MethodChannelThermalPrinterFlutter', () {
    test('default constructor resolves the real platform flag', () {
      expect(MethodChannelThermalPrinterFlutter(), isNotNull);
    });

    test('printBytes delegates network printers to the repository', () async {
      final socket = buildSocket();
      final mc = MethodChannelThermalPrinterFlutter(
        networkRepository:
            NetworkPrinterRepository(connector: connectorTo(socket)),
      );

      await mc.printBytes(
        bytes: const [1, 2],
        printer: Printer(type: PrinterType.network, ip: '1.2.3.4'),
      );

      verify(() => socket.add(const [1, 2])).called(1);
    });
  });

  // ---- Public facade: network discovery delegation --------------------------

  group('ThermalPrinterFlutter.discoverNetworkPrinters', () {
    test('delegates to the injected network repository', () async {
      final plugin = ThermalPrinterFlutter(
        networkRepository: NetworkPrinterRepository(
          interfaceLister: () async => const [],
        ),
      );

      expect(await plugin.discoverNetworkPrinters(), isEmpty);
    });
  });

}
