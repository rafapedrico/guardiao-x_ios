import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/pin_dialog.dart';

/// Área do Histórico protegida pelo PIN de Configurações ("Alertas
/// enviados": SOS, fotos e todos os eventos do cronômetro e do despertador).
///
/// Liberação: vale até sair da aba Histórico ([bloquear], chamado pela
/// HomeScreen e pelo `dispose` da aba) ou até 2 minutos com o app em
/// segundo plano — depois, pede o PIN de novo. Nunca persiste entre
/// aberturas do app.
///
/// Tentativas ([ControleTentativasPin]): 3 PINs errados bloqueiam a área por
/// 5 minutos, com o tempo dobrando a cada novo bloqueio (10, 20, 40…). O
/// estado fica em SharedPreferences, então fechar e abrir o app não zera a
/// contagem. O PIN certo zera os erros e o nível de bloqueio.
class AreaProtegidaHistoricoService with WidgetsBindingObserver implements ControleTentativasPin {
  AreaProtegidaHistoricoService._internal();
  static final AreaProtegidaHistoricoService _instance = AreaProtegidaHistoricoService._internal();
  factory AreaProtegidaHistoricoService() => _instance;

  static const int errosParaBloquear = 3;
  static const Duration bloqueioInicial = Duration(minutes: 5);
  static const Duration limiteSegundoPlano = Duration(minutes: 2);

  static const String _chaveErros = 'historico_pin_erros';
  static const String _chaveBloqueadoAte = 'historico_pin_bloqueado_ate_ms';
  static const String _chaveNivel = 'historico_pin_nivel_bloqueio';

  /// `true` enquanto a área estiver liberada.
  final ValueNotifier<bool> liberado = ValueNotifier<bool>(false);

  DateTime? _foiParaSegundoPlanoEm;
  bool _observando = false;

  void _garantirObservador() {
    if (_observando) return;
    _observando = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void liberar() {
    _garantirObservador();
    liberado.value = true;
  }

  void bloquear() {
    liberado.value = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _foiParaSegundoPlanoEm ??= DateTime.now();
        break;
      case AppLifecycleState.resumed:
        final desde = _foiParaSegundoPlanoEm;
        _foiParaSegundoPlanoEm = null;
        if (desde != null && DateTime.now().difference(desde) >= limiteSegundoPlano) {
          bloquear();
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Future<DateTime?> bloqueadoAte() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_chaveBloqueadoAte);
      if (ms == null) return null;
      final fim = DateTime.fromMillisecondsSinceEpoch(ms);
      return fim.isAfter(DateTime.now()) ? fim : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<DateTime?> registrarErro() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final erros = (prefs.getInt(_chaveErros) ?? 0) + 1;
      if (erros < errosParaBloquear) {
        await prefs.setInt(_chaveErros, erros);
        return null;
      }
      final nivel = prefs.getInt(_chaveNivel) ?? 0;
      final fim = DateTime.now().add(bloqueioInicial * (1 << nivel.clamp(0, 10)));
      await prefs.setInt(_chaveErros, 0);
      await prefs.setInt(_chaveNivel, nivel + 1);
      await prefs.setInt(_chaveBloqueadoAte, fim.millisecondsSinceEpoch);
      return fim;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> registrarAcerto() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_chaveErros);
      await prefs.remove(_chaveNivel);
      await prefs.remove(_chaveBloqueadoAte);
    } catch (_) {}
  }
}
