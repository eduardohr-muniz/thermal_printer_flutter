import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;

class ThermalScreenshot {
  static Future<img.Image> captureWidgetAsMonochromeImage(
    BuildContext context, {
    required Widget widget,
    double pixelRatio = 3.0, // Reduzido para melhor performance
    int width = 550,
    int threshold = 160,
    bool flipHorizontal = false,
    bool applyTextScaling = true,
    bool useBetterText = true,
  }) async {
    final globalKey = GlobalKey();
    final completer = Completer<img.Image>();
    final stopwatch = Stopwatch()..start();

    final captureWidget = RepaintBoundary(
      key: globalKey,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: width.toDouble(),
            maxWidth: width.toDouble(),
          ),
          child: applyTextScaling
              ? MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaleFactor: 1.3, // Reduzido ligeiramente
                  ),
                  child: widget,
                )
              : widget,
        ),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final boundary = globalKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
        if (boundary == null || !boundary.hasSize) {
          throw Exception('Render boundary não está pronto');
        }

        await Future.delayed(const Duration(milliseconds: 10)); // Delay reduzido

        // 1. Fase de Captura (Otimizada)
        final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
        final ByteData? byteData = await image.toByteData(); // Formato mais rápido
        if (byteData == null) throw Exception('Falha ao obter bytes da imagem');

        // 2. Processamento Direto (Sem decodificação PNG intermediária)
        final Uint8List rgbaBytes = byteData.buffer.asUint8List();
        final int newWidth = (width % 8 != 0) ? ((width ~/ 8) * 8) : width;

        // Conversão direta para imagem monocromática
        final monoImage = useBetterText ? _convertTextOptimizedMonochrome(rgbaBytes, image.width, image.height, newWidth, threshold) : _convertRgbaToMonochromeFast(rgbaBytes, image.width, image.height, newWidth, threshold);

        image.dispose();
        log('Screen shot time: ${stopwatch.elapsedMilliseconds}ms', name: 'THERMAL_PRINTER_FLUTTER');
        stopwatch.stop();
        completer.complete(monoImage);
      } catch (e) {
        completer.completeError(e);
      }
    });

    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: -10000,
        child: Material(type: MaterialType.transparency, child: captureWidget),
      ),
    );

    Overlay.of(context, rootOverlay: true).insert(overlayEntry);

    try {
      final result = await completer.future;
      overlayEntry.remove();
      return result;
    } catch (e) {
      overlayEntry.remove();
      rethrow;
    }
  }

  // Conversão direta de RGBA para monocromático com dithering
  static img.Image _convertTextOptimizedMonochrome(Uint8List rgbaBytes, int srcWidth, int srcHeight, int dstWidth, int threshold) {
    final dstHeight = (srcHeight * (dstWidth / srcWidth)).toInt();
    final monoImage = img.Image(width: dstWidth, height: dstHeight);

    // Configurações específicas para texto
    final enhancedThreshold = (threshold * 0.9).toInt(); // Threshold mais baixo para texto

    for (int y = 0; y < dstHeight; y++) {
      final srcY = (y * srcHeight / dstHeight).toInt();
      for (int x = 0; x < dstWidth; x++) {
        final srcX = (x * srcWidth / dstWidth).toInt();
        final pixelOffset = (srcY * srcWidth + srcX) * 4;

        // Detecta bordas de texto (alta variação de cor)
        final isLikelyText = _isTextPixel(rgbaBytes, srcX, srcY, srcWidth, srcHeight);

        if (isLikelyText) {
          // Processamento especial para texto
          final luminance = _calculateTextLuminance(rgbaBytes, pixelOffset);
          final color = luminance > enhancedThreshold ? 255 : 0;
          monoImage.setPixel(x, y, img.ColorRgb8(color, color, color));
        } else {
          // Processamento normal para outras áreas
          final r = rgbaBytes[pixelOffset];
          final g = rgbaBytes[pixelOffset + 1];
          final b = rgbaBytes[pixelOffset + 2];
          final luminance = 0.299 * r + 0.587 * g + 0.114 * b;
          final color = luminance > threshold ? 255 : 0;
          monoImage.setPixel(x, y, img.ColorRgb8(color, color, color));
        }
      }
    }
    return monoImage;
  }

  static bool _isTextPixel(Uint8List rgbaBytes, int x, int y, int width, int height) {
    // Detecta bordas agudas (característica de texto)
    final current = (rgbaBytes[(y * width + x) * 4] + rgbaBytes[(y * width + x) * 4 + 1] + rgbaBytes[(y * width + x) * 4 + 2]) / 3;

    // Compara com pixels vizinhos
    final right = x < width - 1 ? (rgbaBytes[(y * width + x + 1) * 4] + rgbaBytes[(y * width + x + 1) * 4 + 1] + rgbaBytes[(y * width + x + 1) * 4 + 2]) / 3 : current;

    final diff = (current - right).abs();
    return diff > 50; // Limiar para considerar como borda de texto
  }

  static double _calculateTextLuminance(Uint8List rgbaBytes, int offset) {
    // Fórmula especial para texto que aumenta o contraste
    final r = rgbaBytes[offset];
    final g = rgbaBytes[offset + 1];
    final b = rgbaBytes[offset + 2];

    // Aumenta o peso dos canais que mais contribuem para o contraste do texto
    return 0.35 * r + 0.55 * g + 0.10 * b;
  }

  // Versão ultrarrápida sem dithering
  static img.Image _convertRgbaToMonochromeFast(Uint8List rgbaBytes, int srcWidth, int srcHeight, int dstWidth, int threshold) {
    final scale = dstWidth / srcWidth;
    final dstHeight = (srcHeight * scale).toInt();
    final monoImage = img.Image(width: dstWidth, height: dstHeight);

    for (int y = 0; y < dstHeight; y++) {
      final srcY = (y / scale).toInt().clamp(0, srcHeight - 1);
      for (int x = 0; x < dstWidth; x++) {
        final srcX = (x / scale).toInt().clamp(0, srcWidth - 1);
        final pixelOffset = (srcY * srcWidth + srcX) * 4;

        if (rgbaBytes[pixelOffset + 3] < 200) {
          monoImage.setPixel(x, y, img.ColorRgb8(255, 255, 255));
          continue;
        }

        final luminance = 0.2126 * rgbaBytes[pixelOffset] + 0.7152 * rgbaBytes[pixelOffset + 1] + 0.0722 * rgbaBytes[pixelOffset + 2];

        final color = luminance > threshold ? 255 : 0;
        monoImage.setPixel(x, y, img.ColorRgb8(color, color, color));
      }
    }
    return monoImage;
  }

  static Uint8List encodeToPng(img.Image image) {
    return Uint8List.fromList(img.encodePng(image));
  }
}
