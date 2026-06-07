import 'dart:developer';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'package:thermal_printer_flutter/src/network_printer.dart';
import 'printer_repository.dart';

class NetworkPrinterRepository implements PrinterRepository {
  /// Cria o repositório de impressoras de rede.
  ///
  /// [connector] e [interfaceLister] são seams de testabilidade repassados ao
  /// [NetworkPrinter]; em produção ficam nulos e os defaults reais (sockets e
  /// interfaces de rede) são usados.
  NetworkPrinterRepository({
    SocketConnector? connector,
    NetworkInterfaceLister? interfaceLister,
  })  : _connector = connector,
        _interfaceLister = interfaceLister;

  final SocketConnector? _connector;
  final NetworkInterfaceLister? _interfaceLister;
  final Map<String, NetworkPrinter> _networkPrinters = {};

  @override
  Future<List<Printer>> getPrinters() async {
    // Para impressoras de rede, o usuário precisa fornecer IP e porta manualmente
    return [];
  }

  /// Descobre impressoras automaticamente na rede local
  Future<List<Printer>> discoverNetworkPrinters({
    Function(String)? onProgress,
  }) async {
    try {
      log('Iniciando descoberta automática de impressoras na rede...', name: 'THERMAL_PRINTER_FLUTTER');

      final discoveredPrinters = await NetworkPrinter.discoverPrinters(
        onProgress: onProgress,
        connector: _connector,
        interfaceLister: _interfaceLister,
      );

      final printers = discoveredPrinters.map((printerInfo) {
        return Printer(
          type: PrinterType.network,
          name: printerInfo.name,
          ip: printerInfo.ip,
          port: printerInfo.port.toString(),
        );
      }).toList();

      log('Descoberta concluída. Encontradas ${printers.length} impressoras', name: 'THERMAL_PRINTER_FLUTTER');
      return printers;
      // coverage:ignore-start
      // Guarda defensiva: NetworkPrinter.discoverPrinters trata seus próprios
      // erros internamente, então este catch não é alcançável em teste unitário.
    } catch (e) {
      log('Erro durante descoberta de impressoras: $e', name: 'THERMAL_PRINTER_FLUTTER');
      return [];
    }
    // coverage:ignore-end
  }

  @override
  Future<bool> connect(Printer printer) async {
    try {
      if (printer.ip.isEmpty) {
        log('Error: IP address is required for network printer', name: 'THERMAL_PRINTER_FLUTTER');
        return false;
      }

      final key = '${printer.ip}:${printer.port}';

      // Remove conexão anterior se existir
      if (_networkPrinters.containsKey(key)) {
        await _networkPrinters[key]!.disconnect();
        _networkPrinters.remove(key);
      }

      final networkPrinter = NetworkPrinter(
        host: printer.ip,
        port: int.tryParse(printer.port) ?? 9100,
        timeout: const Duration(seconds: 10),
        connector: _connector,
      );

      final connected = await networkPrinter.connect();
      if (connected) {
        _networkPrinters[key] = networkPrinter;
        log('Successfully connected to network printer at ${printer.ip}:${printer.port}', name: 'THERMAL_PRINTER_FLUTTER');
      } else {
        log('Failed to connect to network printer at ${printer.ip}:${printer.port}', name: 'THERMAL_PRINTER_FLUTTER');
      }

      return connected;
      // coverage:ignore-start
      // Guarda defensiva: os colaboradores (NetworkPrinter) não relançam, então
      // este catch não é alcançável em teste unitário.
    } catch (e) {
      log('Error connecting network printer: $e', name: 'THERMAL_PRINTER_FLUTTER');
      return false;
    }
    // coverage:ignore-end
  }

  @override
  Future<void> disconnect(Printer printer) async {
    try {
      final key = '${printer.ip}:${printer.port}';
      if (_networkPrinters.containsKey(key)) {
        await _networkPrinters[key]!.disconnect();
        _networkPrinters.remove(key);
        log('Disconnected from network printer at ${printer.ip}:${printer.port}', name: 'THERMAL_PRINTER_FLUTTER');
      }
      // coverage:ignore-start
      // Guarda defensiva: NetworkPrinter.disconnect já engole seus erros.
    } catch (e) {
      log('Error disconnecting network printer: $e', name: 'THERMAL_PRINTER_FLUTTER');
    }
    // coverage:ignore-end
  }

  @override
  Future<void> printBytes({required List<int> bytes, required Printer printer}) async {
    try {
      final key = '${printer.ip}:${printer.port}';
      NetworkPrinter? networkPrinter = _networkPrinters[key];

      // Se não há conexão ativa, tenta conectar
      if (networkPrinter == null || !networkPrinter.isConnected) {
        final connected = await connect(printer);
        if (!connected) {
          throw Exception('Failed to connect to network printer');
        }
        networkPrinter = _networkPrinters[key]!;
      }

      final success = await networkPrinter.printBytes(bytes, disconnectAfterPrint: false);

      if (!success) {
        log('Failed to print via network', name: 'THERMAL_PRINTER_FLUTTER');
        throw Exception('Failed to print to network printer');
      }
    } catch (e) {
      log('Error printing via network: $e', name: 'THERMAL_PRINTER_FLUTTER');
      rethrow;
    }
  }

  @override
  Future<bool> isConnected(Printer printer) async {
    try {
      final key = '${printer.ip}:${printer.port}';
      final networkPrinter = _networkPrinters[key];
      if (networkPrinter == null) return false;
      // Remove conexões mortas do pool para não vazar entradas acumuladas.
      if (!networkPrinter.isConnected) {
        _networkPrinters.remove(key);
        return false;
      }
      return true;
      // coverage:ignore-start
      // Guarda defensiva: acesso ao mapa não lança.
    } catch (e) {
      log('Error checking network connection: $e', name: 'THERMAL_PRINTER_FLUTTER');
      return false;
    }
    // coverage:ignore-end
  }
}
