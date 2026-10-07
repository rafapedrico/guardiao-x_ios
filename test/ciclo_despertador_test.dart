import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/services/ciclo_despertador.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, dynamic> alarme(DateTime horario, {String? pausado, int tolerancia = 10}) => {
        'id': 7,
        'hora': horario.hour,
        'minuto': horario.minute,
        'dias_semana': '1,2,3,4,5,6,7',
        'ativo': 1,
        'minutos_tolerancia': tolerancia,
        'alarme_pausado': pausado,
      };

  test('próxima ocorrência é hoje; pausado por hoje pula para amanhã', () {
    final agora = DateTime.now();
    final daquiAPouco = agora.add(const Duration(minutes: 30));
    final semPausa = CicloDespertador.proximas(alarme(daquiAPouco));
    expect(semPausa.first.horario.day, daquiAPouco.day);

    final pausado = CicloDespertador.proximas(
        alarme(daquiAPouco, pausado: CicloDespertador.dataDe(agora)));
    expect(pausado.first.horario.isAfter(DateTime(agora.year, agora.month, agora.day + 1)), isTrue);
    expect(CicloDespertador.pausadoAte(alarme(daquiAPouco, pausado: CicloDespertador.dataDe(agora))),
        DateTime(agora.year, agora.month, agora.day + 1));
  });

  test('ocorrência em andamento até o fim da tolerância e some quando resolvida', () async {
    final agora = DateTime.now();
    final tocouHa2Min = DateTime(agora.year, agora.month, agora.day, agora.hour, agora.minute)
        .subtract(const Duration(minutes: 2));
    final dados = alarme(tocouHa2Min);
    final emAndamento = await CicloDespertador.emAndamento(dados);
    expect(emAndamento, isNotNull);
    expect(emAndamento!.eventoId, 'rotina_7_${emAndamento.ciclo}');
    expect((await CicloDespertador.alvo(dados))!.ciclo, emAndamento.ciclo);

    await CicloDespertador.marcarResolvido(7, emAndamento.ciclo);
    expect(await CicloDespertador.emAndamento(dados), isNull);
    expect((await CicloDespertador.alvo(dados))!.horario.isAfter(agora), isTrue,
        reason: 'resolvida a atual, o alvo passa a ser a próxima');
  });

  test('pausado por hoje não tem ocorrência em andamento hoje', () async {
    final agora = DateTime.now();
    final tocou = agora.subtract(const Duration(minutes: 1));
    expect(
        await CicloDespertador.emAndamento(alarme(tocou, pausado: CicloDespertador.dataDe(agora))),
        isNull);
  });
}
