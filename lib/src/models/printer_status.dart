class PrinterStatus {
  final bool hasStatus;
  final bool hasError;
  final bool isPaperOut;
  final bool isPaperJam;
  final bool isDoorOpen;
  final bool isOffline;
  final bool isPaperLow;
  final bool needsUserAction;
  final int rawStatus;
  final String description;

  const PrinterStatus({
    required this.hasStatus,
    required this.hasError,
    required this.isPaperOut,
    required this.isPaperJam,
    required this.isDoorOpen,
    required this.isOffline,
    required this.isPaperLow,
    required this.needsUserAction,
    required this.rawStatus,
    required this.description,
  });

  static const PrinterStatus unknown = PrinterStatus(
    hasStatus: false,
    hasError: false,
    isPaperOut: false,
    isPaperJam: false,
    isDoorOpen: false,
    isOffline: false,
    isPaperLow: false,
    needsUserAction: false,
    rawStatus: 0,
    description: '',
  );

  factory PrinterStatus.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return PrinterStatus.unknown;

    bool flag(String key) => map[key] == true;
    return PrinterStatus(
      hasStatus: flag('hasStatus'),
      hasError: flag('hasError'),
      isPaperOut: flag('isPaperOut'),
      isPaperJam: flag('isPaperJam'),
      isDoorOpen: flag('isDoorOpen'),
      isOffline: flag('isOffline'),
      isPaperLow: flag('isPaperLow'),
      needsUserAction: flag('needsUserAction'),
      rawStatus: (map['rawStatus'] as int?) ?? 0,
      description: map['description'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'hasStatus': hasStatus,
      'hasError': hasError,
      'isPaperOut': isPaperOut,
      'isPaperJam': isPaperJam,
      'isDoorOpen': isDoorOpen,
      'isOffline': isOffline,
      'isPaperLow': isPaperLow,
      'needsUserAction': needsUserAction,
      'rawStatus': rawStatus,
      'description': description,
    };
  }
}

