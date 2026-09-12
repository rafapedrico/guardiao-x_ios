import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Wrapper Dart em torno do plugin nativo local `SosDispatchPlugin`
/// (Kotlin) — controla o [Foreground Service dedicado
/// `SosDispatchService`] que mantém o PROCESSO do app vivo durante a
/// janela crítica de envio do SOS (SMS nativo + upload da foto ao
/// Firebase Storage/Firestore, ver [SosDisparoService]).
///
/// POR QUE ISSO EXISTE: sem um componente 100% nativo em foreground, o
/// envio do SOS depende inteiramente do processo/engine Dart continuar
/// vivo — se o Android decidir matar o processo no meio do envio
/// (memória baixa, Doze agressivo de fabricante, ou o usuário
/// forçar-fechar o app logo após acionar o pânico), o `Future` em voo
/// morre junto e o alerta pode nunca chegar a ser enviado. Este serviço
/// resolve isso pedindo ao Android, explicitamente, para não matar o
/// processo durante essa janela — o mesmo padrão nativo já usado neste
/// projeto para o alarme de rotina (`RotinaAlarmWakeService`) e o botão
/// físico de SOS (`VolumeSosService`).
///
/// Uso: sempre em par, com [executarComServicoAtivo] — nunca chame
/// [iniciar]/[parar] manualmente fora dele, para nunca correr o risco de
/// esquecer o `parar()` e deixar o Service preso (o teto de segurança de
/// 60s no lado nativo cobre esse caso mesmo assim, mas não deve ser a
/// única rede de proteção).
///
/// **iOS:** o canal `sos_dispatch` não tem (ainda) nenhum handler nativo
/// registrado — [_iniciar]/[_parar] lançam `MissingPluginException`, já
/// capturada e só logada como aviso (ver os try/catch abaixo), então
/// [executarComServicoAtivo] continua executando [corpo] normalmente,
/// só SEM a garantia real de "processo não vai ser morto no meio do
/// envio". O iOS não tem um equivalente exato de Foreground Service
/// para trabalho arbitrário em segundo plano — o mais próximo seria
/// `UIApplication.beginBackgroundTask`/`BGTaskScheduler` (janela de
/// poucos segundos, não uma garantia forte). Não implementado nesta
/// fase por não ser um equivalente direto/seguro — ver seção 5 de
/// `docs/migracao-ios-relatorio-2026-09-12.md`.
class SosDispatchNativeService {
  SosDispatchNativeService._internal();
  static final SosDispatchNativeService _instance = SosDispatchNativeService._internal();
  factory SosDispatchNativeService() => _instance;

  static const MethodChannel _canal =
      MethodChannel('com.example.security_check_app/sos_dispatch');

  Future<void> _iniciar() async {
    try {
      await _canal.invokeMethod('iniciar');
    } catch (e) {
      debugPrint('⚠️ [SosDispatchNativeService] Falha ao iniciar Foreground Service: $e');
    }
  }

  Future<void> _parar() async {
    try {
      await _canal.invokeMethod('parar');
    } catch (e) {
      debugPrint('⚠️ [SosDispatchNativeService] Falha ao parar Foreground Service: $e');
    }
  }

  /// Executa [corpo] (o envio real do SMS/upload) com o Foreground
  /// Service nativo ativo do início ao fim — iniciado ANTES de [corpo]
  /// começar, parado num `finally` assim que [corpo] terminar, com
  /// sucesso OU falha. Nunca deixa uma exceção de [corpo] impedir o
  /// `parar()` (o que deixaria o Service preso rodando).
  Future<T> executarComServicoAtivo<T>(Future<T> Function() corpo) async {
    await _iniciar();
    try {
      return await corpo();
    } finally {
      await _parar();
    }
  }
}
