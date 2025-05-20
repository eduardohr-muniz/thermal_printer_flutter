// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'package:thermal_printer_flutter_example/src/order_widget.dart';

void main() {
  runApp(MaterialApp(home: const MyApp()));
}

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

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  @override
  void dispose() {
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
          bluetoothPrinters = await _thermalPrinterFlutterPlugin.getPrinters(printerType: PrinterType.bluethoot);
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
    if (printer.type != PrinterType.bluethoot && printer.type != PrinterType.network) return;

    setState(() {
      _isConnecting = true;
      _connectionError = null;
    });

    try {
      final connected = await _thermalPrinterFlutterPlugin.connect(printer: printer);
      setState(() {
        final index = _printers.indexWhere((p) =>
            (p.type == PrinterType.bluethoot && p.bleAddress == printer.bleAddress) ||
            (p.type == PrinterType.network && p.ip == printer.ip && p.port == printer.port));
        if (index != -1) {
          _printers[index] = printer.copyWith(isConnected: connected);
          _selectedPrinter = _printers[index];
        }
        _isConnecting = false;
      });
    } catch (e) {
      setState(() {
        _connectionError = 'Error connecting printer: $e';
        _isConnecting = false;
      });
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

  Future<void> _printTest() async {
    if (_selectedPrinter == null) return;

    try {
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
      bytes += generator.feed(2);
      bytes += generator.text('Date: ${DateTime.now()}');
      bytes += generator.feed(2);
      bytes += generator.text('This is a test print');
      bytes += generator.feed(2);
      bytes += generator.cut();
      if (mounted) {
        final image = await _thermalPrinterFlutterPlugin.screenShotWidget(
          context,
          widget: OrderWidget(),
          pixelRatio: 5.0,
        );
        bytes += generator.imageRaster(image);
      }

      bytes += generator.feed(2);
      bytes += generator.cut();
      await _thermalPrinterFlutterPlugin.printBytes(bytes: bytes, printer: _selectedPrinter!);
    } catch (e) {
      print('Error printing: $e');
    }
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      scaffoldMessengerKey: _messengerKey,
      home: Scaffold(
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
                      onPressed: _addNetworkPrinter,
                      child: const Text('Add'),
                    ),
                  ],
                ),
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
                              printer.type == PrinterType.bluethoot
                                  ? Icons.bluetooth
                                  : printer.type == PrinterType.network
                                      ? Icons.language
                                      : Icons.usb,
                              color: printer.type == PrinterType.bluethoot
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
                            if (printer.type == PrinterType.bluethoot || printer.type == PrinterType.network)
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
                              if ((newValue.type == PrinterType.bluethoot || newValue.type == PrinterType.network) && !newValue.isConnected) {
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
                  else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton(
                          onPressed: _selectedPrinter?.isConnected == true ? _printTest : null,
                          child: const Text('Print Test'),
                        ),
                        const SizedBox(width: 10),
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
                      ],
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
