import 'package:flutter/foundation.dart';

import 'database_helper.dart';
import 'notificacao_service.dart';

/// Status de entrega de um alerta a UM contato (detalhe do Histórico).
class StatusEntregaContato {
  StatusEntregaContato._();

  static const String entregue = 'entregue';
  static const String tentando = 'tentando';
  static const String naoEntregue = 'nao_entregue';
}

/// Avisos do servidor ao REMETENTE sobre a entrega do alerta a cada
/// contato ("{nome} ainda não recebeu seu alerta…", "{nome} recebeu seu
/// alerta.", "Não foi possível entregar…") — mesmo comportamento do Android.
///
/// Campos lidos do push:
/// - `tipo`: `aviso_entrega_alerta` (o que o servidor envia), ou
///   `aviso_entrega` / `entrega_alerta_tentando` / `entrega_alerta_entregue`
///   / `entrega_alerta_nao_entregue`;
/// - `statusEntrega`: `tentando` | `entregue` | `nao_entregue` — sem ele,
///   `situacao` (`pendente` = tentando, `entregue`, `nao_entregue`);
/// - `titulo`, `corpo`: o texto mostrado, como veio do servidor;
/// - `alertaId` (id do documento em `usuarios/{uid}/alertas`);
/// - contato: `nomeContato` (ou `nomeDestinatario`), e `contatoId` ou
///   `telefone` quando vierem.
///
/// Mostra uma notificação visível com `titulo`/`corpo` (quando o próprio iOS
/// ainda não exibiu o banner) e grava o status do contato na entrada do
/// alerta (pelo `alertaId`; sem ele, no alerta mais recente das últimas
/// 48 h).
class AvisoEntregaService {
  AvisoEntregaService._();

  static const Set<String> tipos = {
    'aviso_entrega_alerta',
    'aviso_entrega',
    'entrega_alerta_tentando',
    'entrega_alerta_entregue',
    'entrega_alerta_nao_entregue',
  };

  static String? statusDoPush(Map<String, dynamic> data) {
    String? normalizar(Object? valor) {
      switch ((valor as String?)?.trim().toLowerCase()) {
        case 'entregue':
          return StatusEntregaContato.entregue;
        case 'tentando':
        case 'pendente':
          return StatusEntregaContato.tentando;
        case 'nao_entregue':
          return StatusEntregaContato.naoEntregue;
      }
      return null;
    }

    final status = normalizar(data['statusEntrega']) ?? normalizar(data['situacao']);
    if (status != null) return status;
    switch (data['tipo']) {
      case 'entrega_alerta_entregue':
        return StatusEntregaContato.entregue;
      case 'entrega_alerta_tentando':
        return StatusEntregaContato.tentando;
      case 'entrega_alerta_nao_entregue':
        return StatusEntregaContato.naoEntregue;
    }
    return null;
  }

  /// Nome do contato: `nomeContato`, senão `nomeDestinatario`.
  static String nomeDoContato(Map<String, dynamic> data) {
    final nome = ((data['nomeContato'] as String?) ?? '').trim();
    return nome.isNotEmpty ? nome : ((data['nomeDestinatario'] as String?) ?? '').trim();
  }

  /// [exibirNotificacao] `false` quando o iOS já mostrou o banner do push.
  static Future<void> processar(Map<String, dynamic> data, {bool exibirNotificacao = true}) async {
    final titulo = ((data['titulo'] as String?) ?? '').trim();
    final corpo = ((data['corpo'] as String?) ?? '').trim();
    final nome = nomeDoContato(data);
    final contato = ((data['contatoId'] as String?) ?? (data['telefone'] as String?) ?? nome).trim();

    try {
      final db = DatabaseHelper();
      var alertaId = (data['alertaId'] as String?)?.trim();
      if (alertaId == null || alertaId.isEmpty) {
        alertaId = await db.alertaMaisRecenteEnviado(const Duration(hours: 48));
      }
      final status = statusDoPush(data);
      if (alertaId != null && contato.isNotEmpty && status != null) {
        await db.salvarEntregaContato(
          alertaId: alertaId,
          contato: contato,
          nome: nome,
          status: status,
          texto: corpo.isNotEmpty ? corpo : titulo,
        );
      }
    } catch (e) {
      debugPrint('⚠️ [AvisoEntrega] Falha ao gravar o status de entrega: $e');
    }

    if (!exibirNotificacao || (titulo.isEmpty && corpo.isEmpty)) return;
    try {
      await NotificacaoService.exibirAvisoDespertador(
        id: 71000 + ('${data['alertaId']}$contato'.hashCode.abs() % 900),
        titulo: titulo.isNotEmpty ? titulo : corpo,
        corpo: corpo.isNotEmpty ? corpo : titulo,
      );
    } catch (e) {
      debugPrint('⚠️ [AvisoEntrega] Falha ao exibir o aviso de entrega: $e');
    }
  }
}
