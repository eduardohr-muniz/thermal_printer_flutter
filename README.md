# THERMAL PRINTER FLUTTER

Flutter plugin for thermal printing with support for multiple platforms and connection types.

## Support

| Platform | USB | Bluetooth | Network |
| -------- | --- | --------- | ------- |
| Android  | ❌  | ✅        | ✅      |
| iOS      | ❌  | ✅        | ✅      |
| macOS    | ❌  | ✅        | ✅      |
| Windows  | ✅  | ❌        | ✅      |
| Linux    | ❌  | ❌        | ✅      |
| Web      | ❌  | ❌        | 🚧      |

## Features

- **Multiple Connection Types**: Support for USB, Bluetooth, and Network printers
- **Cross-Platform**: Works on Android, iOS, macOS, Windows, and Linux
- **Automatic Network Discovery**: Automatically discover network printers on your local network
- **Manual Network Configuration**: Add network printers manually with IP and port
- **Real-time Progress**: Get progress updates during network discovery
- **ESC/POS Compatible**: Full support for ESC/POS thermal printer commands
- **Image Printing**: Print images and widgets directly to thermal printers

## Project Setup

### Android

1. Add the following permissions to the `android/app/src/main/AndroidManifest.xml` file:

```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.INTERNET" />
```

2. For Android 12 or higher, also add:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
```

### iOS

1. Add the following keys to the `ios/Runner/Info.plist` file:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>We need Bluetooth access to connect to thermal printers</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>We need Bluetooth access to connect to thermal printers</string>
```

2. For iOS 13 or higher, also add:

```xml
<key>NSBluetoothAlwaysAndWhenInUseUsageDescription</key>
<string>We need Bluetooth access to connect to thermal printers</string>
```

### macOS

1. Add the following keys to the `macos/Runner/Info.plist` file:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>We need Bluetooth access to connect to thermal printers</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>We need Bluetooth access to connect to thermal printers</string>
```

2. Add the following keys to the `macos/Runner/DebugProfile.entitlements` file:

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
```

3. Add the following keys to the `macos/Runner/Release.entitlements` file:

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
```

### Windows

1. For USB printers, ensure the printer drivers are installed.
2. For Bluetooth printers, Windows must support Bluetooth LE (Bluetooth 4.0 or higher).

### Linux

1. For network printers, ensure that the firewall allows connections on port 9100 (or the configured port).

### Web

1. For network printers, ensure that the web server allows WebSocket connections.
2. Add the following script to the `web/index.html` file:

```html
<script>
  if ("serviceWorker" in navigator) {
    window.addEventListener("flutter-first-frame", function () {
      navigator.serviceWorker.register("flutter_service_worker.js");
    });
  }
</script>
```

## Usage

### Basic Setup

```dart
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';

// Create an instance of the plugin
final thermalPrinter = ThermalPrinterFlutter();
Printer? _selectedPrinter;
```

### Getting Printers

```dart
// Bluetooth printers (Android, iOS, macOS)
final bluetoothPrinters = await thermalPrinter.getPrinters(printerType: PrinterType.bluethoot);

// USB printers (Windows)
final usbPrinters = await thermalPrinter.getPrinters(printerType: PrinterType.usb);

// Network printers - Manual addition only
// Use the discovery method below for automatic detection
```

### 🔍 Network Printer Discovery (NEW!)

Automatically discover network printers on your local network:

```dart
// Discover printers automatically
final networkPrinters = await thermalPrinter.discoverNetworkPrinters(
  onProgress: (progress) {
    print('Discovery progress: $progress');
  },
);

// The discovery scans common printer ports:
// - 9100 (Raw TCP/IP - most common for thermal printers)
// - 515 (LPR/LPD)
// - 631 (IPP - Internet Printing Protocol)
```

### Manual Network Printer Addition

```dart
// Add a network printer manually
final networkPrinter = Printer(
  type: PrinterType.network,
  name: 'My Network Printer',
  ip: '192.168.1.100',
  port: '9100',
);
```

### Connecting to Printers

```dart
// Connect to any printer (Bluetooth or Network)
final connected = await thermalPrinter.connect(printer: selectedPrinter);

// Check connection status
final isConnected = await thermalPrinter.isConnected(printer: selectedPrinter);

// Disconnect from printer
await thermalPrinter.disconnect(printer: selectedPrinter);
```

### Printing

```dart
Future<void> _printTest({
  required ThermalPrinterFlutter termalPrinter,  
  required Printer printer
}) async {
  try {
    final generator = Generator(PaperSize.mm80, await CapabilityProfile.load());
    List<int> bytes = [];

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

    await termalPrinter.printBytes(bytes: bytes, printer: printer);

  } catch (e) {
    print('Error printing: $e');
  }
}
```

### Image and Widget Printing

```dart
// Print a Flutter widget as an image
final image = await thermalPrinter.screenShotWidget(
  context,
  widget: MyCustomWidget(),
  pixelRatio: 3.0,
);

// Convert to thermal printer format
final generator = Generator(PaperSize.mm80, await CapabilityProfile.load());
List<int> bytes = [];
bytes += generator.imageRaster(image);
bytes += generator.cut();

await thermalPrinter.printBytes(bytes: bytes, printer: printer);
```

## Network Discovery Details

The automatic network discovery feature:

- **Automatically detects your local network** (Wi-Fi/Ethernet)
- **Scans all IP addresses** in your subnet (e.g., 192.168.1.1 to 192.168.1.254)
- **Tests multiple ports** commonly used by thermal printers
- **Provides real-time progress** updates during scanning
- **Works on all platforms** that support network printing

### Supported Network Protocols

| Port | Protocol | Description |
|------|----------|-------------|
| 9100 | Raw TCP/IP | Most common for thermal printers |
| 515  | LPR/LPD | Line Printer Remote/Line Printer Daemon |
| 631  | IPP | Internet Printing Protocol |

## Dependency Compatibility

If you are using the packages below, we recommend using these specific versions for better compatibility:

```yaml
dependencies:
  web: ^0.5.1
  image: ^4.5.4
```

## Example

Check out the complete example at `example/lib/main.dart` for a sample implementation with a graphical interface including:

- Automatic network printer discovery
- Manual network printer addition
- Bluetooth printer connectivity
- Real-time connection status
- Test printing functionality

## Contribution

Contributions are welcome! Feel free to open issues or submit pull requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
