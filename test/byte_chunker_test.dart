import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thermal_printer_flutter/src/web/byte_chunker.dart';

void main() {
  group('chunkBytes', () {
    test('entrada vazia retorna lista vazia', () {
      expect(chunkBytes(const [], 4), isEmpty);
    });

    test('menor que o bloco retorna um único bloco com tudo', () {
      final chunks = chunkBytes(const [1, 2, 3], 16);
      expect(chunks, hasLength(1));
      expect(chunks.single, [1, 2, 3]);
    });

    test('múltiplo exato do bloco gera blocos cheios e iguais', () {
      final chunks = chunkBytes(const [1, 2, 3, 4, 5, 6], 2);
      expect(chunks.map((c) => c.toList()), [
        [1, 2],
        [3, 4],
        [5, 6],
      ]);
    });

    test('com resto, o último bloco é menor', () {
      final chunks = chunkBytes(const [1, 2, 3, 4, 5], 2);
      expect(chunks.map((c) => c.toList()), [
        [1, 2],
        [3, 4],
        [5],
      ]);
    });

    test('bloco de tamanho 1 gera um bloco por byte', () {
      final chunks = chunkBytes(const [9, 8, 7], 1);
      expect(chunks.map((c) => c.toList()), [
        [9],
        [8],
        [7],
      ]);
    });

    test('a concatenação dos blocos reconstrói a entrada (golden)', () {
      // Payload determinístico (0..299) — valida ordem e integridade ponta a
      // ponta, que é a propriedade que importa para o ESC/POS não corromper.
      final input = List<int>.generate(300, (i) => i % 256);
      for (final size in [1, 7, 16, 64, 299, 300, 301, 1024]) {
        final chunks = chunkBytes(input, size);
        final rebuilt = <int>[for (final c in chunks) ...c];
        expect(rebuilt, input, reason: 'falhou com chunkSize=$size');
        // Todos cheios exceto o último.
        for (var i = 0; i < chunks.length - 1; i++) {
          expect(chunks[i], hasLength(size), reason: 'bloco $i (size=$size)');
        }
        expect(chunks.last.length, lessThanOrEqualTo(size));
      }
    });

    test('retorna Uint8List (pronto para .toJS / BufferSource)', () {
      expect(chunkBytes(const [1, 2], 1).first, isA<Uint8List>());
    });

    test('chunkSize <= 0 lança ArgumentError', () {
      expect(() => chunkBytes(const [1], 0), throwsArgumentError);
      expect(() => chunkBytes(const [1], -3), throwsArgumentError);
    });
  });
}
