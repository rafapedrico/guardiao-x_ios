import 'package:shared_preferences/shared_preferences.dart';

/// Uma ocorrência (um toque) de um despertador de check-in (alarme de
/// rotina da aba Família). [ciclo] — o horário em epoch ms — identifica a
/// ocorrência em todo lugar: `cicloEpochMs` no documento
/// `alarmes_agendados`, o `eventoId` do alerta, `ultimo_disparo_epoch` no
/// SQLite e o payload das notificações.
class OcorrenciaDespertador {
  const OcorrenciaDespertador({
    required this.idAlarme,
    required this.horario,
    required this.minutosTolerancia,
    required this.alarme,
  });

  final int idAlarme;
  final DateTime horario;
  final int minutosTolerancia;

  /// Linha de `alarmes_rotina`.
  final Map<String, dynamic> alarme;

  int get ciclo => horario.millisecondsSinceEpoch;
  DateTime get fimTolerancia => horario.add(Duration(minutes: minutosTolerancia));
  String get eventoId => 'rotina_${idAlarme}_$ciclo';

  bool emAndamento([DateTime? agora]) {
    final t = agora ?? DateTime.now();
    return !t.isBefore(horario) && t.isBefore(fimTolerancia);
  }
}

/// Regras de ciclo do despertador, iguais no app e no heartbeat da nuvem:
///   - a ocorrência ALVO é a que está tocando (dentro da tolerância e ainda
///     não resolvida neste aparelho) ou, sem ela, a próxima;
///   - "pausado por hoje" (`alarme_pausado` = data de hoje) pula as
///     ocorrências de hoje — nunca reativa a de hoje;
///   - uma ocorrência é resolvida pelo PIN correto ou pelo alerta enviado;
///     só depois disso a próxima é armada.
class CicloDespertador {
  CicloDespertador._();

  static String _chaveResolvido(int idAlarme) => 'despertador_ciclo_resolvido_$idAlarme';

  static String dataDe(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static bool pausadoHoje(Map<String, dynamic> alarme, [DateTime? agora]) =>
      alarme['alarme_pausado']?.toString() == dataDe(agora ?? DateTime.now());

  /// 00:00 do dia seguinte, enquanto pausado por hoje.
  static DateTime? pausadoAte(Map<String, dynamic> alarme, [DateTime? agora]) {
    final t = agora ?? DateTime.now();
    if (!pausadoHoje(alarme, t)) return null;
    return DateTime(t.year, t.month, t.day + 1);
  }

  static Set<int> _dias(Map<String, dynamic> alarme) => ((alarme['dias_semana'] as String?) ?? '')
      .split(',')
      .map((s) => int.tryParse(s.trim()))
      .whereType<int>()
      .where((d) => d >= 1 && d <= 7)
      .toSet();

  /// Horários das ocorrências de [alarme] que começam em [inicio, fim]
  /// (horário local). Sem dia da semana: só hoje (mesma regra de sempre).
  static List<DateTime> horariosEntre(Map<String, dynamic> alarme, DateTime inicio, DateTime fim) {
    final hora = alarme['hora'] as int? ?? 0;
    final minuto = alarme['minuto'] as int? ?? 0;
    final dias = _dias(alarme);
    final resultado = <DateTime>[];
    if (dias.isEmpty) {
      final hoje = DateTime.now();
      final candidato = DateTime(hoje.year, hoje.month, hoje.day, hora, minuto);
      if (!candidato.isBefore(inicio) && !candidato.isAfter(fim)) resultado.add(candidato);
      return resultado;
    }
    for (var dia = DateTime(inicio.year, inicio.month, inicio.day);
        !dia.isAfter(fim);
        dia = DateTime(dia.year, dia.month, dia.day + 1)) {
      if (!dias.contains(dia.weekday)) continue;
      final candidato = DateTime(dia.year, dia.month, dia.day, hora, minuto);
      if (!candidato.isBefore(inicio) && !candidato.isAfter(fim)) resultado.add(candidato);
    }
    return resultado;
  }

  static OcorrenciaDespertador _ocorrencia(Map<String, dynamic> alarme, DateTime horario) =>
      OcorrenciaDespertador(
        idAlarme: alarme['id'] as int,
        horario: horario,
        minutosTolerancia: alarme['minutos_tolerancia'] as int? ?? 10,
        alarme: alarme,
      );

  /// Próximas ocorrências que ainda vão começar (para agendar o toque),
  /// pulando as de hoje quando pausado por hoje.
  static List<OcorrenciaDespertador> proximas(Map<String, dynamic> alarme,
      {Duration horizonte = const Duration(days: 8), DateTime? agora}) {
    if ((alarme['ativo'] as int?) != 1 || alarme['id'] == null) return const [];
    final t = agora ?? DateTime.now();
    final ate = pausadoAte(alarme, t);
    final inicio = ate != null && ate.isAfter(t) ? ate : t.add(const Duration(seconds: 1));
    return horariosEntre(alarme, inicio, t.add(horizonte)).map((h) => _ocorrencia(alarme, h)).toList();
  }

  /// Ocorrência tocando agora (dentro da tolerância), não resolvida neste
  /// aparelho e não pausada.
  static Future<OcorrenciaDespertador?> emAndamento(Map<String, dynamic> alarme, {DateTime? agora}) async {
    if ((alarme['ativo'] as int?) != 1 || alarme['id'] == null) return null;
    final t = agora ?? DateTime.now();
    if (pausadoHoje(alarme, t)) return null;
    final tolerancia = Duration(minutes: alarme['minutos_tolerancia'] as int? ?? 10);
    final candidatos = horariosEntre(alarme, t.subtract(tolerancia), t);
    if (candidatos.isEmpty) return null;
    final ocorrencia = _ocorrencia(alarme, candidatos.last);
    if (!ocorrencia.emAndamento(t)) return null;
    if (await cicloResolvido(ocorrencia.idAlarme) == ocorrencia.ciclo) return null;
    return ocorrencia;
  }

  /// A ocorrência que o ciclo da nuvem acompanha agora: a em andamento ou,
  /// sem ela, a próxima.
  static Future<OcorrenciaDespertador?> alvo(Map<String, dynamic> alarme, {DateTime? agora}) async {
    final atual = await emAndamento(alarme, agora: agora);
    if (atual != null) return atual;
    final seguintes = proximas(alarme, agora: agora);
    return seguintes.isEmpty ? null : seguintes.first;
  }

  /// Ocorrência pelo [ciclo] (payload de notificação/AlarmKit).
  static OcorrenciaDespertador ocorrenciaDoCiclo(Map<String, dynamic> alarme, int ciclo) =>
      _ocorrencia(alarme, DateTime.fromMillisecondsSinceEpoch(ciclo));

  static Future<int?> cicloResolvido(int idAlarme) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getInt(_chaveResolvido(idAlarme));
    } catch (_) {
      return null;
    }
  }

  static Future<void> marcarResolvido(int idAlarme, int ciclo) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_chaveResolvido(idAlarme), ciclo);
    } catch (_) {}
  }
}
