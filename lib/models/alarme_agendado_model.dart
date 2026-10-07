import 'package:cloud_firestore/cloud_firestore.dart';

/// Status do ciclo de vida de um [AlarmeAgendadoModel] no Firestore,
/// espelhando (na nuvem) o mesmo fluxo já validado do alarme de rotina
/// local (ver `RotinaAlarmeService`): o documento nasce `pendente` assim
/// que o alarme entra na janela de heartbeat (ver
/// `BackgroundLocationHeartbeatService`), muda para `confirmadoSeguro`
/// assim que o PIN correto é digitado no aparelho (ver
/// `RotinaAlarmeService.confirmarCheckinRotina`), ou para
/// `alertaDisparado` quando a Cloud Function de monitoramento agendado
/// (ver `cloud_functions/scheduledAlarmMonitor.ts`) detecta que o horário
/// limite foi ultrapassado sem confirmação.
///
/// CORREÇÃO (2026-08-23, checagem pré-disparo local + sincronização
/// imediata de pausa/cancelamento): dois novos status, escritos
/// diretamente pelo APP (nunca pela Cloud Function) assim que o usuário
/// cancela/pausa um alarme/rotina pela interface — ver
/// [AlarmeAgendadoCloudService.marcarCancelado]/[marcarPausado] e
/// `RotinaAlarmeService.cancelarAlarme`/`pausarAlarme`. Qualquer status
/// diferente de [pendente] (inclusive estes dois) sinaliza que a nuvem
/// já é dona do desfecho do ciclo — ver
/// [AlarmeAgendadoCloudService.statusJaResolvidoNaNuvem], consultado
/// pelo alarme local ANTES de tocar sirene ou enviar SMS/Push, evitando
/// duplicidade quando o aparelho religa ou reconecta depois que a nuvem
/// já assumiu o ciclo sozinha.
enum AlarmeAgendadoStatus {
  pendente,
  confirmadoSeguro,
  alertaDisparado,
  cancelado,
  pausado;

  /// Valor exatamente como gravado no Firestore (mesma grafia lida pela
  /// Cloud Function em TypeScript, ver `cloud_functions/`).
  String get valorFirestore {
    switch (this) {
      case AlarmeAgendadoStatus.pendente:
        return 'PENDENTE';
      case AlarmeAgendadoStatus.confirmadoSeguro:
        return 'CONFIRMADO_SEGURA';
      case AlarmeAgendadoStatus.alertaDisparado:
        return 'ALERTA_DISPARADO';
      case AlarmeAgendadoStatus.cancelado:
        return 'CANCELADO';
      case AlarmeAgendadoStatus.pausado:
        return 'PAUSADO';
    }
  }

  /// `true` para qualquer status diferente de [pendente] — a nuvem já
  /// assumiu o desfecho deste ciclo (confirmado seguro, alerta já
  /// disparado pela Cloud Function, cancelado ou pausado pelo usuário) e
  /// o alarme local NÃO deve mais agir (tocar sirene, enviar SMS/Push)
  /// para este mesmo ciclo. Ver [AlarmeAgendadoCloudService.statusJaResolvidoNaNuvem].
  bool get jaResolvidoNaNuvem => this != AlarmeAgendadoStatus.pendente;

  static AlarmeAgendadoStatus fromFirestore(String? valor) {
    switch (valor) {
      case 'CONFIRMADO_SEGURA':
        return AlarmeAgendadoStatus.confirmadoSeguro;
      case 'ALERTA_DISPARADO':
        return AlarmeAgendadoStatus.alertaDisparado;
      case 'CANCELADO':
        return AlarmeAgendadoStatus.cancelado;
      case 'PAUSADO':
        return AlarmeAgendadoStatus.pausado;
      case 'PENDENTE':
      default:
        return AlarmeAgendadoStatus.pendente;
    }
  }
}

/// Última localização conhecida do usuário no momento do heartbeat (ver
/// `BackgroundLocationHeartbeatService`), embutida diretamente no
/// documento do alarme — permite que a Cloud Function monte o link do
/// Google Maps sem precisar de uma segunda coleção/leitura.
class UltimaLocalizacaoModel {
  final double lat;
  final double lng;

  /// `null` ao montar o mapa para escrita = usa o timestamp do SERVIDOR
  /// (`FieldValue.serverTimestamp()`), preferível sempre que possível
  /// (evita depender do relógio do aparelho). Só vem preenchido ao ler de
  /// volta um documento já existente (ver [fromMap]).
  final DateTime? timestamp;

  const UltimaLocalizacaoModel({
    required this.lat,
    required this.lng,
    this.timestamp,
  });

  Map<String, dynamic> toMap() => {
        'lat': lat,
        'lng': lng,
        'timestamp': FieldValue.serverTimestamp(),
      };

  factory UltimaLocalizacaoModel.fromMap(Map<String, dynamic>? map) {
    if (map == null) {
      return const UltimaLocalizacaoModel(lat: 0, lng: 0);
    }
    final ts = map['timestamp'];
    return UltimaLocalizacaoModel(
      lat: (map['lat'] as num?)?.toDouble() ?? 0,
      lng: (map['lng'] as num?)?.toDouble() ?? 0,
      timestamp: ts is Timestamp ? ts.toDate() : null,
    );
  }
}

/// Modelo do documento `alarmes_agendados/{idAlarme}` no Firestore — uma
/// camada de monitoramento na nuvem PARALELA e independente do alarme
/// local (`android_alarm_manager_plus` + `RotinaAlarmeService`), pensada
/// para que uma Cloud Function agendada (ver `cloud_functions/`) possa
/// disparar o alerta de emergência mesmo que o aparelho seja
/// destruído/desligado/perca sinal antes do prazo local expirar.
///
/// NÃO substitui o fluxo local já validado (som, tela, tolerância, janela
/// final, SMS nativo) — é uma camada A MAIS de resiliência, assim como
/// `FirebaseSyncService` já é para o alerta reativo de tentativa de
/// desarme incorreta.
class AlarmeAgendadoModel {
  final String idAlarme;
  final DateTime dataHoraDisparo;

  /// Prazo REAL que a Cloud Function agendada (ver
  /// `cloud_functions/scheduledAlarmMonitor.ts`) usa para decidir se o
  /// alarme "venceu sem confirmação" — `dataHoraDisparo` + tolerância +
  /// janela final (`RotinaAlarmeService.duracaoJanelaFinal`), OU SEJA, o
  /// mesmo instante em que o alerta de emergência REAL dispara
  /// localmente. Calculado no app (que sabe a tolerância configurada por
  /// alarme) para a function não precisar reimplementar essa regra.
  final DateTime prazoFinalDisparo;

  final AlarmeAgendadoStatus status;
  final UltimaLocalizacaoModel? ultimaLocalizacao;

  /// Dono do documento (`uid` do Firebase Auth) — necessário para que as
  /// regras do Firestore (`firestore.rules`) restrinjam leitura/escrita a
  /// quem é dono do alarme, e para o id do documento ser namespaced por
  /// usuário (ver [AlarmeAgendadoCloudService]), evitando colisão entre o
  /// mesmo `idAlarme` local de dois usuários diferentes.
  final String usuarioId;

  /// Contatos de emergência no formato `{nome, telefone}` — mesmo formato
  /// gravado em `usuarios/{uid}.contatosEmergencia` (ver
  /// `FirebaseSyncService.sincronizarContatosEmergencia`). A Cloud
  /// Function de disparo (`functions/alertaHibridoService.js`) resolve
  /// dinamicamente, por telefone, quais desses contatos têm conta no app
  /// e envia o Push FCM gratuito para quem for encontrado.
  final List<Map<String, dynamic>> contatosEmergencia;

  /// Etiqueta do alarme (ex: "Corrida no parque") e contexto
  /// personalizado (ex: "Vou por essa trilha, aviso quando voltar"),
  /// copiados do SQLite local — repassados para a Cloud Function incluir
  /// na mensagem de alerta, dando mais contexto aos contatos de
  /// emergência além de horário/localização.
  final String etiqueta;
  final String contextoPersonalizado;

  /// Ocorrência que este documento acompanha (horário em epoch ms, ver
  /// `CicloDespertador`). `null` no cronômetro de check-in.
  final int? cicloEpochMs;

  /// Fim da pausa ("pausado por hoje" = 00h00 do dia seguinte); `null` sem
  /// pausa. Gravado em todo documento, igual ao Android.
  final DateTime? pausadoAte;

  /// Ciclo efetivo: [cicloEpochMs] ou, sem ele, o horário.
  int get ciclo => cicloEpochMs ?? dataHoraDisparo.millisecondsSinceEpoch;

  const AlarmeAgendadoModel({
    required this.idAlarme,
    required this.dataHoraDisparo,
    required this.prazoFinalDisparo,
    required this.usuarioId,
    this.status = AlarmeAgendadoStatus.pendente,
    this.ultimaLocalizacao,
    this.contatosEmergencia = const [],
    this.etiqueta = '',
    this.contextoPersonalizado = '',
    this.cicloEpochMs,
    this.pausadoAte,
  });

  Map<String, dynamic> toFirestore() => {
        'idAlarme': idAlarme,
        'usuarioId': usuarioId,
        'dataHoraDisparo': Timestamp.fromDate(dataHoraDisparo),
        'prazoFinalEpochMs': prazoFinalDisparo.millisecondsSinceEpoch,
        'status': status.valorFirestore,
        if (ultimaLocalizacao != null)
          'ultimaLocalizacao': ultimaLocalizacao!.toMap(),
        'contatosEmergencia': contatosEmergencia,
        'etiqueta': etiqueta,
        'contextoPersonalizado': contextoPersonalizado,
        'cicloEpochMs': ciclo,
        'pausadoAte': pausadoAte != null ? Timestamp.fromDate(pausadoAte!) : null,
      };

  factory AlarmeAgendadoModel.fromFirestore(
    Map<String, dynamic> dados,
    String idDocumento,
  ) {
    final dataHora = dados['dataHoraDisparo'];
    final prazoFinalEpochMs = dados['prazoFinalEpochMs'] as int?;
    return AlarmeAgendadoModel(
      idAlarme: (dados['idAlarme'] as String?) ?? idDocumento,
      usuarioId: (dados['usuarioId'] as String?) ?? '',
      dataHoraDisparo:
          dataHora is Timestamp ? dataHora.toDate() : DateTime.now(),
      prazoFinalDisparo: prazoFinalEpochMs != null
          ? DateTime.fromMillisecondsSinceEpoch(prazoFinalEpochMs)
          : (dataHora is Timestamp ? dataHora.toDate() : DateTime.now()),
      status: AlarmeAgendadoStatus.fromFirestore(dados['status'] as String?),
      ultimaLocalizacao: UltimaLocalizacaoModel.fromMap(
        dados['ultimaLocalizacao'] as Map<String, dynamic>?,
      ),
      contatosEmergencia:
          (dados['contatosEmergencia'] as List?)?.cast<Map<String, dynamic>>() ??
              const [],
      etiqueta: (dados['etiqueta'] as String?) ?? '',
      contextoPersonalizado: (dados['contextoPersonalizado'] as String?) ?? '',
      cicloEpochMs: (dados['cicloEpochMs'] as num?)?.toInt(),
      pausadoAte: (dados['pausadoAte'] as Timestamp?)?.toDate(),
    );
  }
}
