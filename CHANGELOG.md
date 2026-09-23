## 2.1.0

- `screenShotWidget` now renders the widget offscreen with its own build/layout/paint pipeline instead of inserting it into the app's `Overlay` and waiting for a post-frame callback. Capturing no longer depends on UI frames, so image receipts print while the app is minimized or in the background.
- `screenShotWidget`'s `BuildContext` parameter is now optional (`BuildContext?`). When provided, the capture inherits the app's `Theme`, `MediaQuery`, `Directionality` and `Localizations`; network/asset images should be pre-cached (e.g. `precacheImage`) to appear in the capture.
- Added a `timeout` parameter to `screenShotWidget` (default 10 s) that throws a `TimeoutException` if rendering stalls.
- Screenshot performance: the widget is re-rendered only when something actually changes after the first frame, and render objects/layers are released right after capture instead of waiting for GC.

## 2.0.0

- **Web printing:** USB printers via WebUSB and BLE printers via Web Bluetooth (Chromium browsers). New APIs: `requestPrinter` (opens the browser's device chooser; returns `null` on native platforms), `isWebUsbSupported`, `isWebBluetoothSupported` and `onWebUsbConnectionChange` (auto-reconnect authorized USB printers when they are plugged in).
- **Bluetooth on Windows:** paired SPP/RFCOMM thermal printers can now be listed, connected and printed to on Windows (previously blocked in the Dart layer). Connecting falls back to scanning RFCOMM channels when the printer doesn't publish an SPP record.
- **iOS/macOS BLE writes reworked:** writes no longer block the main thread, chunks respect `maximumWriteValueLength`, and `.withoutResponse` writes are flow-controlled via `canSendWriteWithoutResponse`/`peripheralIsReady`. Each job ends with a `.withResponse` flush barrier, so `printBytes` completes only after the printer received the data. This fixes prints that stalled mid-receipt, were truncated or printed slowly.
- Fixed iOS/macOS multi-chunk BLE payloads being corrupted after the first chunk (chunks are now zero-based `Data` copies).
- Bluetooth print jobs now wait for the printer to drain its buffer (proportional to the payload size, max 5 s) before the next job starts, preventing truncated or frozen output when jobs are sent back to back.

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
- Improved image print quality: `screenShotWidget` now downsamples with area-average interpolation and applies Floyd–Steinberg dithering by default (`dither: true`), greatly improving logos/photos/grayscale on 1-bit thermal printers. Pass `dither: false` for the previous threshold-only path (sharper for pure text).
- Changed the default `screenShotWidget` `width` from `550` to `576` (80 mm @ 203 dpi, a multiple of 8) so the bitmap matches the printer head without rescaling. Use `384` for 58 mm.
- Android Bluetooth writes now run on a background thread (single write + flush) instead of blocking the platform/UI thread. This removes the freeze/jank (and ANR risk) during long prints. The whole payload is sent in one write — chunked writes were found to make printing stutter/band — so output stays smooth; raw SPP throughput is gated by the printer, not the plugin.
- Fixed Bluetooth connect failing on Android with "MAC address is required": the Android plugin sent the device address under the `address` key while Dart expected `bleAddress`, so the address arrived empty. Android now sends `bleAddress` (matching iOS/macOS) and the Dart parser accepts both keys.
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
