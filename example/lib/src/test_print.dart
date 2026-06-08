import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';

/// Recibo de teste equivalente ao `testprint.dart` do `blue_thermal_printer`,
/// porém montado com ESC/POS (`Generator`) — que é como este plugin imprime.
///
/// Serve para comparar a impressão lado a lado: mesmo cabeçalho, mesmas linhas
/// LEFT/RIGHT em vários tamanhos, 3 e 4 colunas, QR Code e corte.
///
/// Observações de equivalência:
/// - O exemplo deles usa `printCustom/printLeftRight/print3Column/print4Column`
///   (API de alto nível). Aqui reproduzimos o mesmo layout com `text`, `row` e
///   `qrcode`.
/// - As imagens (logo de asset/arquivo/rede) foram omitidas de propósito: o
///   objetivo é medir o caminho de impressão Bluetooth puro (texto + QR), sem
///   depender de assets/rede.
/// - Os caracteres especiais (`čĆžŽšŠ…` em windows-1250 no original) foram
///   trocados por equivalentes ASCII para não depender de code page.
Future<List<int>> buildBlueThermalSampleReceipt() async {
  final generator = Generator(PaperSize.mm80, await CapabilityProfile.load());
  List<int> bytes = [];

  bytes += generator.reset();

  // HEADER — bold, tamanho 2x, centralizado (≈ Size.boldMedium, Align.center).
  bytes += generator.feed(1);
  bytes += generator.text(
    'HEADER',
    styles: const PosStyles(
      align: PosAlign.center,
      bold: true,
      height: PosTextSize.size2,
      width: PosTextSize.size2,
    ),
  );
  bytes += generator.feed(1);

  // LEFT / RIGHT em tamanhos crescentes (printLeftRight).
  bytes += generator.row([
    PosColumn(text: 'LEFT', width: 6),
    PosColumn(text: 'RIGHT', width: 6, styles: const PosStyles(align: PosAlign.right)),
  ]);
  bytes += generator.row([
    PosColumn(text: 'LEFT', width: 6, styles: const PosStyles(bold: true)),
    PosColumn(text: 'RIGHT', width: 6, styles: const PosStyles(bold: true, align: PosAlign.right)),
  ]);
  bytes += generator.feed(1);
  bytes += generator.row([
    PosColumn(
      text: 'LEFT',
      width: 6,
      styles: const PosStyles(bold: true, height: PosTextSize.size2, width: PosTextSize.size2),
    ),
    PosColumn(
      text: 'RIGHT',
      width: 6,
      styles: const PosStyles(bold: true, height: PosTextSize.size2, width: PosTextSize.size2, align: PosAlign.right),
    ),
  ]);
  bytes += generator.feed(1);

  // 3 colunas (print3Column).
  bytes += generator.row([
    PosColumn(text: 'Col1', width: 4, styles: const PosStyles(bold: true)),
    PosColumn(text: 'Col2', width: 4, styles: const PosStyles(bold: true, align: PosAlign.center)),
    PosColumn(text: 'Col3', width: 4, styles: const PosStyles(bold: true, align: PosAlign.right)),
  ]);
  bytes += generator.feed(1);

  // 4 colunas (print4Column).
  bytes += generator.row([
    PosColumn(text: 'Col1', width: 3, styles: const PosStyles(bold: true)),
    PosColumn(text: 'Col2', width: 3, styles: const PosStyles(bold: true, align: PosAlign.center)),
    PosColumn(text: 'Col3', width: 3, styles: const PosStyles(bold: true, align: PosAlign.center)),
    PosColumn(text: 'Col4', width: 3, styles: const PosStyles(bold: true, align: PosAlign.right)),
  ]);
  bytes += generator.feed(1);

  // Bloco final: caracteres especiais (ASCII), número, corpo e agradecimento.
  bytes += generator.text('cCzZsS-H-sccd', styles: const PosStyles(align: PosAlign.center, bold: true));
  bytes += generator.row([
    PosColumn(text: 'Numero:', width: 6, styles: const PosStyles(bold: true)),
    PosColumn(text: '18000001', width: 6, styles: const PosStyles(bold: true, align: PosAlign.right)),
  ]);
  bytes += generator.text('Body left', styles: const PosStyles(bold: true));
  bytes += generator.text('Body right', styles: const PosStyles(align: PosAlign.right));
  bytes += generator.feed(1);

  bytes += generator.text('Thank You', styles: const PosStyles(align: PosAlign.center, bold: true));
  bytes += generator.feed(1);

  // QR Code (printQRcode "Insert Your Own Text to Generate").
  bytes += generator.qrcode('Insert Your Own Text to Generate');
  bytes += generator.feed(2);

  bytes += generator.cut();
  return bytes;
}
