import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<img.Image> capture(
    WidgetTester tester, {
    required bool useBetterText,
    bool flipHorizontal = false,
    bool applyTextScaling = true,
    bool dither = false,
    Widget? child,
  }) async {
    late BuildContext capturedContext;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    late img.Image image;

    // runAsync lets the real Future.delayed and ui.Image.toByteData run, while
    // we drive frames so the off-screen overlay lays out and paints.
    await tester.runAsync(() async {
      final future = ThermalScreenshot.captureWidgetAsMonochromeImage(
        capturedContext,
        width: 64,
        pixelRatio: 1.0,
        useBetterText: useBetterText,
        flipHorizontal: flipHorizontal,
        applyTextScaling: applyTextScaling,
        dither: dither,
        widget: child ??
            Container(
              width: 64,
              height: 32,
              color: Colors.black,
              child: const Text(
                'Hello World',
                style: TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
      );

      // Pump a few frames so the overlay paints and the post-frame callback fires.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      image = await future;
    });

    return image;
  }

  group('ThermalScreenshot.captureWidgetAsMonochromeImage', () {
    testWidgets('produces a monochrome image with the text-optimized path',
        (tester) async {
      final image = await capture(tester, useBetterText: true);

      expect(image.width, greaterThan(0));
      expect(image.height, greaterThan(0));
    });

    testWidgets('produces a monochrome image with the fast path',
        (tester) async {
      final image = await capture(tester, useBetterText: false);

      expect(image.width, greaterThan(0));
      expect(image.height, greaterThan(0));
    });

    testWidgets('flipHorizontal mirrors the image', (tester) async {
      // Widget assimétrico: metade esquerda preta, metade direita branca.
      Widget asymmetric() => Row(
            children: const [
              SizedBox(
                  width: 32,
                  height: 32,
                  child: ColoredBox(color: Colors.black)),
              SizedBox(
                  width: 32,
                  height: 32,
                  child: ColoredBox(color: Colors.white)),
            ],
          );

      final normal = await capture(tester,
          useBetterText: false, applyTextScaling: false, child: asymmetric());
      final flipped = await capture(tester,
          useBetterText: false,
          applyTextScaling: false,
          flipHorizontal: true,
          child: asymmetric());

      expect(flipped.width, normal.width);
      expect(flipped.height, normal.height);

      final y = normal.height ~/ 2;
      // Pixel da borda esquerda: preto no normal, branco após espelhar.
      final leftNormal = normal.getPixel(1, y);
      final leftFlipped = flipped.getPixel(1, y);
      expect(leftFlipped.luminanceNormalized,
          greaterThan(leftNormal.luminanceNormalized));
    });

    testWidgets('fast path renders transparent pixels as white',
        (tester) async {
      final image = await capture(
        tester,
        useBetterText: false,
        child: const SizedBox(width: 64, height: 32),
      );

      expect(image.width, greaterThan(0));
    });

    testWidgets('dithered path (Floyd–Steinberg) produces a monochrome image',
        (tester) async {
      final image = await capture(tester, useBetterText: false, dither: true);

      expect(image.width, greaterThan(0));
      expect(image.height, greaterThan(0));
    });

    testWidgets('dithered path composites transparency onto white',
        (tester) async {
      final image = await capture(
        tester,
        useBetterText: false,
        dither: true,
        child: const SizedBox(width: 64, height: 32),
      );

      expect(image.width, greaterThan(0));
    });
  });

  group('ThermalScreenshot offscreen rendering', () {
    Widget receipt() => const SizedBox(
          width: 64,
          height: 40,
          child: ColoredBox(color: Colors.black),
        );

    testWidgets('captures without a BuildContext', (tester) async {
      late img.Image image;
      await tester.runAsync(() async {
        image = await ThermalScreenshot.captureWidgetAsMonochromeImage(
          null,
          width: 64,
          pixelRatio: 1.0,
          dither: false,
          useBetterText: false,
          widget: receipt(),
        );
      });

      expect(image.width, 64);
      expect(image.height, 40);
      // Conteúdo preto foi de fato pintado.
      expect(image.getPixel(32, 20).luminanceNormalized, 0);
    });

    testWidgets('captures while the app is in background (no frames)',
        (tester) async {
      late BuildContext capturedContext;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          capturedContext = context;
          return const SizedBox();
        }),
      ));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(tester.binding.framesEnabled, isFalse);

      late img.Image image;
      await tester.runAsync(() async {
        // Nenhum pump: se a captura dependesse de frames, travaria aqui.
        image = await ThermalScreenshot.captureWidgetAsMonochromeImage(
          capturedContext,
          width: 64,
          pixelRatio: 1.0,
          dither: false,
          useBetterText: false,
          widget: receipt(),
        );
      });

      expect(image.height, 40);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    testWidgets('receipt height follows the widget (unbounded height)',
        (tester) async {
      late img.Image image;
      await tester.runAsync(() async {
        image = await ThermalScreenshot.captureWidgetAsMonochromeImage(
          null,
          width: 64,
          pixelRatio: 1.0,
          dither: false,
          widget: Column(
            children: List.generate(
                10, (_) => const SizedBox(height: 100, width: 10)),
          ),
        );
      });

      expect(image.height, 1000);
    });
  });

  group('ThermalScreenshot.encodeToPng', () {
    test('encodes an image to non-empty PNG bytes', () {
      final image = img.Image(width: 4, height: 4);
      img.fill(image, color: img.ColorRgb8(0, 0, 0));

      final png = ThermalScreenshot.encodeToPng(image);

      expect(png, isNotEmpty);
      // PNG magic number.
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });
  });
}
