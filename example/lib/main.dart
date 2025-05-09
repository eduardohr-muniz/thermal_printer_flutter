import 'package:flutter/material.dart';
import 'dart:async';
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

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  @override
  void dispose() {
    _ipController.dispose();
    _portController.dispose();
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
    setState(() => _isLoading = true);
    try {
      final bluetoothPrinters = await _thermalPrinterFlutterPlugin.getPrinters(printerType: PrinterType.bluethoot);
      final usbPrinters = await _thermalPrinterFlutterPlugin.getPrinters(printerType: PrinterType.usb);

      setState(() {
        _printers = [
          ...bluetoothPrinters,
          ...usbPrinters
        ];
        if (_printers.isNotEmpty) {
          _selectedPrinter = _printers[0];
        }
      });
    } catch (e) {
      print('Error loading printers: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _connectPrinter(Printer printer) async {
    if (printer.type != PrinterType.bluethoot && printer.type != PrinterType.network) return;

    setState(() => _isConnecting = true);
    try {
      final connected = await _thermalPrinterFlutterPlugin.connect(printer: printer);
      if (connected) {
        setState(() {
          final index = _printers.indexWhere((p) => (p.type == PrinterType.bluethoot && p.bleAddress == printer.bleAddress) || (p.type == PrinterType.network && p.ip == printer.ip && p.port == printer.port));
          if (index != -1) {
            _printers[index] = printer.copyWith(isConnected: true);
            _selectedPrinter = _printers[index];
          }
        });
      }
    } catch (e) {
      print('Error connecting printer: $e');
    } finally {
      setState(() => _isConnecting = false);
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

      final image = await _thermalPrinterFlutterPlugin.screenShotWidget(
        context,
        widget: OrderWidget(),
        pixelRatio: 5.0,
      );

      bytes += generator.imageRaster(image);

      bytes += generator.feed(2);
      bytes += generator.cut();
      await _thermalPrinterFlutterPlugin.printBytes(bytes: bytes, printer: _selectedPrinter!);
    } catch (e) {
      print('Error printing: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Thermal Printer Example'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Running on: $_platformVersion\n'),
                const SizedBox(height: 20),
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
                  onPressed: _loadPrinters,
                  child: const Text('Load Printers'),
                ),
                const SizedBox(height: 20),
                if (_isLoading)
                  const CircularProgressIndicator()
                else if (_printers.isNotEmpty) ...[
                  const Text('Select a printer:'),
                  const SizedBox(height: 10),
                  DropdownButton<Printer>(
                    value: _selectedPrinter,
                    items: _printers.map((printer) {
                      return DropdownMenuItem<Printer>(
                        value: printer,
                        child: Row(
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
                            Text(printer.name),
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
                    onChanged: (newValue) {
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
                    const CircularProgressIndicator()
                  else
                    ElevatedButton(
                      onPressed: _printTest,
                      child: const Text('Print Test'),
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
