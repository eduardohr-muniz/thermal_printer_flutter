import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:thermal_printer_flutter/src/network_printer.dart';

class _MockSocket extends Mock implements Socket {}

class _FakeInternetAddress extends Fake implements InternetAddress {
  _FakeInternetAddress(this.address, {this.isLoopback = false});

  @override
  final String address;
  @override
  InternetAddressType get type => InternetAddressType.IPv4;
  @override
  final bool isLoopback;
}

class _FakeNetworkInterface extends Fake implements NetworkInterface {
  _FakeNetworkInterface(this.name, this.addresses);

  @override
  final String name;
  @override
  final List<InternetAddress> addresses;
}

void main() {
  setUpAll(() {
    registerFallbackValue(<int>[]);
  });

  _MockSocket buildSocket() {
    final socket = _MockSocket();
    when(() => socket.add(any())).thenReturn(null);
    when(() => socket.flush()).thenAnswer((_) async {});
    when(() => socket.close()).thenAnswer((_) async {});
    return socket;
  }

  group('NetworkPrinter constructor / getters', () {
    test('exposes host and port and defaults', () {
      final printer = NetworkPrinter(host: '10.0.0.1');

      expect(printer.host, '10.0.0.1');
      expect(printer.port, 9100);
      expect(printer.isConnected, isFalse);
    });

    test('respects a custom port', () {
      final printer = NetworkPrinter(host: '10.0.0.1', port: 515);

      expect(printer.port, 515);
    });
  });

  group('connect', () {
    test('connects via the injected connector and reports connected', () async {
      final socket = buildSocket();
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            socket,
      );

      expect(await printer.connect(), isTrue);
      expect(printer.isConnected, isTrue);
    });

    test('returns true immediately when already connected', () async {
      var connectCount = 0;
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async {
          connectCount++;
          return buildSocket();
        },
      );

      await printer.connect();
      expect(await printer.connect(), isTrue);
      expect(connectCount, 1);
    });

    test('returns false when the connector throws', () async {
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            throw const SocketException('fail'),
      );

      expect(await printer.connect(), isFalse);
      expect(printer.isConnected, isFalse);
    });
  });

  group('printBytes', () {
    test('writes and flushes, then disconnects by default', () async {
      final socket = buildSocket();
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            socket,
      );

      final ok = await printer.printBytes([1, 2, 3]);

      expect(ok, isTrue);
      verify(() => socket.add([1, 2, 3])).called(1);
      verify(() => socket.close()).called(1);
      expect(printer.isConnected, isFalse);
    });

    test('keeps the connection open when disconnectAfterPrint is false',
        () async {
      final socket = buildSocket();
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            socket,
      );

      await printer.connect();
      final ok = await printer.printBytes([9], disconnectAfterPrint: false);

      expect(ok, isTrue);
      expect(printer.isConnected, isTrue);
    });

    test('auto-connects when not connected', () async {
      final socket = buildSocket();
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            socket,
      );

      final ok = await printer.printBytes([1], disconnectAfterPrint: false);

      expect(ok, isTrue);
    });

    test('returns false when reconnection fails', () async {
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            throw const SocketException('no'),
      );

      expect(await printer.printBytes([1]), isFalse);
    });

    test('returns false and disconnects when write throws', () async {
      final socket = buildSocket();
      when(() => socket.add(any())).thenThrow(const SocketException('broken'));
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            socket,
      );

      await printer.connect();
      expect(await printer.printBytes([1]), isFalse);
      expect(printer.isConnected, isFalse);
    });
  });

  group('disconnect', () {
    test('flushes, closes and resets state', () async {
      final socket = buildSocket();
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            socket,
      );

      await printer.connect();
      await printer.disconnect();

      verify(() => socket.close()).called(1);
      expect(printer.isConnected, isFalse);
    });

    test('is safe to call without an active socket', () async {
      final printer = NetworkPrinter(host: '10.0.0.1');

      await printer.disconnect();

      expect(printer.isConnected, isFalse);
    });

    test('swallows errors thrown while closing', () async {
      final socket = buildSocket();
      when(() => socket.close()).thenThrow(const SocketException('close fail'));
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            socket,
      );

      await printer.connect();
      await printer.disconnect();

      expect(printer.isConnected, isFalse);
    });
  });

  group('testConnection', () {
    test('returns true when a socket can be opened and closed', () async {
      final socket = buildSocket();
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            socket,
      );

      expect(await printer.testConnection(), isTrue);
      verify(() => socket.close()).called(1);
    });

    test('returns false when the connector throws', () async {
      final printer = NetworkPrinter(
        host: '10.0.0.1',
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            throw const SocketException('fail'),
      );

      expect(await printer.testConnection(), isFalse);
    });
  });

  group('discoverPrinters', () {
    test('finds a printer using an explicit subnet and reports progress',
        () async {
      final progress = <String>[];
      final printers = await NetworkPrinter.discoverPrinters(
        subnet: '192.168.1.0',
        ports: const [9100],
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async {
          // Only the .50 host "answers".
          if (host == '192.168.1.50') {
            return buildSocket();
          }
          throw const SocketException('refused');
        },
        onProgress: progress.add,
      );

      expect(printers, hasLength(1));
      expect(printers.first.ip, '192.168.1.50');
      expect(printers.first.port, 9100);
      expect(printers.first.description, contains('Raw'));
      expect(progress, contains('Impressora encontrada: 192.168.1.50:9100'));
    });

    test('reports progress and returns empty when nothing answers', () async {
      final progress = <String>[];
      final printers = await NetworkPrinter.discoverPrinters(
        subnet: '192.168.1.0',
        ports: const [9100],
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            throw const SocketException('refused'),
        onProgress: progress.add,
      );

      expect(printers, isEmpty);
      expect(progress, isNotEmpty);
    });

    test('uses the interfaceLister to discover the subnet automatically',
        () async {
      final printers = await NetworkPrinter.discoverPrinters(
        ports: const [9100],
        interfaceLister: () async => [
          _FakeNetworkInterface('en0', [_FakeInternetAddress('192.168.1.5')]),
        ],
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async {
          if (host == '192.168.1.5') return buildSocket();
          throw const SocketException('refused');
        },
      );

      expect(printers.map((p) => p.ip), contains('192.168.1.5'));
    });

    test('falls back to a 10.x interface when no 192.168 wifi/eth match',
        () async {
      final printers = await NetworkPrinter.discoverPrinters(
        ports: const [9100],
        interfaceLister: () async => [
          _FakeNetworkInterface(
              'lo0', [_FakeInternetAddress('127.0.0.1', isLoopback: true)]),
          _FakeNetworkInterface('tun0', [_FakeInternetAddress('10.0.0.7')]),
        ],
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async {
          if (host == '10.0.0.7') return buildSocket();
          throw const SocketException('refused');
        },
      );

      expect(printers.map((p) => p.ip), contains('10.0.0.7'));
    });

    test('falls back to a 172.x interface address', () async {
      final printers = await NetworkPrinter.discoverPrinters(
        ports: const [9100],
        interfaceLister: () async => [
          _FakeNetworkInterface('utun0', [_FakeInternetAddress('172.16.0.4')]),
        ],
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async {
          if (host == '172.16.0.4') return buildSocket();
          throw const SocketException('refused');
        },
      );

      expect(printers.map((p) => p.ip), contains('172.16.0.4'));
    });

    test('returns empty when no subnet can be determined', () async {
      final printers = await NetworkPrinter.discoverPrinters(
        interfaceLister: () async => [],
      );

      expect(printers, isEmpty);
    });

    test('reports an error and returns empty when discovery throws internally',
        () async {
      final progress = <String>[];
      // A subnet without a dot makes the internal baseIp computation throw,
      // which is handled by the outer error handler.
      final printers = await NetworkPrinter.discoverPrinters(
        subnet: 'invalid-subnet',
        ports: const [9100],
        connector: (host, port, {timeout = const Duration(seconds: 5)}) async =>
            buildSocket(),
        onProgress: progress.add,
      );

      expect(printers, isEmpty);
      expect(
          progress.any((m) => m.contains('Erro durante descoberta')), isTrue);
    });

    test('returns empty when interfaceLister throws', () async {
      final printers = await NetworkPrinter.discoverPrinters(
        interfaceLister: () async =>
            throw const SocketException('no interfaces'),
      );

      expect(printers, isEmpty);
    });

    test('maps known ports to descriptions', () async {
      Future<List<NetworkPrinterInfo>> discoverOnPort(int port) {
        return NetworkPrinter.discoverPrinters(
          subnet: '192.168.1.0',
          ports: [port],
          connector: (host, p, {timeout = const Duration(seconds: 5)}) async {
            if (host == '192.168.1.1') return buildSocket();
            throw const SocketException('refused');
          },
        );
      }

      expect((await discoverOnPort(515)).first.description, contains('LPR'));
      expect((await discoverOnPort(631)).first.description, contains('IPP'));
      expect((await discoverOnPort(1234)).first.description, contains('1234'));
    });
  });

  group('NetworkPrinterInfo', () {
    test('toString includes name, address and description', () {
      final info = NetworkPrinterInfo(
        ip: '1.2.3.4',
        port: 9100,
        name: 'Printer',
        description: 'Raw',
      );

      expect(info.toString(), 'Printer - 1.2.3.4:9100 (Raw)');
    });
  });
}
