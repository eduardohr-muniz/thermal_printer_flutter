import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_printer_flutter/src/helpers/platform.dart' as platform;

void main() {
  group('platform helpers (VM, isWeb == false)', () {
    test('isWeb is false in the test VM', () {
      expect(platform.isWeb, isFalse);
    });

    test('each getter mirrors dart:io Platform values', () {
      expect(platform.isAndroid, Platform.isAndroid);
      expect(platform.isWindows, Platform.isWindows);
      expect(platform.isLinux, Platform.isLinux);
      expect(platform.isMacOS, Platform.isMacOS);
      expect(platform.isFuchsia, Platform.isFuchsia);
      expect(platform.isIOS, Platform.isIOS);
    });

    test('isDesktop is true only for desktop platforms', () {
      final expected =
          Platform.isMacOS || Platform.isWindows || Platform.isLinux;
      expect(platform.isDesktop, expected);
    });

    test('isMobile is true only for mobile platforms', () {
      final expected = Platform.isAndroid || Platform.isIOS;
      expect(platform.isMobile, expected);
    });
  });
}
