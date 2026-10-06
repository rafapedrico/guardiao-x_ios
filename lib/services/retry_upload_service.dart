import 'dart:async';
import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:camera/camera.dart' show XFile;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'database_helper.dart';
import 'sos_disparo_service.dart';

/// Fila de RESILIÊNCIA OFFLINE para o upload da foto do SOS ao Firebase
/// Storage/Firestore (P2 da sequência unificada, ver [SosDisparoService]):
/// quando a chamada de rede falha no momento do disparo (sem
/// Wi-Fi/4G/sinal, Storage indisponível, timeout, etc.), o SMS com a
/// mensagem de fallback já foi enviado via GSM normalmente (nunca depende
/// de internet) — mas o link real da foto/alerta na nuvem ficaria perdido
/// para sempre sem esta fila.
///
/// ESTRATÉGIA: o payload (cópia PERMANENTE da foto + metadados) é salvo
/// no SQLite local (tabela `fila_retry_upload_sos`, ver [DatabaseHelper])
/// assim que o upload falha. Duas oportunidades de reenvio automático,
/// SEM exigir nenhuma ação do usuário:
/// 1. [tentarDrenarFilaAgora] — chamado uma vez a cada cold start do app
///    (ver `main.dart`), cobrindo o caso mais comum: usuário reabre o
///    app depois que a conectividade já voltou.
/// 2. Um alarme nativo periódico (`AndroidAlarmManager.periodic`, mesmo
///    mecanismo já usado por [RotinaAlarmeService] neste projeto),
///    tentando a cada 15 minutos enquanto houver itens pendentes — cobre
///    o caso do app permanecer minimizado/fechado por um longo período.
///
/// Cada item tem um teto de [_maxTentativas] — depois disso, desiste e
/// remove o item (mantendo o arquivo de foto local, nunca apagado
/// automaticamente) para não reter tentativas indefinidas de um upload
/// que pode estar falhando por outro motivo que não seja conectividade
/// (ex: conta removida, regra de segurança do Storage).
class RetryUploadService {
  RetryUploadService._internal();
  static final RetryUploadService _instance = RetryUploadService._internal();
  factory RetryUploadService() => _instance;

  static const int _maxTentativas = 10;
  static const int _idAlarmePeriodico = 990011;

  final DatabaseHelper _db = DatabaseHelper();

  /// Chamado uma única vez no início do app (`main.dart`), depois do
  /// Firebase estar inicializado — agenda o alarme periódico de retry
  /// (idempotente: reagendar com o mesmo id substitui o anterior, nunca
  /// duplica) e dispara uma tentativa oportunista imediata.
  Future<void> iniciar() async {
    try {
      await AndroidAlarmManager.periodic(
        const Duration(minutes: 15),
        _idAlarmePeriodico,
        _callbackRetryPeriodico,
        wakeup: true,
        rescheduleOnReboot: true,
      );
    } catch (e) {
      debugPrint('⚠️ [RetryUploadService] Falha ao agendar alarme periódico de retry: $e');
    }

    // Tentativa oportunista no cold start: fire-and-forget, nunca atrasa
    // a inicialização do app.
    unawaited(tentarDrenarFilaAgora());
  }

  /// Copia [fotoOriginal] (arquivo TEMPORÁRIO da captura, que o SO pode
  /// reciclar a qualquer momento) para um diretório PERMANENTE do app e
  /// enfileira o retry — chamado por [SosDisparoService] assim que o
  /// upload original falha. Nunca lança exceção (best-effort: se nem a
  /// cópia local funcionar, o pior caso é o mesmo de antes desta
  /// funcionalidade existir — sem retry, mas sem quebrar o fluxo de SOS).
  Future<void> enfileirar({
    required XFile fotoOriginal,
    required String origem,
    double? latitude,
    double? longitude,
    String? alertaId,
  }) async {
    try {
      final diretorioPermanente = await getApplicationDocumentsDirectory();
      final nomeArquivo = 'sos_retry_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final destino = path.join(diretorioPermanente.path, nomeArquivo);
      await File(fotoOriginal.path).copy(destino);

      await _db.enfileirarRetryUploadSos(
        fotoPath: destino,
        origem: origem,
        latitude: latitude,
        longitude: longitude,
        alertaId: alertaId,
      );
      debugPrint('💾 [RetryUploadService] Upload de foto SOS ($origem) enfileirado para retry: $destino');
    } catch (e) {
      debugPrint('⚠️ [RetryUploadService] Falha ao enfileirar retry (foto pode ter sido perdida): $e');
    }
  }

  /// Percorre a fila e tenta reenviar cada item pendente, um de cada vez
  /// (sequencial, de propósito — evita disparar N uploads simultâneos
  /// competindo por banda/CPU num aparelho que acabou de recuperar sinal
  /// fraco). Idempotente e seguro para chamar a qualquer momento — se a
  /// fila estiver vazia, é um no-op rápido.
  Future<void> tentarDrenarFilaAgora() async {
    List<Map<String, dynamic>> pendentes;
    try {
      pendentes = await _db.listarRetryUploadSosPendentes();
    } catch (e) {
      debugPrint('⚠️ [RetryUploadService] Falha ao ler fila de retry: $e');
      return;
    }

    if (pendentes.isEmpty) return;

    debugPrint('🔁 [RetryUploadService] ${pendentes.length} upload(s) de SOS pendente(s) — tentando reenviar...');

    for (final item in pendentes) {
      final int id = item['id'] as int;
      final String fotoPath = item['foto_path'] as String;
      final String origem = item['origem'] as String? ?? 'sos_retry';
      final int tentativasAnteriores = item['tentativas'] as int? ?? 0;

      try {
        if (!await File(fotoPath).exists()) {
          debugPrint('⚠️ [RetryUploadService] Item #$id — arquivo local não existe mais, removendo da fila.');
          await _db.removerRetryUploadSos(id);
          continue;
        }

        final bool sucesso = await SosDisparoService().tentarReenviarFotoEnfileirada(
          fotoPathLocal: fotoPath,
          origem: origem,
          alertaId: item['alerta_id'] as String?,
          latitude: (item['latitude'] as num?)?.toDouble(),
          longitude: (item['longitude'] as num?)?.toDouble(),
        );

        if (sucesso) {
          await _db.removerRetryUploadSos(id);
          try {
            await File(fotoPath).delete();
          } catch (_) {}
          debugPrint('✅ [RetryUploadService] Item #$id reenviado com sucesso — removido da fila.');
        } else if (tentativasAnteriores + 1 >= _maxTentativas) {
          debugPrint('🚫 [RetryUploadService] Item #$id atingiu o máximo de $_maxTentativas tentativas — desistindo.');
          await _db.removerRetryUploadSos(id);
        } else {
          await _db.incrementarTentativaRetryUploadSos(id);
        }
      } catch (e) {
        debugPrint('⚠️ [RetryUploadService] Falha inesperada ao processar item #$id: $e');
      }
    }
  }
}

/// Callback headless do alarme periódico de retry (ver [RetryUploadService.iniciar])
/// — roda num engine/isolate separado do processo principal, por isso
/// não pode depender de nenhum estado em memória: [RetryUploadService] é
/// stateless além do singleton em si, e [DatabaseHelper]/[SosDisparoService]
/// já são seguros para uso headless (mesmo padrão já usado pelos demais
/// callbacks nativos deste projeto, ver `rotina_alarme_service.dart`).
@pragma('vm:entry-point')
void _callbackRetryPeriodico() {
  RetryUploadService().tentarDrenarFilaAgora();
}
