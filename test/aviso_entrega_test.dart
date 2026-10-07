import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/services/aviso_entrega_service.dart';

void main() {
  test('status do aviso de entrega: statusEntrega, situacao e tipo', () {
    expect(AvisoEntregaService.statusDoPush({'tipo': 'aviso_entrega_alerta', 'statusEntrega': 'entregue'}),
        StatusEntregaContato.entregue);
    expect(AvisoEntregaService.statusDoPush({'tipo': 'aviso_entrega_alerta', 'situacao': 'pendente'}),
        StatusEntregaContato.tentando);
    expect(AvisoEntregaService.statusDoPush({'tipo': 'entrega_alerta_nao_entregue'}),
        StatusEntregaContato.naoEntregue);
    expect(AvisoEntregaService.statusDoPush({'tipo': 'aviso_entrega_alerta'}), isNull);
  });

  test('nome do contato com fallback para nomeDestinatario', () {
    expect(AvisoEntregaService.nomeDoContato({'nomeContato': ' Ana '}), 'Ana');
    expect(AvisoEntregaService.nomeDoContato({'nomeDestinatario': 'Bia'}), 'Bia');
    expect(AvisoEntregaService.tipos.contains('aviso_entrega_alerta'), isTrue);
  });
}
