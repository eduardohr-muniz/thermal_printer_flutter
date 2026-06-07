import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;

/// Captura widgets como imagens monocromáticas prontas para impressão térmica.
class ThermalScreenshot {
  /// Renderiza [widget] fora da tela e o converte numa imagem monocromática.
  static Future<img.Image> captureWidgetAsMonochromeImage(
    BuildContext context, {
    required Widget widget,
    double pixelRatio = 3.0, // Reduzido para melhor performance
    int width = 576, // 80 mm @ 203 dpi (múltiplo de 8). Use 384 p/ 58 mm.
    int threshold = 160,
    bool flipHorizontal = false,
    bool applyTextScaling = true,
    bool useBetterText = true,
    double textScaleFactor = 1.3,
    bool dither = true,
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
                    textScaler: TextScaler.linear(textScaleFactor),
                  ),
                  child: widget,
                )
              : widget,
        ),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final boundary = globalKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
        // coverage:ignore-start
        // Guarda defensiva: o boundary é sempre inserido na árvore antes do
        // post-frame, então este ramo não é reproduzível em teste unitário.
        if (boundary == null || !boundary.hasSize) {
          throw Exception('Render boundary não está pronto');
        }
        // coverage:ignore-end

        await Future.delayed(
            const Duration(milliseconds: 10)); // Delay reduzido

        // 1. Fase de Captura (Otimizada)
        final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
        final ByteData? byteData =
            await image.toByteData(); // Formato mais rápido
        // coverage:ignore-start
        // toByteData() só retorna null em falha de GPU, não reproduzível.
        if (byteData == null) throw Exception('Falha ao obter bytes da imagem');
        // coverage:ignore-end

        // 2. Processamento Direto (Sem decodificação PNG intermediária)
        final Uint8List rgbaBytes = byteData.buffer.asUint8List();
        final int newWidth = (width % 8 != 0) ? ((width ~/ 8) * 8) : width;

        // Conversão direta para imagem monocromática.
        // `dither` usa reamostragem por média + Floyd–Steinberg (melhor para
        // logos/fotos/tons de cinza). Caso contrário usa o caminho de
        // limiar (melhor para texto puro).
        var monoImage = dither
            ? _convertWithDithering(
                rgbaBytes, image.width, image.height, newWidth, threshold)
            : useBetterText
                ? _convertTextOptimizedMonochrome(
                    rgbaBytes, image.width, image.height, newWidth, threshold)
                : _convertRgbaToMonochromeFast(
                    rgbaBytes, image.width, image.height, newWidth, threshold);

        // Espelha horizontalmente quando solicitado (algumas impressoras
        // térmicas/refletivas exigem a imagem invertida).
        if (flipHorizontal) {
          monoImage = img.flipHorizontal(monoImage);
        }

        image.dispose();
        log('Screen shot time: ${stopwatch.elapsedMilliseconds}ms',
            name: 'THERMAL_PRINTER_FLUTTER');
        stopwatch.stop();
        completer.complete(monoImage);
        // coverage:ignore-start
        // Caminho de erro de captura (falha de GPU/render), não reproduzível
        // de forma determinística em teste unitário.
      } catch (e) {
        completer.completeError(e);
      }
      // coverage:ignore-end
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
      // coverage:ignore-start
      // Só alcançado se a captura falhar (ver bloco acima); o overlay é removido
      // e o erro é repropagado ao chamador.
    } catch (e) {
      overlayEntry.remove();
      rethrow;
    }
    // coverage:ignore-end
  }

  // Conversão direta de RGBA para monocromático com dithering
  static img.Image _convertTextOptimizedMonochrome(Uint8List rgbaBytes,
      int srcWidth, int srcHeight, int dstWidth, int threshold) {
    final dstHeight = (srcHeight * (dstWidth / srcWidth)).toInt();
    final monoImage = img.Image(width: dstWidth, height: dstHeight);

    // Configurações específicas para texto
    final enhancedThreshold =
        (threshold * 0.9).toInt(); // Threshold mais baixo para texto

    for (int y = 0; y < dstHeight; y++) {
      final srcY = (y * srcHeight / dstHeight).toInt();
      for (int x = 0; x < dstWidth; x++) {
        final srcX = (x * srcWidth / dstWidth).toInt();
        final pixelOffset = (srcY * srcWidth + srcX) * 4;

        // Detecta bordas de texto (alta variação de cor)
        final isLikelyText =
            _isTextPixel(rgbaBytes, srcX, srcY, srcWidth, srcHeight);

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

  static bool _isTextPixel(
      Uint8List rgbaBytes, int x, int y, int width, int height) {
    // Detecta bordas agudas (característica de texto)
    final current = (rgbaBytes[(y * width + x) * 4] +
            rgbaBytes[(y * width + x) * 4 + 1] +
            rgbaBytes[(y * width + x) * 4 + 2]) /
        3;

    // Compara com pixels vizinhos
    final right = x < width - 1
        ? (rgbaBytes[(y * width + x + 1) * 4] +
                rgbaBytes[(y * width + x + 1) * 4 + 1] +
                rgbaBytes[(y * width + x + 1) * 4 + 2]) /
            3
        : current;

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
  static img.Image _convertRgbaToMonochromeFast(Uint8List rgbaBytes,
      int srcWidth, int srcHeight, int dstWidth, int threshold) {
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

        final luminance = 0.2126 * rgbaBytes[pixelOffset] +
            0.7152 * rgbaBytes[pixelOffset + 1] +
            0.0722 * rgbaBytes[pixelOffset + 2];

        final color = luminance > threshold ? 255 : 0;
        monoImage.setPixel(x, y, img.ColorRgb8(color, color, color));
      }
    }
    return monoImage;
  }

  /// Conversão de alta qualidade: reamostra por **média de área** (em vez de
  /// vizinho-mais-próximo) e aplica **dithering Floyd–Steinberg** para 1-bit.
  ///
  /// Indicado para logos/fotos/gradientes, onde o limiar simples perde
  /// detalhe. Pixels transparentes são compostos sobre fundo branco.
  static img.Image _convertWithDithering(Uint8List rgbaBytes, int srcWidth,
      int srcHeight, int dstWidth, int threshold) {
    // Envolve os bytes RGBA crus e reduz com interpolação por média.
    final src = img.Image.fromBytes(
      width: srcWidth,
      height: srcHeight,
      bytes: rgbaBytes.buffer,
      numChannels: 4,
    );
    final dstHeight = (srcHeight * (dstWidth / srcWidth)).round();
    final resized = img.copyResize(
      src,
      width: dstWidth,
      height: dstHeight,
      interpolation: img.Interpolation.average,
    );

    // Buffer de luminância (compondo a transparência sobre branco).
    final gray = List<double>.filled(dstWidth * dstHeight, 0);
    for (int y = 0; y < dstHeight; y++) {
      for (int x = 0; x < dstWidth; x++) {
        final p = resized.getPixel(x, y);
        final a = p.a / 255.0;
        final r = p.r * a + 255 * (1 - a);
        final g = p.g * a + 255 * (1 - a);
        final b = p.b * a + 255 * (1 - a);
        gray[y * dstWidth + x] = 0.299 * r + 0.587 * g + 0.114 * b;
      }
    }

    // Difusão de erro Floyd–Steinberg.
    final monoImage = img.Image(width: dstWidth, height: dstHeight);
    for (int y = 0; y < dstHeight; y++) {
      for (int x = 0; x < dstWidth; x++) {
        final i = y * dstWidth + x;
        final oldVal = gray[i];
        final newVal = oldVal < threshold ? 0.0 : 255.0;
        final err = oldVal - newVal;
        final c = newVal.toInt();
        monoImage.setPixel(x, y, img.ColorRgb8(c, c, c));

        if (x + 1 < dstWidth) gray[i + 1] += err * 7 / 16;
        if (y + 1 < dstHeight) {
          if (x > 0) gray[i + dstWidth - 1] += err * 3 / 16;
          gray[i + dstWidth] += err * 5 / 16;
          if (x + 1 < dstWidth) gray[i + dstWidth + 1] += err * 1 / 16;
        }
      }
    }
    return monoImage;
  }

  /// Codifica [image] em bytes PNG.
  static Uint8List encodeToPng(img.Image image) {
    return Uint8List.fromList(img.encodePng(image));
  }
}
