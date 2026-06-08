# thermal_printer_flutter

Flutter plugin for ESC/POS thermal printing over **USB**, **Bluetooth (BLE)** and **Network (TCP/IP)** on Android, iOS, macOS, Windows, Linux and Web.

## Platform support

| Platform | USB | Bluetooth | Network |
| -------- | --- | --------- | ------- |
| Android  | ❌  | ✅ (BLE/RFCOMM) | ✅      |
| iOS      | ❌  | ✅ (BLE)        | ✅      |
| macOS    | ✅  | 🚧             | ✅      |
| Windows  | ✅  | ✅ (RFCOMM)     | ✅      |
| Linux    | ❌  | ❌             | ✅      |
| Web      | ✅ | ✅ (BLE)     | ❌      |

¹ **Web** uses **WebUSB** and **Web Bluetooth** — Chromium browsers only (Chrome/Edge/Opera; not Safari/Firefox), over **HTTPS or `localhost`**. Network (raw TCP 9100) is not possible in a browser. See [Web](#web) below for the important caveats.

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
Web printing works over **WebUSB** and **Web Bluetooth (BLE)**. There is no native setup, but the browser imposes hard constraints — read these before shipping.

> **TL;DR:** **BLE works reliably on the web** (Chromium). **USB also works on Windows / Linux / ChromeOS**, but on **macOS** a USB printer is held by the system print driver and needs a cable replug to authorize — so **on macOS, prefer BLE**. See the *macOS + USB printers* note below.

#### Browser & context
- **Chromium only** (Chrome / Edge / Opera). Safari and Firefox do **not** implement WebUSB/Web Bluetooth. Detect at runtime with `isWebUsbSupported()` / `isWebBluetoothSupported()`.
- **Secure context required:** HTTPS, or `http://localhost` for development.

#### What the browser does *not* allow
- **No silent discovery / no scanning.** A page can never enumerate devices on its own. The only flow is: user gesture (button click) → the browser's own device chooser → user picks the device. After that the grant is remembered and the device reconnects without the chooser (`getDevices`).
- **No raw network (TCP 9100).** Browsers can't open raw sockets, so `PrinterType.network` is **not** available on web (only USB and BLE). A server/WebSocket bridge would be required.
- **Bluetooth is BLE only** — classic/RFCOMM is not exposed to the web. The printer must advertise a known GATT write service; the common ESC/POS UUIDs are in `printerServiceUuids` (`lib/src/web/web_bluetooth.dart`). If your model uses a different service it won't be found — open an issue/PR with the UUID.

#### Permission is per-origin — pin the dev port
WebUSB/Web Bluetooth permission is scoped to the **origin = scheme + host + _port_**. `flutter run -d chrome` picks a **random port every run**, so the grant is lost each time and `getDevices()` comes back empty. Pin the port so the grant (and silent reconnect) persists:

```bash
flutter run -d chrome --web-port=8080
```

#### ⚠️ macOS + USB printers — known limitation
On **macOS**, a class-compliant USB printer (interface class `0x07`) is claimed by the system print driver as soon as it enumerates. Chrome cannot offer a device whose interface is held by a kernel driver, so **the WebUSB chooser comes up empty**. This is a macOS/OS-level constraint — **there is no code-side fix** (unlike Windows, which can override the driver with a WinUSB INF, or Linux with a udev rule; macOS has no clean equivalent).

Confirmed behavior and workarounds:
- The device is always visible in `chrome://usb-internals`, but **not** in the WebUSB chooser, because the OS holds it.
- **Physically unplugging and reconnecting the USB cable** frees the device for a brief window — click *Authorize* right after the replug and it works. The `connect` event (see `onWebUsbConnectionChange`) fires on that replug, so once a printer has been authorized it then reconnects automatically each time it's plugged in.
- **For reliable web printing on macOS, use Bluetooth (BLE)** — it doesn't compete with the print driver.

**WebUSB works normally on Windows, Linux and ChromeOS.** The replug dance is specific to macOS class-`0x07` printers.

See [Web (USB & Bluetooth)](#web-usb--bluetooth) under Usage for the API.

## Usage

```dart
final printer = ThermalPrinterFlutter();
```

### List printers

```dart
final usb       = await printer.getPrinters(printerType: PrinterType.usb);       // Windows, macOS
final bluetooth = await printer.getPrinters(printerType: PrinterType.bluetooth); // Android, iOS, macOS
```

> On **Web**, `getPrinters` returns only devices the user **already authorized** (it never opens a chooser). Use `requestPrinter` to authorize a new one. See [Web (USB & Bluetooth)](#web-usb--bluetooth).

### Web (USB & Bluetooth)

On the web, the browser must prompt the user before a device is accessible. The pattern is **authorize once, then reconnect silently**:

```dart
// 1. Feature-detect (Chromium only, HTTPS/localhost).
if (await printer.isWebUsbSupported()) {
  // 2. Authorize. Smart: reuses an already-granted device if present,
  //    and only opens the browser chooser when needed. MUST be called
  //    from a user gesture (e.g. a button's onPressed).
  final target = await printer.requestPrinter(printerType: PrinterType.usb);
  if (target != null) {
    await printer.printBytes(bytes: bytes, printer: target);
  }
}

// Web Bluetooth (BLE) is the same, with PrinterType.bluetooth:
if (await printer.isWebBluetoothSupported()) {
  final ble = await printer.requestPrinter(printerType: PrinterType.bluetooth);
}
```

Auto-reconnect already-authorized USB printers when the cable is plugged in (no chooser):

```dart
// Re-resolve granted devices on every USB connect/disconnect event.
final sub = printer.onWebUsbConnectionChange.listen((_) async {
  final usb = await printer.getPrinters(printerType: PrinterType.usb);
  // usb now contains the reconnected printer(s).
});
// ...
await sub.cancel(); // when done
```

> `requestPrinter`, `isWebUsbSupported`, `isWebBluetoothSupported` and `onWebUsbConnectionChange` are no-ops/empty on non-web platforms, so the same code is safe everywhere.

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
- **Web**: Chromium only (HTTPS/localhost); no network transport; BLE only (no classic); WebUSB permission is **per-origin including the port** (pin `--web-port` in dev); on macOS the system print driver competes for USB printers (prefer BLE). See [Web setup](#web).

## License

MIT — see [LICENSE](LICENSE).
