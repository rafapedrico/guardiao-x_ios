import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n_headless_service.dart';
import 'notificacao_service.dart';
import 'plano_ciclo_service.dart';

/// Período do ciclo em que o botão SOS (Widget SOS do iOS) fica desativado
/// no Plano Free: do dia 11 ([inicio]) até a renovação do ciclo ([fim]).
@immutable
class BloqueioSosPlano {
  const BloqueioSosPlano({required this.inicio, required this.fim});

  final DateTime inicio;
  final DateTime fim;

  /// Período do ciclo de [status]; `null` para Premium ou sem status.
  static BloqueioSosPlano? doCiclo(PlanoCicloStatus? status) {
    if (status == null || status.isPremium) return null;
    return BloqueioSosPlano(
      inicio: status.cycleStartDate.add(const Duration(days: 10)).toLocal(),
      fim: status.dataRenovacao.toLocal(),
    );
  }

  /// Período em vigor AGORA (botão desativado); `null` fora dele.
  static BloqueioSosPlano? vigente(PlanoCicloStatus? status) {
    if (status == null || status.ativo) return null;
    return doCiclo(status);
  }
}

/// "DD/MM" — mesmo padrão de data numérica usado no resto do app.
String formatarDiaMes(DateTime data) =>
    '${data.day.toString().padLeft(2, '0')}/${data.month.toString().padLeft(2, '0')}';

/// Avisa ANTES que o botão SOS vai parar nos dias bloqueados do Plano Free
/// (dias 11–30 do ciclo), para ninguém contar com ele e ser pego de
/// surpresa. O bloqueio em si não muda (ver [PlanoCicloService]).
///
/// Notificações LOCAIS, calculadas a partir do `cycleStartDate` (nada de
/// servidor):
///   - lembrete na véspera, às 10h: "ficará desativado a partir de amanhã
///     (DD/MM) até DD/MM…";
///   - no início do bloqueio (não antes das 8h): "está desativado até
///     DD/MM…".
/// Reagendadas sempre que o ciclo ou o plano mudam (ouvindo
/// [PlanoCicloService.statusStream]); Premium cancela tudo.
class SosPlanoAvisoService {
  SosPlanoAvisoService._internal();
  static final SosPlanoAvisoService _instance = SosPlanoAvisoService._internal();
  factory SosPlanoAvisoService() => _instance;

  static const int _idLembrete = 510001;
  static const int _idInicio = 510002;
  static const String payloadNotificacao = 'sos_plano_free';
  static const String _chaveLembreteExibido = 'sos_plano_lembrete_exibido_ciclo';

  StreamSubscription<PlanoCicloStatus?>? _assinatura;
  String? _ultimaChave;

  /// Começa a acompanhar o ciclo. Chamado uma vez por sessão (ver
  /// `iniciarServicosPosLoginOuDashboard`).
  void iniciar() {
    if (!Platform.isIOS || _assinatura != null) return;
    _assinatura = PlanoCicloService().statusStream().listen((status) {
      if (status == null) return;
      final chave = '${status.isPremium}_${status.cycleStartDate.millisecondsSinceEpoch}';
      if (chave == _ultimaChave) return;
      _ultimaChave = chave;
      unawaited(_reagendar(status));
    });
  }

  Future<void> _reagendar(PlanoCicloStatus status) async {
    try {
      await NotificacaoService.cancelarAvisoLocal(_idLembrete);
      await NotificacaoService.cancelarAvisoLocal(_idInicio);
      final bloqueio = BloqueioSosPlano.doCiclo(status);
      if (bloqueio == null) {
        debugPrint('💎 [SosPlanoAviso] Premium — avisos do botão SOS cancelados.');
        return;
      }

      final l10n = await L10nHeadlessService.obter();
      final inicio = formatarDiaMes(bloqueio.inicio);
      final fim = formatarDiaMes(bloqueio.fim);
      final agora = DateTime.now();

      final vespera = bloqueio.inicio.subtract(const Duration(days: 1));
      final momentoLembrete = DateTime(vespera.year, vespera.month, vespera.day, 10);
      final textoLembrete = l10n.sosPlanoLembreteNotificacao(inicio, fim);
      if (momentoLembrete.isAfter(agora)) {
        await NotificacaoService.agendarAvisoLocal(
          id: _idLembrete,
          titulo: l10n.sosPlanoNotificacaoTitulo,
          corpo: textoLembrete,
          quando: momentoLembrete,
          payload: payloadNotificacao,
        );
      } else if (agora.isBefore(bloqueio.inicio)) {
        // Já passou das 10h da véspera (app aberto só agora): avisa já,
        // uma vez por ciclo.
        final prefs = await SharedPreferences.getInstance();
        final ciclo = status.cycleStartDate.millisecondsSinceEpoch;
        if (prefs.getInt(_chaveLembreteExibido) != ciclo) {
          await prefs.setInt(_chaveLembreteExibido, ciclo);
          await NotificacaoService.exibirAvisoLocal(
            id: _idLembrete,
            titulo: l10n.sosPlanoNotificacaoTitulo,
            corpo: textoLembrete,
            payload: payloadNotificacao,
          );
        }
      }

      final inicioDoDia = bloqueio.inicio;
      final oitoHoras = DateTime(inicioDoDia.year, inicioDoDia.month, inicioDoDia.day, 8);
      await NotificacaoService.agendarAvisoLocal(
        id: _idInicio,
        titulo: l10n.sosPlanoNotificacaoTitulo,
        corpo: l10n.sosPlanoDesativadoAte(fim),
        quando: inicioDoDia.isBefore(oitoHoras) ? oitoHoras : inicioDoDia,
        payload: payloadNotificacao,
      );
      debugPrint('💎 [SosPlanoAviso] Avisos do botão SOS agendados (bloqueio $inicio–$fim).');
    } catch (e) {
      debugPrint('⚠️ [SosPlanoAviso] Falha ao agendar os avisos do botão SOS: $e');
    }
  }
}
