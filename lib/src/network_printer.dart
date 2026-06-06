import 'dart:io';
import 'dart:async';
import 'dart:developer';

class NetworkPrinter {
  late String _host;
  int _port = 9100;
  bool _isConnected = false;
  Duration _timeout = const Duration(seconds: 5);
  Socket? _socket;

  NetworkPrinter({
    required String host,
    int port = 9100,
    Duration timeout = const Duration(seconds: 5),
  }) {
    _host = host;
    _port = port;
    _timeout = timeout;
  }

  Future<bool> connect() async {
    try {
      // Se já está conectado, não precisa conectar novamente
      if (_isConnected && _socket != null) {
        return true;
      }

      // Desconecta qualquer conexão anterior
      await disconnect();

      log('Tentando conectar à impressora de rede em $_host:$_port', name: 'NETWORK_PRINTER');

      _socket = await Socket.connect(_host, _port, timeout: _timeout);
      _isConnected = true;

      log('Conectado com sucesso à impressora de rede em $_host:$_port', name: 'NETWORK_PRINTER');
      return true;
    } catch (e) {
      log('Erro ao conectar à impressora de rede em $_host:$_port: $e', name: 'NETWORK_PRINTER');
      _isConnected = false;
      _socket = null;
      return false;
    }
  }

  Future<bool> printBytes(List<int> bytes, {bool disconnectAfterPrint = true}) async {
    try {
      // Verifica se está conectado
      if (!_isConnected || _socket == null) {
        log('Tentando reconectar antes de imprimir...', name: 'NETWORK_PRINTER');
        final connected = await connect();
        if (!connected) {
          log('Falha ao conectar para impressão', name: 'NETWORK_PRINTER');
          return false;
        }
      }

      log('Enviando ${bytes.length} bytes para impressão', name: 'NETWORK_PRINTER');

      _socket!.add(bytes);
      await _socket!.flush();

      log('Bytes enviados com sucesso', name: 'NETWORK_PRINTER');

      if (disconnectAfterPrint) {
        log('Desconectando após impressão...', name: 'NETWORK_PRINTER');
        await disconnect();
      }

      return true;
    } catch (e) {
      log('Erro ao imprimir via rede: $e', name: 'NETWORK_PRINTER');
      // Em caso de erro, força desconexão
      await disconnect();
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      if (_socket != null) {
        log('Desconectando da impressora de rede...', name: 'NETWORK_PRINTER');
        await _socket!.flush();
        await _socket!.close();
        log('Desconectado com sucesso', name: 'NETWORK_PRINTER');
      }
    } catch (e) {
      log('Erro ao desconectar impressora de rede: $e', name: 'NETWORK_PRINTER');
    } finally {
      _socket = null;
      _isConnected = false;
    }
  }

  bool get isConnected => _isConnected && _socket != null;

  String get host => _host;
  int get port => _port;

  // Método para testar conectividade
  Future<bool> testConnection() async {
    try {
      final socket = await Socket.connect(_host, _port, timeout: _timeout);
      await socket.close();
      return true;
    } catch (e) {
      log('Teste de conexão falhou para $_host:$_port: $e', name: 'NETWORK_PRINTER');
      return false;
    }
  }

  // Métodos estáticos para descobrir impressoras na rede
  static Future<List<NetworkPrinterInfo>> discoverPrinters({
    String? subnet,
    List<int> ports = const [9100, 515, 631],
    Duration timeout = const Duration(seconds: 2),
    Function(String)? onProgress,
  }) async {
    final List<NetworkPrinterInfo> discoveredPrinters = [];

    try {
      // Se subnet não foi fornecido, tenta descobrir automaticamente
      final networkSubnet = subnet ?? await _getLocalNetworkSubnet();
      if (networkSubnet == null) {
        log('Não foi possível determinar a subnet da rede local', name: 'NETWORK_SCANNER');
        return discoveredPrinters;
      }

      log('Iniciando descoberta de impressoras na subnet: $networkSubnet', name: 'NETWORK_SCANNER');
      onProgress?.call('Iniciando descoberta na rede $networkSubnet...');

      // Gera lista de IPs para testar (ex: 192.168.1.1 a 192.168.1.254)
      final baseIp = networkSubnet.substring(0, networkSubnet.lastIndexOf('.'));
      final futures = <Future<void>>[];

      for (int i = 1; i <= 254; i++) {
        final ip = '$baseIp.$i';
        futures.add(_testPrinterAtIP(ip, ports, timeout, discoveredPrinters, onProgress));
      }

      // Executa todos os testes em paralelo (em grupos para não sobrecarregar)
      const batchSize = 20;
      for (int i = 0; i < futures.length; i += batchSize) {
        final batch = futures.skip(i).take(batchSize).toList();
        await Future.wait(batch);

        final progress = ((i + batchSize) / futures.length * 100).clamp(0, 100).toInt();
        onProgress?.call('Escaneando rede... $progress%');
      }

      log('Descoberta finalizada. Encontradas ${discoveredPrinters.length} impressoras', name: 'NETWORK_SCANNER');
      onProgress?.call('Descoberta finalizada. Encontradas ${discoveredPrinters.length} impressoras');
    } catch (e) {
      log('Erro durante descoberta de impressoras: $e', name: 'NETWORK_SCANNER');
      onProgress?.call('Erro durante descoberta: $e');
    }

    return discoveredPrinters;
  }

  static Future<void> _testPrinterAtIP(
    String ip,
    List<int> ports,
    Duration timeout,
    List<NetworkPrinterInfo> discoveredPrinters,
    Function(String)? onProgress,
  ) async {
    for (final port in ports) {
      try {
        final socket = await Socket.connect(ip, port, timeout: timeout);
        await socket.close();

        // Se conseguiu conectar, é uma possível impressora
        final printerInfo = NetworkPrinterInfo(
          ip: ip,
          port: port,
          name: 'Impressora de Rede ($ip:$port)',
          description: _getPortDescription(port),
        );

        discoveredPrinters.add(printerInfo);
        log('Impressora encontrada em $ip:$port', name: 'NETWORK_SCANNER');
        onProgress?.call('Impressora encontrada: $ip:$port');

        // Para em caso de sucesso para evitar duplicatas
        break;
      } catch (e) {
        // Falha na conexão é esperada para a maioria dos IPs
        continue;
      }
    }
  }

  static String _getPortDescription(int port) {
    switch (port) {
      case 9100:
        return 'Raw TCP/IP (Padrão)';
      case 515:
        return 'LPR/LPD';
      case 631:
        return 'IPP (Internet Printing Protocol)';
      default:
        return 'Porta $port';
    }
  }

  static Future<String?> _getLocalNetworkSubnet() async {
    try {
      final interfaces = await NetworkInterface.list();

      for (final interface in interfaces) {
        // Procura por interface Wi-Fi ou Ethernet ativa
        if (interface.name.toLowerCase().contains('wlan') || interface.name.toLowerCase().contains('eth') || interface.name.toLowerCase().contains('wi-fi') || interface.name.toLowerCase().contains('en0')) {
          for (final address in interface.addresses) {
            if (address.type == InternetAddressType.IPv4 && !address.isLoopback && address.address.startsWith('192.168.')) {
              log('Interface de rede encontrada: ${interface.name} - ${address.address}', name: 'NETWORK_SCANNER');
              return address.address;
            }
          }
        }
      }

      // Fallback: procura qualquer interface IPv4 não-loopback
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type == InternetAddressType.IPv4 && !address.isLoopback && (address.address.startsWith('192.168.') || address.address.startsWith('10.') || address.address.startsWith('172.'))) {
            log('Interface de rede encontrada (fallback): ${interface.name} - ${address.address}', name: 'NETWORK_SCANNER');
            return address.address;
          }
        }
      }
    } catch (e) {
      log('Erro ao obter interfaces de rede: $e', name: 'NETWORK_SCANNER');
    }

    return null;
  }
}

class NetworkPrinterInfo {
  final String ip;
  final int port;
  final String name;
  final String description;

  NetworkPrinterInfo({
    required this.ip,
    required this.port,
    required this.name,
    required this.description,
  });

  @override
  String toString() => '$name - $ip:$port ($description)';
}
