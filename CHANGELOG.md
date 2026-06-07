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
- Added unit test coverage

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
