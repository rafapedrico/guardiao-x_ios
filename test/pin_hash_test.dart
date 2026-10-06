import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/services/area_protegida_historico_service.dart';
import 'package:security_check_app/services/pin_hash.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PinHash', () {
    test('gera hash com sal que só confere com o PIN certo', () {
      final a = PinHash.gerar('1234');
      final b = PinHash.gerar('1234');
      expect(PinHash.ehHash(a), isTrue);
      expect(a, isNot(b), reason: 'sal aleatório');
      expect(a.contains('1234'), isFalse);
      expect(PinHash.verificar('1234', a), isTrue);
      expect(PinHash.verificar('4321', a), isFalse);
      expect(PinHash.verificar('', a), isFalse);
      expect(PinHash.verificar('1234', null), isFalse);
    });

    test('aceita o PIN antigo em texto puro e migra', () {
      expect(PinHash.verificar('5678', '5678'), isTrue);
      expect(PinHash.verificar('5679', '5678'), isFalse);
      final migrado = PinHash.migrar('5678')!;
      expect(PinHash.ehHash(migrado), isTrue);
      expect(PinHash.verificar('5678', migrado), isTrue);
      expect(PinHash.migrar(migrado), migrado);
      expect(PinHash.migrar(null), isNull);
    });
  });

  group('AreaProtegidaHistoricoService', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('3 erros bloqueiam por 5 min e o tempo dobra a cada bloqueio', () async {
      final area = AreaProtegidaHistoricoService();
      await area.registrarAcerto();
      expect(await area.registrarErro(), isNull);
      expect(await area.registrarErro(), isNull);
      final primeiro = await area.registrarErro();
      expect(primeiro, isNotNull);
      expect(primeiro!.difference(DateTime.now()).inMinutes, inInclusiveRange(4, 5));
      expect(await area.bloqueadoAte(), isNotNull);

      await area.registrarErro();
      await area.registrarErro();
      final segundo = await area.registrarErro();
      expect(segundo!.difference(DateTime.now()).inMinutes, inInclusiveRange(9, 10));

      await area.registrarAcerto();
      expect(await area.bloqueadoAte(), isNull);
    });
  });
}
