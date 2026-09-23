// coverage:ignore-file
// Utilidades de diagnóstico para os transportes web (WebUSB / Web Bluetooth).
// Tudo aqui depende de APIs do browser (js_interop), por isso fica fora da
// cobertura de testes.

import 'dart:js_interop';

@JS('location.origin')
external String _locationOrigin;

@JS('isSecureContext')
external bool _isSecureContext;

@JS('console.log')
external void _consoleLog(JSString message);

/// Escreve [message] no **Console do navegador** (DevTools → Console).
///
/// Usamos `console.log` em vez de `dart:developer log`, porque este último vai
/// para a aba Logging do Dart DevTools (não para o Console do Chrome, onde se
/// costuma olhar).
void webLog(String message) {
  try {
    _consoleLog(message.toJS);
  } catch (_) {
    // Best-effort: nunca deixar o log derrubar o fluxo.
  }
}

/// Origem atual (esquema + host + **porta**). A permissão WebUSB/Web Bluetooth é
/// por origem; se a porta muda entre execuções, a autorização se perde.
String webOrigin() {
  try {
    return _locationOrigin;
  } catch (_) {
    return '<desconhecida>';
  }
}

/// Indica se a página está em contexto seguro (HTTPS ou localhost).
bool webIsSecureContext() {
  try {
    return _isSecureContext;
  } catch (_) {
    return false;
  }
}

/// Descreve um erro capturado (de uma `Promise` rejeitada) de forma legível.
///
/// Em build debug (o que `flutter run` usa) o `toString()` de um DOMException já
/// inclui nome + mensagem (ex.: `NotFoundError: No device selected`,
/// `SecurityError`, `NetworkError: Unable to claim interface`) — exatamente a
/// causa real que antes era engolida pelos `catch (_)`.
String describeJsError(Object e) => e.toString();
