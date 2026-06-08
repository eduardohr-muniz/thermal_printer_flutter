import 'dart:typed_data';

/// Divide [bytes] em blocos de no máximo [chunkSize] bytes, preservando a ordem.
///
/// Lógica **pura** (sem APIs de browser) para ser testável na VM — usada tanto
/// pelo transporte WebUSB quanto pelo Web Bluetooth, que precisam fracionar o
/// payload ESC/POS pelos limites de transferência de cada protocolo.
///
/// Garantias:
/// - A concatenação dos blocos é idêntica a [bytes] (ordem e conteúdo).
/// - Todos os blocos têm exatamente [chunkSize] bytes, exceto possivelmente o
///   último (o resto).
/// - `[]` para entrada vazia.
List<Uint8List> chunkBytes(List<int> bytes, int chunkSize) {
  if (chunkSize <= 0) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'deve ser > 0');
  }
  final chunks = <Uint8List>[];
  for (var i = 0; i < bytes.length; i += chunkSize) {
    final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
    chunks.add(Uint8List.fromList(bytes.sublist(i, end)));
  }
  return chunks;
}
