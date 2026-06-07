import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_printer_flutter/src/models/printer_status.dart';

void main() {
  group('PrinterStatus.unknown', () {
    test('is an empty/neutral status', () {
      const status = PrinterStatus.unknown;
      expect(status.hasStatus, isFalse);
      expect(status.hasError, isFalse);
      expect(status.isPaperOut, isFalse);
      expect(status.isPaperJam, isFalse);
      expect(status.isDoorOpen, isFalse);
      expect(status.isOffline, isFalse);
      expect(status.isPaperLow, isFalse);
      expect(status.needsUserAction, isFalse);
      expect(status.rawStatus, 0);
      expect(status.description, isEmpty);
    });
  });

  group('PrinterStatus.fromMap', () {
    test('returns unknown when the map is null', () {
      final status = PrinterStatus.fromMap(null);
      expect(status.hasStatus, isFalse);
      expect(status.description, isEmpty);
    });

    test('reads every flag and field from the map', () {
      final status = PrinterStatus.fromMap(<dynamic, dynamic>{
        'hasStatus': true,
        'hasError': true,
        'isPaperOut': true,
        'isPaperJam': true,
        'isDoorOpen': true,
        'isOffline': true,
        'isPaperLow': true,
        'needsUserAction': true,
        'rawStatus': 42,
        'description': 'Sem papel',
      });

      expect(status.hasStatus, isTrue);
      expect(status.hasError, isTrue);
      expect(status.isPaperOut, isTrue);
      expect(status.isPaperJam, isTrue);
      expect(status.isDoorOpen, isTrue);
      expect(status.isOffline, isTrue);
      expect(status.isPaperLow, isTrue);
      expect(status.needsUserAction, isTrue);
      expect(status.rawStatus, 42);
      expect(status.description, 'Sem papel');
    });

    test('falls back to defaults for missing/invalid values', () {
      final status = PrinterStatus.fromMap(<dynamic, dynamic>{
        'hasStatus': 'not a bool',
        'rawStatus': null,
        'description': null,
      });

      // Non-true values are treated as false.
      expect(status.hasStatus, isFalse);
      expect(status.rawStatus, 0);
      expect(status.description, isEmpty);
    });
  });

  group('PrinterStatus.toMap', () {
    test('serializes all fields', () {
      const status = PrinterStatus(
        hasStatus: true,
        hasError: false,
        isPaperOut: true,
        isPaperJam: false,
        isDoorOpen: true,
        isOffline: false,
        isPaperLow: true,
        needsUserAction: false,
        rawStatus: 7,
        description: 'Pronta',
      );

      final map = status.toMap();

      expect(map['hasStatus'], isTrue);
      expect(map['hasError'], isFalse);
      expect(map['isPaperOut'], isTrue);
      expect(map['isPaperJam'], isFalse);
      expect(map['isDoorOpen'], isTrue);
      expect(map['isOffline'], isFalse);
      expect(map['isPaperLow'], isTrue);
      expect(map['needsUserAction'], isFalse);
      expect(map['rawStatus'], 7);
      expect(map['description'], 'Pronta');
    });

    test('round-trips through fromMap', () {
      const original = PrinterStatus(
        hasStatus: true,
        hasError: true,
        isPaperOut: false,
        isPaperJam: true,
        isDoorOpen: false,
        isOffline: true,
        isPaperLow: false,
        needsUserAction: true,
        rawStatus: 99,
        description: 'Erro',
      );

      final restored = PrinterStatus.fromMap(original.toMap());

      expect(restored.hasStatus, original.hasStatus);
      expect(restored.hasError, original.hasError);
      expect(restored.isPaperOut, original.isPaperOut);
      expect(restored.isPaperJam, original.isPaperJam);
      expect(restored.isDoorOpen, original.isDoorOpen);
      expect(restored.isOffline, original.isOffline);
      expect(restored.isPaperLow, original.isPaperLow);
      expect(restored.needsUserAction, original.needsUserAction);
      expect(restored.rawStatus, original.rawStatus);
      expect(restored.description, original.description);
    });
  });
}
