import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// PIN de acesso guardado como hash com sal (PBKDF2-HMAC-SHA256) em
/// `user_config.pin_real`/`senha_pendente` — nunca em texto puro.
///
/// Formato: `pbkdf2$<iterações>$<sal base64>$<hash base64>`. Um valor fora
/// desse formato é um PIN antigo em texto puro (instalações anteriores à
/// migração v20 do banco, ver `DatabaseHelper._onUpgrade`) e continua
/// sendo aceito por [verificar] até ser regravado.
class PinHash {
  PinHash._();

  static const String _prefixo = 'pbkdf2';
  static const int _iteracoes = 10000;
  static const int _bytesSal = 16;
  static const int _bytesHash = 32;

  static bool ehHash(String? valor) => valor != null && valor.startsWith('$_prefixo\$');

  /// Hash novo (sal aleatório) para [pin].
  static String gerar(String pin) {
    final aleatorio = Random.secure();
    final sal = Uint8List.fromList(List<int>.generate(_bytesSal, (_) => aleatorio.nextInt(256)));
    final hash = _pbkdf2(utf8.encode(pin), sal, _iteracoes, _bytesHash);
    return '$_prefixo\$$_iteracoes\$${base64.encode(sal)}\$${base64.encode(hash)}';
  }

  /// `true` quando [digitado] corresponde ao [armazenado] (hash ou PIN
  /// antigo em texto puro). Comparação em tempo constante.
  static bool verificar(String digitado, String? armazenado) {
    if (armazenado == null || armazenado.isEmpty || digitado.isEmpty) return false;
    if (!ehHash(armazenado)) {
      return _iguais(utf8.encode(digitado), utf8.encode(armazenado));
    }
    final partes = armazenado.split('\$');
    if (partes.length != 4) return false;
    final iteracoes = int.tryParse(partes[1]);
    if (iteracoes == null || iteracoes <= 0) return false;
    try {
      final sal = base64.decode(partes[2]);
      final esperado = base64.decode(partes[3]);
      final calculado = _pbkdf2(utf8.encode(digitado), sal, iteracoes, esperado.length);
      return _iguais(calculado, esperado);
    } on FormatException {
      return false;
    }
  }

  /// Hash de [valor] se ainda estiver em texto puro; `null`/vazio/hash
  /// voltam como estão. Usado na migração do PIN atual.
  static String? migrar(String? valor) {
    if (valor == null || valor.trim().isEmpty || ehHash(valor)) return valor;
    return gerar(valor.trim());
  }

  static List<int> _pbkdf2(List<int> senha, List<int> sal, int iteracoes, int tamanho) {
    final hmac = Hmac(sha256, senha);
    final resultado = <int>[];
    var bloco = 1;
    while (resultado.length < tamanho) {
      final entrada = Uint8List(sal.length + 4)
        ..setAll(0, sal)
        ..buffer.asByteData().setUint32(sal.length, bloco);
      var u = hmac.convert(entrada).bytes;
      final t = List<int>.from(u);
      for (var i = 1; i < iteracoes; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      resultado.addAll(t);
      bloco++;
    }
    return resultado.sublist(0, tamanho);
  }

  static bool _iguais(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diferenca = 0;
    for (var i = 0; i < a.length; i++) {
      diferenca |= a[i] ^ b[i];
    }
    return diferenca == 0;
  }
}
