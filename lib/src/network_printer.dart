import 'dart:io';
import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

/// Abre uma conexão de socket TCP com [host]:[port].
///
/// Seam de testabilidade: permite injetar uma implementação fake nos
/// testes para evitar I/O real. Padrão: [Socket.connect].
typedef SocketConnector = Future<Socket> Function(String host, int port,
    {Duration timeout});

/// Lista as interfaces de rede disponíveis.
///
/// Seam de testabilidade para [NetworkPrinter.discoverPrinters].
/// Padrão: [NetworkInterface.list].
typedef NetworkInterfaceLister = Future<List<NetworkInterface>> Function();

Future<Socket> _defaultSocketConnector(String host, int port,
    {Duration timeout = const Duration(seconds: 5)}) {
  return Socket.connect(host, port, timeout: timeout);
}

Future<List<NetworkInterface>> _defaultInterfaceLister() =>
    NetworkInterface.list();

/// Cliente TCP para impressoras de rede (raw socket).
class NetworkPrinter {
  late String _host;
  int _port = 9100;
  bool _isConnected = false;
  Duration _timeout = const Duration(seconds: 5);
  Socket? _socket;
  final SocketConnector _connector;

  /// Cria um [NetworkPrinter] para [host]:[port].
  ///
  /// [connector] permite injetar a abertura de socket nos testes;
  /// por padrão usa [Socket.connect].
  NetworkPrinter({
    required String host,
    int port = 9100,
    Duration timeout = const Duration(seconds: 5),
    SocketConnector? connector,
  }) : _connector = connector ?? _defaultSocketConnector {
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

      log('Tentando conectar à impressora de rede em $_host:$_port',
          name: 'NETWORK_PRINTER');

      _socket = await _connector(_host, _port, timeout: _timeout);
      _isConnected = true;

      log('Conectado com sucesso à impressora de rede em $_host:$_port',
          name: 'NETWORK_PRINTER');
      return true;
    } catch (e) {
      log('Erro ao conectar à impressora de rede em $_host:$_port: $e',
          name: 'NETWORK_PRINTER');
      _isConnected = false;
      _socket = null;
      return false;
    }
  }

  Future<bool> printBytes(List<int> bytes,
      {bool disconnectAfterPrint = true}) async {
    try {
      // Verifica se está conectado
      if (!_isConnected || _socket == null) {
        log('Tentando reconectar antes de imprimir...',
            name: 'NETWORK_PRINTER');
        final connected = await connect();
        if (!connected) {
          log('Falha ao conectar para impressão', name: 'NETWORK_PRINTER');
          return false;
        }
      }

      log('Enviando ${bytes.length} bytes para impressão',
          name: 'NETWORK_PRINTER');

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
      log('Erro ao desconectar impressora de rede: $e',
          name: 'NETWORK_PRINTER');
    } finally {
      _socket = null;
      _isConnected = false;
    }
  }

  /// Indica se há uma conexão de socket ativa.
  bool get isConnected => _isConnected && _socket != null;

  /// Host da impressora.
  String get host => _host;

  /// Porta da impressora.
  int get port => _port;

  /// Testa a conectividade abrindo e fechando um socket.
  Future<bool> testConnection() async {
    try {
      final socket = await _connector(_host, _port, timeout: _timeout);
      await socket.close();
      return true;
    } catch (e) {
      log('Teste de conexão falhou para $_host:$_port: $e',
          name: 'NETWORK_PRINTER');
      return false;
    }
  }

  /// Descobre impressoras na rede local escaneando portas comuns.
  ///
  /// [connector] e [interfaceLister] são seams de testabilidade
  /// (padrões: [Socket.connect] e [NetworkInterface.list]).
  /// [requireConfirmation] quando `true`, retorna apenas impressoras
  /// confirmadas via sonda ESC/POS (DLE EOT) na porta 9100. Por padrão
  /// (`false`) mantém o comportamento original de retornar todos os
  /// candidatos com porta aberta, cada um carregando o flag
  /// [NetworkPrinterInfo.confirmed].
  static Future<List<NetworkPrinterInfo>> discoverPrinters({
    String? subnet,
    List<int> ports = const [9100, 515, 631],
    Duration timeout = const Duration(seconds: 2),
    Function(String)? onProgress,
    SocketConnector? connector,
    NetworkInterfaceLister? interfaceLister,
    bool requireConfirmation = false,
  }) async {
    final socketConnector = connector ?? _defaultSocketConnector;
    final List<NetworkPrinterInfo> discoveredPrinters = [];

    try {
      // Se subnet não foi fornecido, tenta descobrir automaticamente
      final networkSubnet = subnet ??
          await _getLocalNetworkSubnet(
              interfaceLister ?? _defaultInterfaceLister);
      if (networkSubnet == null) {
        log('Não foi possível determinar a subnet da rede local',
            name: 'NETWORK_SCANNER');
        return discoveredPrinters;
      }

      log('Iniciando descoberta de impressoras na subnet: $networkSubnet',
          name: 'NETWORK_SCANNER');
      onProgress?.call('Iniciando descoberta na rede $networkSubnet...');

      // Gera lista de IPs para testar (ex: 192.168.1.1 a 192.168.1.254)
      final baseIp = networkSubnet.substring(0, networkSubnet.lastIndexOf('.'));
      final futures = <Future<void>>[];

      for (int i = 1; i <= 254; i++) {
        final ip = '$baseIp.$i';
        futures.add(_testPrinterAtIP(ip, ports, timeout, discoveredPrinters,
            onProgress, socketConnector, requireConfirmation));
      }

      // Executa todos os testes em paralelo (em grupos para não sobrecarregar)
      const batchSize = 20;
      for (int i = 0; i < futures.length; i += batchSize) {
        final batch = futures.skip(i).take(batchSize).toList();
        await Future.wait(batch);

        final progress =
            ((i + batchSize) / futures.length * 100).clamp(0, 100).toInt();
        onProgress?.call('Escaneando rede... $progress%');
      }

      log('Descoberta finalizada. Encontradas ${discoveredPrinters.length} impressoras',
          name: 'NETWORK_SCANNER');
      onProgress?.call(
          'Descoberta finalizada. Encontradas ${discoveredPrinters.length} impressoras');
    } catch (e) {
      log('Erro durante descoberta de impressoras: $e',
          name: 'NETWORK_SCANNER');
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
    SocketConnector connector,
    bool requireConfirmation,
  ) async {
    for (final port in ports) {
      try {
        final socket = await connector(ip, port, timeout: timeout);

        // Na porta 9100 (ESC/POS raw) tentamos confirmar que o host é mesmo
        // uma impressora enviando uma requisição de status em tempo real
        // (DLE EOT 1) e aguardando qualquer resposta. Nas demais portas
        // (515/631) a sonda raw não faz sentido, então não confirmamos.
        bool confirmed = false;
        if (port == 9100) {
          confirmed = await _probeEscPos(socket, timeout);
        } else {
          await socket.close();
        }

        // Se requireConfirmation, descarta candidatos não confirmados.
        if (requireConfirmation && !confirmed) {
          continue;
        }

        final printerInfo = NetworkPrinterInfo(
          ip: ip,
          port: port,
          name: 'Impressora de Rede ($ip:$port)',
          description: _getPortDescription(port),
          confirmed: confirmed,
        );

        discoveredPrinters.add(printerInfo);
        log('Impressora encontrada em $ip:$port (confirmada: $confirmed)',
            name: 'NETWORK_SCANNER');
        onProgress?.call('Impressora encontrada: $ip:$port');

        // Para em caso de sucesso para evitar duplicatas
        break;
      } catch (e) {
        // Falha na conexão é esperada para a maioria dos IPs
        continue;
      }
    }
  }

  /// Envia a requisição de status em tempo real ESC/POS (DLE EOT 1) em
  /// [socket] e aguarda até [timeout] por qualquer byte de resposta.
  ///
  /// Retorna `true` se algum byte for recebido (alta confiança de que o host
  /// é uma impressora ESC/POS); `false` em caso de timeout ou erro no stream.
  /// Sempre fecha o socket antes de retornar.
  static Future<bool> _probeEscPos(Socket socket, Duration timeout) async {
    final completer = Completer<bool>();
    StreamSubscription<Uint8List>? subscription;

    void finish(bool result) {
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    try {
      subscription = socket.listen(
        (data) {
          if (data.isNotEmpty) {
            finish(true);
          }
        },
        onError: (_) => finish(false),
        onDone: () => finish(false),
        cancelOnError: true,
      );

      // DLE EOT 1: requisição de status de impressora em tempo real.
      socket.add(const [0x10, 0x04, 0x01]);
      await socket.flush();

      return await completer.future.timeout(timeout, onTimeout: () => false);
    } catch (e) {
      return false;
    } finally {
      await subscription?.cancel();
      try {
        await socket.close();
      } catch (_) {
        // Ignora erros ao fechar; o resultado da sonda já foi determinado.
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

  /// Verifica se [ip] está em uma faixa IPv4 privada (RFC 1918):
  /// `10.0.0.0/8`, `172.16.0.0/12` ou `192.168.0.0/16`.
  static bool _isPrivateIPv4(String ip) {
    if (ip.startsWith('192.168.') || ip.startsWith('10.')) return true;
    // 172.16.0.0 – 172.31.255.255 (não o intervalo 172.0–15 / 172.32–255).
    if (ip.startsWith('172.')) {
      final parts = ip.split('.');
      final second = parts.length > 1 ? int.tryParse(parts[1]) : null;
      return second != null && second >= 16 && second <= 31;
    }
    return false;
  }

  static Future<String?> _getLocalNetworkSubnet(
      NetworkInterfaceLister interfaceLister) async {
    try {
      final interfaces = await interfaceLister();

      for (final interface in interfaces) {
        // Procura por interface Wi-Fi ou Ethernet ativa
        if (interface.name.toLowerCase().contains('wlan') ||
            interface.name.toLowerCase().contains('eth') ||
            interface.name.toLowerCase().contains('wi-fi') ||
            interface.name.toLowerCase().contains('en0')) {
          for (final address in interface.addresses) {
            if (address.type == InternetAddressType.IPv4 &&
                !address.isLoopback &&
                address.address.startsWith('192.168.')) {
              log('Interface de rede encontrada: ${interface.name} - ${address.address}',
                  name: 'NETWORK_SCANNER');
              return address.address;
            }
          }
        }
      }

      // Fallback: procura qualquer interface IPv4 privada não-loopback.
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type == InternetAddressType.IPv4 &&
              !address.isLoopback &&
              _isPrivateIPv4(address.address)) {
            log('Interface de rede encontrada (fallback): ${interface.name} - ${address.address}',
                name: 'NETWORK_SCANNER');
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

/// Informações de uma impressora de rede descoberta.
class NetworkPrinterInfo {
  /// Endereço IP da impressora.
  final String ip;

  /// Porta na qual a impressora respondeu.
  final int port;

  /// Nome descritivo da impressora.
  final String name;

  /// Descrição do protocolo/porta detectada.
  final String description;

  /// Indica se a impressora foi confirmada via sonda ESC/POS (DLE EOT) na
  /// porta 9100. Para portas 515/631 (onde a sonda raw não se aplica) é
  /// sempre `false`.
  final bool confirmed;

  /// Cria um [NetworkPrinterInfo].
  NetworkPrinterInfo({
    required this.ip,
    required this.port,
    required this.name,
    required this.description,
    this.confirmed = false,
  });

  @override
  String toString() => '$name - $ip:$port ($description)';
}
