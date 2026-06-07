## 0.1.0

- **BREAKING:** Renamed `PrinterType.bluethoot` to `PrinterType.bluetooth`. Update call sites from `PrinterType.bluethoot` to `PrinterType.bluetooth`. Serialized data using the legacy `"bluethoot"` string is still parsed by `Printer.fromMap`.
- Added USB printing support on macOS (via CUPS)
- Added automatic network printer discovery (`discoverNetworkPrinters`)
- Fixed `getPlatformVersion` to return the platform version through the method channel
- Fixed double-result crash on Bluetooth (BLE) for iOS/macOS
- Added a `copies` parameter to `printBytes` — copies are now built into the byte stream and sent as a single job, behaving identically on every platform. Prefer this over calling `printBytes` in a loop.
- Print jobs are now serialized internally, so concurrent/looped `printBytes` calls never overlap (a common cause of "runaway"/duplicated printing).
- Fixed runaway/multiple-copies on Windows: the spooler now uses `RAW` datatype **and** forces `dmCopies = 1`, so a driver "Copies" default can no longer multiply RAW jobs. Partial/aborted jobs are deleted from the spooler instead of being sent truncated.
- Byte payloads are now sent as `Uint8List` across all platforms
- Fixed `flipHorizontal` on `screenShotWidget`: it was accepted but never applied; the captured image is now actually mirrored.
- Hardened Bluetooth printer parsing: a malformed paired-device string no longer drops the whole list (`RangeError`).
- `BluetoothPrinterRepository` reconnect delay is now configurable (was a hardcoded 500 ms).
- Network discovery now only auto-detects genuinely private subnets (correct `172.16.0.0/12` range) and prunes dead pooled connections.
- Windows printer status descriptions are now in English (was mixed Portuguese).
- Removed unused internal platform helper.
- USB `isConnected` now returns `true` (connectionless model) instead of relying on an unimplemented/meaningless channel call; use `getPrinterStatus` for real USB health.
- Documented the `writebytes` wire contract (USB sends a `Map`, Bluetooth sends raw bytes — this is how macOS routes USB-via-CUPS vs BLE) and locked it with tests.
- Documented platform/feature limitations in the README (status, isConnected, single BLE connection, discovery false positives).
- Network discovery can now confirm a candidate is a real printer via an ESC/POS `DLE EOT` probe on port 9100: `NetworkPrinterInfo.confirmed` flags the result, and `discoverNetworkPrinters(requireConfirmation: true)` returns only confirmed printers (default `false` keeps the previous candidate-listing behavior).
- Removed dead `printstring`/`printBytes` method handlers from the iOS/macOS plugins (never invoked from Dart).
- **Fixed Bluetooth discovery on iOS:** the Dart layer lists printers via the `pairedbluetooths` channel method, but the iOS plugin only handled `getPrinters`, so `getPrinters(printerType: bluetooth)` always returned an empty list on iOS. iOS now handles `pairedbluetooths` (runs a short BLE scan).
- Added `dispose()` to the plugin to close pooled network connections (prevents leaked sockets on teardown).
- Removed the dead `getPrinters` channel handler from the Windows, macOS, iOS and Android plugins (Dart calls `usbprinters`/`pairedbluetooths` directly).
- Implemented `getPrinterStatus` on macOS via CUPS (`printer-state` / `printer-state-reasons`), so USB printer status now works on macOS as well as Windows.
- Added a GitHub Actions CI workflow: analyze + test (coverage) and example builds for iOS, macOS, Android, Windows and Linux.
- Added unit test coverage (100% of the Dart library).

## 0.0.1+6

- Improved printing performance via Bluetooth

## 0.0.1+5

- Feature add textScaleFactor on Screenshot

## 0.0.1+4

- Dependency Compatibility

## 0.0.1+3

- Resolve bug align in printers bluethoot
- Feature Add Screenshot widget

## 0.0.1+2

- Update readme

## 0.0.1

- Release
