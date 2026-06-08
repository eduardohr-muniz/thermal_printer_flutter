# thermal_printer_flutter

Flutter plugin for ESC/POS thermal printing over **USB**, **Bluetooth (BLE)** and **Network (TCP/IP)** on Android, iOS, macOS, Windows, Linux and Web.

## Platform support

| Platform | USB | Bluetooth | Network |
| -------- | --- | --------- | ------- |
| Android  | ❌  | ✅        | ✅      |
| iOS      | ❌  | ✅        | ✅      |
| macOS    | ✅  | 🚧        | ✅      |
| Windows  | ✅  | ✅        | ✅      |
| Linux    | ❌  | ❌        | ✅      |
| Web      | ❌  | ❌        | 🚧      |

## Install

```yaml
dependencies:
  thermal_printer_flutter: ^0.1.0
```

```dart
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
```

## Permissions & setup per platform

### Android
Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.INTERNET" />
```

Android 12+ also needs:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
```

### iOS
Add to `ios/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>We need Bluetooth access to connect to thermal printers</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>We need Bluetooth access to connect to thermal printers</string>
```

iOS 13+ also needs:

```xml
<key>NSBluetoothAlwaysAndWhenInUseUsageDescription</key>
<string>We need Bluetooth access to connect to thermal printers</string>
```

### macOS
Add the Bluetooth keys to `macos/Runner/Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>We need Bluetooth access to connect to thermal printers</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>We need Bluetooth access to connect to thermal printers</string>
```

Add the entitlements to **both** `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
<key>com.apple.security.print</key>
<true/>
```

> **USB on macOS** goes through the system print queue (CUPS), not raw USB.
> Add the printer in **System Settings → Printers & Scanners** first (the
> *Generic* driver works for most ESC/POS printers). `getPrinters(printerType: PrinterType.usb)`
> then lists the installed queues.

### Windows
No manifest permissions required. Install the USB printer driver so it shows up in the Windows print spooler. (Bluetooth is not supported on Windows.)

### Linux
Network only — make sure the firewall allows the printer port (default `9100`).

### Web
Experimental. Network printing requires a server/proxy that accepts the connection (raw TCP sockets aren't available in the browser).

## Usage

```dart
final printer = ThermalPrinterFlutter();
```

### List printers

```dart
final usb       = await printer.getPrinters(printerType: PrinterType.usb);       // Windows, macOS
final bluetooth = await printer.getPrinters(printerType: PrinterType.bluetooth); // Android, iOS, macOS
```

### Discover network printers

```dart
final found = await printer.discoverNetworkPrinters(
  onProgress: (p) => print(p),
  requireConfirmation: true, // optional: probe port 9100 (ESC/POS) to drop false positives
);
```

Or add one manually:

```dart
final p = Printer(type: PrinterType.network, name: 'Kitchen', ip: '192.168.1.50', port: '9100');
```

### Connect (Bluetooth / Network)

```dart
await printer.connect(printer: target);
await printer.disconnect(printer: target);
```
> USB printers are connectionless — no `connect()` needed.

### Print

```dart
final generator = Generator(PaperSize.mm80, await CapabilityProfile.load());
final bytes = <int>[]
  ..addAll(generator.text('Hello', styles: const PosStyles(align: PosAlign.center, bold: true)))
  ..addAll(generator.feed(2))
  ..addAll(generator.cut());

await printer.printBytes(bytes: bytes, printer: target);

// Multiple copies in a single job (do not call printBytes in a loop):
await printer.printBytes(bytes: bytes, printer: target, copies: 2);
```

### Print a widget / image

```dart
final image = await printer.screenShotWidget(
  context,
  widget: MyReceipt(),
  width: 576,   // 80 mm @ 203 dpi (use 384 for 58 mm)
  pixelRatio: 4.0,
  dither: true, // Floyd–Steinberg (default) — best for logos/photos
);

final bytes = <int>[]
  ..addAll(generator.imageRaster(image))
  ..addAll(generator.cut());

await printer.printBytes(bytes: bytes, printer: target);
```

### Printer status (USB)

```dart
final status = await printer.getPrinterStatus(printer: target);
print('${status.description} (paperOut=${status.isPaperOut}, offline=${status.isOffline})');
```

### Release resources

```dart
await printer.dispose(); // closes pooled network sockets
```

## Notes & limitations

- `getPrinterStatus` returns real data only for **USB** printers on **Windows** (spooler) and **macOS** (CUPS); otherwise `PrinterStatus.unknown`.
- `isConnected` is always `true` for USB (connectionless) — use `getPrinterStatus` for real health.
- Bluetooth manages a **single active connection**; `disconnect()` closes the active one regardless of the `Printer` passed.
- Network discovery flags **any host** with an open port (9100/515/631) as a candidate — use `requireConfirmation: true` to reduce false positives.

## License

MIT — see [LICENSE](LICENSE).
