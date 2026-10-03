import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Registro dos últimos [capacidade] erros/avisos do app, com horário, para
/// a tela Diagnóstico (Configurações > Diagnóstico, ou 5 toques no cadeado
/// da tela de bloqueio). Existe para o usuário conseguir mandar o erro
/// REAL de um build do TestFlight sem Mac/Xcode/console por perto.
///
/// Captura, a partir de [instalar] (chamado no início de `main()`):
/// - `debugPrint` com marcador de problema (⚠️, 🚨, ❌, "Falha", "Erro",
///   "erro", "Exception") — é o padrão de todos os try/catch do app;
/// - [FlutterError.onError] (erros de build/layout/gestos/navegação — ex:
///   o "Null check operator" que travava o Navigator no build 107);
/// - [PlatformDispatcher.onError] (exceções assíncronas não tratadas).
///
/// O buffer é persistido no SharedPreferences (gravação agrupada), para
/// que o erro que antecedeu um fechamento/crash ainda esteja lá quando o
/// app for reaberto.
class DiagnosticoService {
  DiagnosticoService._internal();
  static final DiagnosticoService _instance = DiagnosticoService._internal();
  factory DiagnosticoService() => _instance;

  static const int capacidade = 200;
  static const String _chavePrefs = 'diagnostico_registros_v1';
  static const int _tamanhoMaximoEntrada = 4000;

  static final RegExp _marcadorProblema =
      RegExp(r'⚠️|🚨|❌|🔒|Falha|falha|Erro|erro|Exception|Error');

  final List<String> _registros = <String>[];
  final ValueNotifier<int> versao = ValueNotifier<int>(0);
  bool _instalado = false;
  bool _carregado = false;
  Timer? _timerGravacao;

  List<String> get registros => List.unmodifiable(_registros);

  void instalar() {
    if (_instalado) return;
    _instalado = true;

    final debugPrintOriginal = debugPrint;
    debugPrint = (String? mensagem, {int? wrapWidth}) {
      debugPrintOriginal(mensagem, wrapWidth: wrapWidth);
      if (mensagem != null && _marcadorProblema.hasMatch(mensagem)) {
        registrar(mensagem);
      }
    };

    final onErrorOriginal = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails detalhes) {
      registrar('[FlutterError] ${detalhes.exceptionAsString()}\n'
          '${_pilhaResumida(detalhes.stack)}');
      if (onErrorOriginal != null) {
        onErrorOriginal(detalhes);
      } else {
        FlutterError.presentError(detalhes);
      }
    };

    final plataformaOriginal = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object erro, StackTrace pilha) {
      registrar('[Não tratado] ${erro.runtimeType}: $erro\n${_pilhaResumida(pilha)}');
      return plataformaOriginal?.call(erro, pilha) ?? false;
    };

    unawaited(_carregar());
  }

  void registrar(String mensagem) {
    final agora = DateTime.now();
    var texto = mensagem.trim();
    if (texto.length > _tamanhoMaximoEntrada) {
      texto = '${texto.substring(0, _tamanhoMaximoEntrada)}…';
    }
    _registros.add('${_horario(agora)}  $texto');
    if (_registros.length > capacidade) {
      _registros.removeRange(0, _registros.length - capacidade);
    }
    _notificar();
    _agendarGravacao();
  }

  bool _notificacaoAgendada = false;

  /// Notifica a tela fora da fase de build: um erro registrado DURANTE um
  /// build (FlutterError) não pode disparar setState de forma síncrona.
  void _notificar() {
    if (_notificacaoAgendada) return;
    _notificacaoAgendada = true;
    scheduleMicrotask(() {
      _notificacaoAgendada = false;
      versao.value++;
    });
  }

  /// Texto completo para copiar (mais recente por último).
  String textoParaCopiar() => _registros.join('\n\n');

  Future<void> limpar() async {
    _registros.clear();
    _notificar();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_chavePrefs);
    } catch (_) {}
  }

  Future<void> _carregar() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final salvos = prefs.getStringList(_chavePrefs) ?? const <String>[];
      // Registros desta execução que chegaram antes da leitura ficam por
      // último (são os mais novos).
      _registros.insertAll(0, salvos);
      if (_registros.length > capacidade) {
        _registros.removeRange(0, _registros.length - capacidade);
      }
      _notificar();
    } catch (_) {
      // Sem SharedPreferences (teste, engine sem plugins): só memória.
    } finally {
      _carregado = true;
    }
  }

  void _agendarGravacao() {
    if (_timerGravacao?.isActive ?? false) return;
    _timerGravacao = Timer(const Duration(seconds: 2), () async {
      if (!_carregado) {
        _agendarGravacao();
        return;
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_chavePrefs, List<String>.of(_registros));
      } catch (_) {}
    });
  }

  static String _pilhaResumida(StackTrace? pilha) {
    if (pilha == null) return '';
    return pilha.toString().split('\n').where((l) => l.trim().isNotEmpty).take(12).join('\n');
  }

  static String _horario(DateTime d) {
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${dois(d.day)}/${dois(d.month)} ${dois(d.hour)}:${dois(d.minute)}:${dois(d.second)}';
  }
}
