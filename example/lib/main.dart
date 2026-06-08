// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'package:thermal_printer_flutter_example/src/order_widget.dart';
import 'package:thermal_printer_flutter_example/src/test_print.dart';

void main() {
  runApp(const MyApp());
}

/// Texto longo de exemplo para testar a velocidade/throughput da impressão.
const String _longText = 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '
    'Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.\n'
    'Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris '
    'nisi ut aliquip ex ea commodo consequat.\n'
    'Duis aute irure dolor in reprehenderit in voluptate velit esse '
    'cillum dolore eu fugiat nulla pariatur.\n'
    'Excepteur sint occaecat cupidatat non proident, sunt in culpa qui '
    'officia deserunt mollit anim id est laborum.\n'
    '1234567890 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz\n'
    'A impressao deste bloco serve para medir o tempo de transmissao via '
    'Bluetooth e a velocidade de impressao da bobina.\n'
    'Linha 1 - item de teste .................... R\$ 10,00\n'
    'Linha 2 - item de teste .................... R\$ 20,00\n'
    'Linha 3 - item de teste .................... R\$ 30,00\n'
    'Linha 4 - item de teste .................... R\$ 40,00\n'
    'Linha 5 - item de teste .................... R\$ 50,00\n'
    'Obrigado pela preferencia! Volte sempre.';

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _platformVersion = 'Unknown';
  final _thermalPrinterFlutterPlugin = ThermalPrinterFlutter();
  List<Printer> _printers = [];
  Printer? _selectedPrinter;
  bool _isLoading = false;
  bool _isConnecting = false;
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '9100');
  String? _connectionError;
  MaterialBanner? _currentBanner;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _isDiscovering = false;
  String _discoveryProgress = '';
  bool _isCheckingStatus = false;

  // Opções de impressão / descoberta (casos de uso novos).
  int _copies = 1;
  bool _flipHorizontal = false;
  bool _dither = true;
  bool _requireConfirmation = false;

  // Contexto abaixo do MaterialApp (definido no build via Builder), usado
  // por screenShotWidget (Overlay) e showDialog (Navigator).
  late BuildContext _rootContext;

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  @override
  void dispose() {
    // Fecha conexões de rede em pool ao descartar o plugin.
    _thermalPrinterFlutterPlugin.dispose();
    _ipController.dispose();
    _portController.dispose();
    if (_currentBanner != null) {
      _messengerKey.currentState?.hideCurrentMaterialBanner();
    }
    super.dispose();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    String platformVersion;
    // Platform messages may fail, so we use a try/catch PlatformException.
    // We also handle the message potentially returning null.
    try {
      platformVersion = await _thermalPrinterFlutterPlugin.getPlatformVersion() ?? 'Unknown platform version';
    } on PlatformException {
      platformVersion = 'Failed to get platform version.';
    }

    // If the widget was removed from the tree while the asynchronous platform
    // message was in flight, we want to discard the reply rather than calling
    // setState to update our non-existent appearance.
    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  Future<void> _loadPrinters() async {
    setState(() {
      _isLoading = true;
      _connectionError = null;
    });

    try {
      List<Printer> bluetoothPrinters = [];
      if (!Platform.isWindows) {
        // Check if Bluetooth is enabled
        final isEnabled = await _thermalPrinterFlutterPlugin.isBluetoothEnabled();
        if (!isEnabled) {
          // Request Bluetooth activation
          final enabled = await _thermalPrinterFlutterPlugin.enableBluetooth();
          if (!enabled) {
            setState(() {
              _connectionError = 'Bluetooth was not enabled';
              _isLoading = false;
            });
            return;
          }
        }

        // Check and request Bluetooth permissions
        final hasPermissions = await _thermalPrinterFlutterPlugin.checkBluetoothPermissions();
        if (!hasPermissions) {
          // Try again after a brief delay
          await Future.delayed(const Duration(seconds: 1));
          final retryPermissions = await _thermalPrinterFlutterPlugin.checkBluetoothPermissions();
          if (!retryPermissions) {
            setState(() {
              _connectionError = 'Bluetooth permissions not granted';
              _isLoading = false;
            });
            return;
          }
        }

        // Load Bluetooth printers
        try {
          bluetoothPrinters = await _thermalPrinterFlutterPlugin.getPrinters(printerType: PrinterType.bluetooth);
        } catch (e) {
          print('Error loading Bluetooth printers: $e');
        }
      }

      // Load USB printers
      List<Printer> usbPrinters = [];
      try {
        usbPrinters = await _thermalPrinterFlutterPlugin.getPrinters(printerType: PrinterType.usb);
      } catch (e) {
        print('Error loading USB printers: $e');
      }

      setState(() {
        _printers = [...bluetoothPrinters, ...usbPrinters];
        if (_printers.isNotEmpty) {
          _selectedPrinter = _printers[0];
        }
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _connectionError = 'Error loading printers: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _connectPrinter(Printer printer) async {
    if (printer.type != PrinterType.bluetooth && printer.type != PrinterType.network) {
      return;
    }

    setState(() {
      _isConnecting = true;
      _connectionError = null;
    });

    try {
      if (printer.type == PrinterType.network) {
        print('Tentando conectar à impressora de rede: ${printer.ip}:${printer.port}');
        _showBanner('Conectando à impressora de rede ${printer.ip}:${printer.port}...');
      }

      final connected = await _thermalPrinterFlutterPlugin.connect(printer: printer);

      setState(() {
        final index = _printers.indexWhere((p) =>
            (p.type == PrinterType.bluetooth && p.bleAddress == printer.bleAddress) ||
            (p.type == PrinterType.network && p.ip == printer.ip && p.port == printer.port));
        if (index != -1) {
          _printers[index] = printer.copyWith(isConnected: connected);
          _selectedPrinter = _printers[index];
        }
        _isConnecting = false;
      });

      if (connected) {
        if (printer.type == PrinterType.network) {
          print('Conectado com sucesso à impressora de rede: ${printer.ip}:${printer.port}');
          _showBanner('Conectado com sucesso à impressora de rede!');
        } else {
          _showBanner('Conectado com sucesso à impressora Bluetooth!');
        }
      } else {
        final errorMsg = printer.type == PrinterType.network
            ? 'Falha ao conectar à impressora de rede ${printer.ip}:${printer.port}. Verifique se a impressora está ligada e acessível na rede.'
            : 'Falha ao conectar à impressora Bluetooth';
        print(errorMsg);
        _showBanner(errorMsg, isError: true);
      }
    } catch (e) {
      final errorMsg = printer.type == PrinterType.network
          ? 'Erro ao conectar à impressora de rede ${printer.ip}:${printer.port}: $e'
          : 'Erro ao conectar à impressora Bluetooth: $e';
      print(errorMsg);
      setState(() {
        _connectionError = errorMsg;
        _isConnecting = false;
      });
      _showBanner(errorMsg, isError: true);
    }
  }

  Future<void> _addNetworkPrinter() async {
    if (_ipController.text.isEmpty) return;

    final printer = Printer(
      type: PrinterType.network,
      name: 'Network Printer (${_ipController.text})',
      ip: _ipController.text,
      port: _portController.text,
    );

    setState(() {
      _printers.add(printer);
      _selectedPrinter = printer;
    });

    _ipController.clear();
    _portController.text = '9100';
  }

  /// Monta um recibo ESC/POS. Quando [withImage] é true, captura o
  /// `OrderWidget` como imagem (exercitando `screenShotWidget` + `flipHorizontal`).
  Future<List<int>> _buildReceiptBytes({required bool withImage}) async {
    final generator = Generator(PaperSize.mm80, await CapabilityProfile.load());
    List<int> bytes = [];
    bytes += generator.reset();
    bytes += generator.text('Print Test',
        styles: const PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ));
    bytes += generator.feed(1);
    bytes += generator.text('Date: ${DateTime.now()}');
    bytes += generator.text('Copies: $_copies   Flip: $_flipHorizontal');
    bytes += generator.feed(1);

    // Texto longo (útil para testar throughput/velocidade de impressão).
    bytes += generator.text('--- Texto longo ---', styles: const PosStyles(align: PosAlign.center, bold: true));
    for (final line in _longText.split('\n')) {
      bytes += generator.text(line);
    }
    bytes += generator.feed(1);

    if (withImage && mounted) {
      final image = await _thermalPrinterFlutterPlugin.screenShotWidget(
        _rootContext,
        widget: OrderWidget(),
        pixelRatio: 5.0,
        flipHorizontal: _flipHorizontal,
        dither: _dither,
      );
      bytes += generator.imageRaster(image);
    }

    bytes += generator.feed(2);
    bytes += generator.cut();
    return bytes;
  }

  Future<void> _printTest({required bool withImage}) async {
    if (_selectedPrinter == null) {
      _showBanner('Selecione uma impressora primeiro', isError: true);
      return;
    }

    try {
      // Instrumentação: separa o tempo de GERAÇÃO dos bytes do tempo de ENVIO.
      final sw = Stopwatch()..start();
      final bytes = await _buildReceiptBytes(withImage: withImage);
      final genMs = sw.elapsedMilliseconds;

      sw
        ..reset()
        ..start();
      // `copies` repete o payload num único job (idêntico em toda plataforma).
      await _thermalPrinterFlutterPlugin.printBytes(
        bytes: bytes,
        printer: _selectedPrinter!,
        copies: _copies,
      );
      final sendMs = sw.elapsedMilliseconds;

      final msg = 'gen ${genMs}ms · envio ${sendMs}ms · '
          '${bytes.length}B x$_copies';
      print('TIMING: $msg');
      _showBanner(msg);
    } catch (e) {
      print('Error printing: $e');
      _showBanner('Erro ao imprimir: $e', isError: true);
    }
  }

  /// Imprime o recibo de teste equivalente ao `testprint.dart` do
  /// `blue_thermal_printer` (mesmo layout, montado com ESC/POS) para comparar
  /// a impressão lado a lado. Reaproveita a mesma instrumentação de timing.
  Future<void> _printBlueThermalSample() async {
    if (_selectedPrinter == null) {
      _showBanner('Selecione uma impressora primeiro', isError: true);
      return;
    }

    try {
      final sw = Stopwatch()..start();
      final bytes = await buildBlueThermalSampleReceipt();
      final genMs = sw.elapsedMilliseconds;

      sw
        ..reset()
        ..start();
      await _thermalPrinterFlutterPlugin.printBytes(
        bytes: bytes,
        printer: _selectedPrinter!,
        copies: _copies,
      );
      final sendMs = sw.elapsedMilliseconds;

      final msg = 'blue sample · gen ${genMs}ms · envio ${sendMs}ms · '
          '${bytes.length}B x$_copies';
      print('TIMING: $msg');
      _showBanner(msg);
    } catch (e) {
      print('Error printing blue sample: $e');
      _showBanner('Erro ao imprimir (blue sample): $e', isError: true);
    }
  }

  /// Demonstra `dispose()`: fecha as conexões de rede em pool.
  Future<void> _disposePlugin() async {
    await _thermalPrinterFlutterPlugin.dispose();
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < _printers.length; i++) {
        if (_printers[i].type == PrinterType.network) {
          _printers[i] = _printers[i].copyWith(isConnected: false);
        }
      }
    });
    _showBanner('dispose() chamado — conexões de rede fechadas');
  }

  void _showBanner(String message, {bool isError = false}) {
    if (!mounted) return;

    // Remove current banner if exists
    if (_currentBanner != null) {
      _messengerKey.currentState?.hideCurrentMaterialBanner();
    }

    // Create and show new banner
    _currentBanner = MaterialBanner(
      content: Text(message),
      backgroundColor: isError ? Colors.red.shade100 : Colors.green.shade100,
      contentTextStyle: TextStyle(
        color: isError ? Colors.red.shade900 : Colors.green.shade900,
        fontWeight: FontWeight.bold,
      ),
      actions: [
        TextButton(
          onPressed: () {
            _messengerKey.currentState?.hideCurrentMaterialBanner();
            _currentBanner = null;
          },
          child: const Text('OK'),
        ),
      ],
    );

    _messengerKey.currentState?.showMaterialBanner(_currentBanner!);
  }

  Future<void> _checkBluetoothStatus() async {
    try {
      final isEnabled = await _thermalPrinterFlutterPlugin.isBluetoothEnabled();
      if (!mounted) return;
      _showBanner(
        isEnabled ? 'Bluetooth is enabled' : 'Bluetooth is disabled',
        isError: !isEnabled,
      );
    } catch (e) {
      if (!mounted) return;
      _showBanner('Error checking Bluetooth status: $e', isError: true);
    }
  }

  Future<void> _checkBluetoothPermissions() async {
    try {
      final hasPermissions = await _thermalPrinterFlutterPlugin.checkBluetoothPermissions();
      if (!mounted) return;
      _showBanner(
        hasPermissions ? 'Bluetooth permissions granted' : 'Bluetooth permissions not granted',
        isError: !hasPermissions,
      );
    } catch (e) {
      if (!mounted) return;
      _showBanner('Error checking Bluetooth permissions: $e', isError: true);
    }
  }

  Future<void> _enableBluetooth() async {
    try {
      final enabled = await _thermalPrinterFlutterPlugin.enableBluetooth();
      if (!mounted) return;
      _showBanner(
        enabled ? 'Bluetooth enabled successfully' : 'Failed to enable Bluetooth',
        isError: !enabled,
      );
    } catch (e) {
      if (!mounted) return;
      _showBanner('Error enabling Bluetooth: $e', isError: true);
    }
  }

  Future<void> _testNetworkConnection() async {
    if (_ipController.text.isEmpty) {
      _showBanner('Por favor, insira um endereço IP', isError: true);
      return;
    }

    setState(() {
      _isConnecting = true;
      _connectionError = null;
    });

    try {
      final ip = _ipController.text;
      final port = _portController.text;
      _showBanner('Testando conectividade com $ip:$port...');

      // Testa conectividade usando Socket diretamente
      final socket = await Socket.connect(ip, int.tryParse(port) ?? 9100, timeout: const Duration(seconds: 5));
      await socket.close();

      _showBanner('Conectividade OK! A impressora está acessível na rede.');
    } catch (e) {
      print('Teste de conectividade falhou: $e');
      _showBanner('Teste de conectividade falhou: $e. Verifique o IP, porta e se a impressora está ligada.', isError: true);
    } finally {
      setState(() {
        _isConnecting = false;
      });
    }
  }

  Future<void> _discoverNetworkPrinters() async {
    setState(() {
      _isDiscovering = true;
      _discoveryProgress = 'Iniciando descoberta...';
      _connectionError = null;
    });

    try {
      print('Iniciando descoberta automática de impressoras na rede...');

      final discoveredPrinters = await _thermalPrinterFlutterPlugin.discoverNetworkPrinters(
        requireConfirmation: _requireConfirmation,
        onProgress: (progress) {
          setState(() {
            _discoveryProgress = progress;
          });
          print('Progress: $progress');
        },
      );

      setState(() {
        // Remove impressoras de rede existentes para evitar duplicatas
        _printers
          ..removeWhere((printer) => printer.type == PrinterType.network)
          // Adiciona as impressoras descobertas
          ..addAll(discoveredPrinters);

        if (discoveredPrinters.isNotEmpty && _selectedPrinter == null) {
          _selectedPrinter = discoveredPrinters.first;
        }

        _isDiscovering = false;
        _discoveryProgress = '';
      });

      if (discoveredPrinters.isEmpty) {
        _showBanner('Nenhuma impressora encontrada na rede. Verifique se as impressoras estão ligadas e conectadas à mesma rede.');
      } else {
        _showBanner('Encontradas ${discoveredPrinters.length} impressoras na rede!');
      }

      print('Descoberta concluída. Encontradas ${discoveredPrinters.length} impressoras');
    } catch (e) {
      print('Erro durante descoberta: $e');
      setState(() {
        _connectionError = 'Erro durante descoberta: $e';
        _isDiscovering = false;
        _discoveryProgress = '';
      });
      _showBanner('Erro durante descoberta: $e', isError: true);
    }
  }

  Future<void> _fetchPrinterStatus() async {
    if (_selectedPrinter == null) {
      _showBanner('Selecione uma impressora primeiro', isError: true);
      return;
    }

    if (_selectedPrinter!.type != PrinterType.usb) {
      _showBanner('Leitura de status disponível apenas para impressoras USB (Windows/macOS)', isError: true);
      return;
    }

    setState(() {
      _isCheckingStatus = true;
    });

    try {
      final status = await _thermalPrinterFlutterPlugin.getPrinterStatus(printer: _selectedPrinter!);
      if (!mounted) return;

      await showDialog<void>(
        context: _rootContext,
        builder: (context) {
          return AlertDialog(
            title: Text('Status da impressora\n${_selectedPrinter!.name}', textAlign: TextAlign.center),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStatusRow('Possui status', status.hasStatus),
                _buildStatusRow('Erro', status.hasError),
                _buildStatusRow('Sem papel', status.isPaperOut),
                _buildStatusRow('Papel travado', status.isPaperJam),
                _buildStatusRow('Tampa aberta', status.isDoorOpen),
                _buildStatusRow('Offline', status.isOffline),
                _buildStatusRow('Pouco papel', status.isPaperLow),
                _buildStatusRow('Intervenção necessária', status.needsUserAction),
                const SizedBox(height: 12),
                Text(
                  status.description.isEmpty ? 'Sem detalhes adicionais.' : status.description,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Código bruto: ${status.rawStatus}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Fechar'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      _showBanner('Erro ao consultar status: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingStatus = false;
        });
      }
    }
  }

  Widget _buildStatusRow(String label, bool value) {
    final color = value ? Colors.red.shade600 : Colors.green.shade600;
    final text = value ? 'Sim' : 'Não';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Chip(
            label: Text(
              text,
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: color,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: _messengerKey,
      // `Builder` dá um contexto ABAIXO do MaterialApp — necessário para
      // `screenShotWidget` (Overlay.of) e `showDialog` (Navigator.of).
      home: Builder(builder: (context) {
        _rootContext = context;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Thermal Printer Example'),
          ),
          body: Padding(
            padding: const EdgeInsets.all(16.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Running on: $_platformVersion\n'),
                  if (_connectionError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        _connectionError!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  const SizedBox(height: 20),
                  if (!Platform.isWindows) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _checkBluetoothStatus,
                          icon: const Icon(Icons.bluetooth),
                          label: const Text('Check Bluetooth'),
                        ),
                        ElevatedButton.icon(
                          onPressed: _checkBluetoothPermissions,
                          icon: const Icon(Icons.security),
                          label: const Text('Check Permissions'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _enableBluetooth,
                          icon: const Icon(Icons.bluetooth_connected),
                          label: const Text('Enable Bluetooth'),
                        ),
                        ElevatedButton.icon(
                          onPressed: _checkBluetoothPermissions,
                          icon: const Icon(Icons.security_update),
                          label: const Text('Request Permissions'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _loadPrinters,
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Load Printers'),
                  ),
                  const SizedBox(height: 20),
                  if (_printers.isNotEmpty) ...[
                    const Text('Select a printer:'),
                    const SizedBox(height: 10),
                    DropdownButton<Printer>(
                      value: _selectedPrinter,
                      items: _printers.map((printer) {
                        return DropdownMenuItem<Printer>(
                          value: printer,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                printer.type == PrinterType.bluetooth
                                    ? Icons.bluetooth
                                    : printer.type == PrinterType.network
                                        ? Icons.language
                                        : Icons.usb,
                                color: printer.type == PrinterType.bluetooth
                                    ? (printer.isConnected ? Colors.blue : Colors.grey)
                                    : printer.type == PrinterType.network
                                        ? (printer.isConnected ? Colors.green : Colors.grey)
                                        : Colors.black,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  printer.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (printer.type == PrinterType.bluetooth || printer.type == PrinterType.network)
                                Text(
                                  printer.isConnected ? ' (Connected)' : ' (Disconnected)',
                                  style: TextStyle(
                                    color: printer.isConnected ? Colors.green : Colors.red,
                                  ),
                                ),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: _isConnecting
                          ? null
                          : (newValue) {
                              if (newValue != null) {
                                setState(() {
                                  _selectedPrinter = newValue;
                                });
                                if ((newValue.type == PrinterType.bluetooth || newValue.type == PrinterType.network) && !newValue.isConnected) {
                                  _connectPrinter(newValue);
                                }
                              }
                            },
                    ),
                    const SizedBox(height: 20),
                    if (_isConnecting)
                      const Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 8),
                          Text('Connecting...'),
                        ],
                      )
                    else ...[
                      // Opções de impressão (cópias + espelhamento).
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('Cópias (copies):'),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.remove_circle_outline),
                                        onPressed: _copies > 1 ? () => setState(() => _copies--) : null,
                                      ),
                                      Text('$_copies', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                      IconButton(
                                        icon: const Icon(Icons.add_circle_outline),
                                        onPressed: _copies < 10 ? () => setState(() => _copies++) : null,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Espelhar imagem (flipHorizontal)'),
                                value: _flipHorizontal,
                                onChanged: (v) => setState(() => _flipHorizontal = v),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Dithering Floyd–Steinberg (melhor p/ imagens)'),
                                subtitle: const Text(
                                  'Reamostra por média + difusão de erro',
                                  style: TextStyle(fontSize: 11),
                                ),
                                value: _dither,
                                onChanged: (v) => setState(() => _dither = v),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          ElevatedButton.icon(
                            onPressed: (_selectedPrinter?.isConnected == true || _selectedPrinter?.type == PrinterType.usb)
                                ? () => _printTest(withImage: true)
                                : null,
                            icon: const Icon(Icons.image),
                            label: const Text('Print (imagem)'),
                          ),
                          ElevatedButton.icon(
                            onPressed: (_selectedPrinter?.isConnected == true || _selectedPrinter?.type == PrinterType.usb)
                                ? () => _printTest(withImage: false)
                                : null,
                            icon: const Icon(Icons.text_fields),
                            label: const Text('Print (texto)'),
                          ),
                          ElevatedButton.icon(
                            onPressed: (_selectedPrinter?.isConnected == true || _selectedPrinter?.type == PrinterType.usb)
                                ? _printBlueThermalSample
                                : null,
                            icon: const Icon(Icons.receipt_long),
                            label: const Text('Print (blue sample)'),
                          ),
                          ElevatedButton(
                            onPressed: _selectedPrinter?.isConnected == true
                                ? () async {
                                    try {
                                      await _thermalPrinterFlutterPlugin.disconnect(printer: _selectedPrinter!);
                                      setState(() {
                                        final index = _printers.indexWhere((p) => p == _selectedPrinter);
                                        if (index != -1) {
                                          _printers[index] = _printers[index].copyWith(isConnected: false);
                                          _selectedPrinter = _printers[index];
                                        }
                                      });
                                      _showBanner('Impressora desconectada com sucesso');
                                    } catch (e) {
                                      _showBanner('Erro ao desconectar impressora: $e', isError: true);
                                    }
                                  }
                                : null,
                            child: const Text('Desconectar'),
                          ),
                          ElevatedButton.icon(
                            onPressed: (_selectedPrinter != null && _selectedPrinter!.type == PrinterType.usb && !_isCheckingStatus)
                                ? _fetchPrinterStatus
                                : null,
                            icon: _isCheckingStatus
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.info_outline),
                            label: const Text('Status (USB)'),
                          ),
                        ],
                      ),
                    ],
                  ],
                  const SizedBox(height: 20),
                  // Seção para descoberta automática de impressoras
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Descoberta Automática de Impressoras',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Escaneia a rede local procurando por impressoras nas portas comuns (9100, 515, 631)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Somente confirmadas '
                                '(requireConfirmation)'),
                            subtitle: const Text(
                              'Confirma via sonda ESC/POS na porta 9100 e '
                              'descarta falsos positivos',
                              style: TextStyle(fontSize: 11),
                            ),
                            value: _requireConfirmation,
                            onChanged: (v) => setState(() => _requireConfirmation = v),
                          ),
                          const SizedBox(height: 16),
                          if (_isDiscovering) ...[
                            const LinearProgressIndicator(),
                            const SizedBox(height: 8),
                            Text(
                              _discoveryProgress,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ] else ...[
                            ElevatedButton.icon(
                              onPressed: _discoverNetworkPrinters,
                              icon: const Icon(Icons.search),
                              label: const Text('Descobrir Impressoras na Rede'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Seção para adicionar impressora manualmente
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Adicionar Impressora Manualmente',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _ipController,
                                  decoration: const InputDecoration(
                                    labelText: 'Printer IP',
                                    hintText: '192.168.1.100',
                                  ),
                                  keyboardType: TextInputType.number,
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 100,
                                child: TextField(
                                  controller: _portController,
                                  decoration: const InputDecoration(
                                    labelText: 'Port',
                                  ),
                                  keyboardType: TextInputType.number,
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _isConnecting ? null : _testNetworkConnection,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue,
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text('Testar'),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _addNetworkPrinter,
                                child: const Text('Adicionar'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    onPressed: _disposePlugin,
                    icon: const Icon(Icons.cleaning_services_outlined),
                    label: const Text('dispose() — fechar conexões de rede'),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}
