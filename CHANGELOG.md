## 0.1.0

- **BREAKING:** Renamed `PrinterType.bluethoot` to `PrinterType.bluetooth`. Update call sites from `PrinterType.bluethoot` to `PrinterType.bluetooth`. Serialized data using the legacy `"bluethoot"` string is still parsed by `Printer.fromMap`.
- Added USB printing support on macOS (via CUPS)
- Added automatic network printer discovery (`discoverNetworkPrinters`)
- Fixed `getPlatformVersion` to return the platform version through the method channel
- Fixed double-result crash on Bluetooth (BLE) for iOS/macOS
- Fixed multiple-copies bug when printing RAW on Windows
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
