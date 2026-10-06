import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:uuid/uuid.dart';

import 'database_helper.dart';
import 'emergency_alert_service.dart';
import 'firebase_sync_service.dart';
import 'l10n_headless_service.dart';
import 'location_service.dart';
import 'protecao_arquivo_service.dart';

/// Tipos de entrada do histórico de alertas enviados (coluna `tipo`).
class TipoAlertaHistorico {
  TipoAlertaHistorico._();

  static const String sosManual = 'sos_manual';
  static const String sosWidget = 'sos_widget';
  static const String cronometroExpirado = 'cronometro_expirado';
  static const String tentativaDesarmeIncorreto = 'tentativa_desarme_incorreto';
  static const String cronometroAtivado = 'cronometro_ativado';
  static const String cronometroDesarmado = 'cronometro_desarmado';
  static const String despertadorConfirmado = 'despertador_confirmado';
  static const String despertadorExpirado = 'despertador_expirado';
  static const String despertadorPinIncorreto = 'despertador_pin_incorreto';
  static const String despertadorTentativaApagar = 'despertador_tentativa_apagar';
  static const String alertaServidor = 'alerta_servidor';

  /// Eventos que não são um alerta aos contatos (não têm status de envio).
  static const Set<String> semEnvio = {cronometroAtivado, cronometroDesarmado, despertadorConfirmado};
}

/// Status do envio de um alerta (coluna `status`).
class StatusAlertaHistorico {
  StatusAlertaHistorico._();

  static const String enviando = 'enviando';
  static const String enviado = 'enviado';
  static const String pendente = 'pendente';
  static const String falhou = 'falhou';
}

/// Histórico dos alertas enviados pelo próprio usuário: UMA entrada por
/// alerta na tabela `historico` (categoria 'critico', área protegida pelo
/// PIN), identificada pelo `alerta_id` — o mesmo id do documento em
/// `usuarios/{uid}/alertas`.
///
/// Ciclo de vida de um alerta:
///   - criado no toque com status "enviando" ([registrarAlerta]);
///   - "enviado" só quando o Firestore confirma; "pendente" quando o envio
///     ficou na fila por falta de conexão ([marcarStatus] — um alerta já
///     "enviado" nunca volta atrás);
///   - a foto entra na MESMA entrada quando o upload termina, inclusive pelo
///     RetryUploadService mais tarde ([anexarFoto]).
///
/// Na abertura do app com sessão, [importarDoFirestore] traz os alertas da
/// conta que não existem aqui (reinstalação, troca de aparelho, alertas
/// disparados pelo servidor com o app fechado) e confirma os que ficaram
/// "enviando"/"pendente" localmente mas já chegaram ao servidor.
class HistoricoAlertasService {
  HistoricoAlertasService._internal();
  static final HistoricoAlertasService _instance = HistoricoAlertasService._internal();
  factory HistoricoAlertasService() => _instance;

  static const String categoria = 'critico';
  static const String _pastaFotos = 'historico_fotos';

  final DatabaseHelper _db = DatabaseHelper();
  StreamSubscription<User?>? _assinaturaAuth;
  String? _uidImportado;

  String novoAlertaId() => const Uuid().v4().replaceAll('-', '');

  /// Liga a importação do Firestore a cada sessão que abrir.
  void iniciar() {
    if (_assinaturaAuth != null || Firebase.apps.isEmpty) return;
    _assinaturaAuth = FirebaseAuth.instance.authStateChanges().listen((usuario) {
      if (usuario == null) {
        _uidImportado = null;
        return;
      }
      if (_uidImportado == usuario.uid) return;
      _uidImportado = usuario.uid;
      unawaited(importarDoFirestore(usuario.uid));
    });
  }

  static String tituloDoTipo(AppLocalizations l10n, String? tipo) {
    switch (tipo) {
      case TipoAlertaHistorico.sosManual:
        return l10n.historicoTipoSosManual;
      case TipoAlertaHistorico.sosWidget:
        return l10n.historicoTipoSosWidget;
      case TipoAlertaHistorico.cronometroExpirado:
        return l10n.historicoTipoCronometroExpirado;
      case TipoAlertaHistorico.tentativaDesarmeIncorreto:
        return l10n.historicoTipoTentativaDesarme;
      case TipoAlertaHistorico.cronometroAtivado:
        return l10n.historicoTipoCronometroAtivado;
      case TipoAlertaHistorico.cronometroDesarmado:
        return l10n.historicoTipoCronometroDesarmado;
      case TipoAlertaHistorico.despertadorConfirmado:
        return l10n.historicoTipoDespertadorConfirmado;
      case TipoAlertaHistorico.despertadorExpirado:
        return l10n.historicoTipoDespertadorExpirado;
      case TipoAlertaHistorico.despertadorPinIncorreto:
        return l10n.historicoTipoDespertadorPinIncorreto;
      case TipoAlertaHistorico.despertadorTentativaApagar:
        return l10n.historicoTipoDespertadorTentativaApagar;
      default:
        return l10n.historicoTipoAlertaServidor;
    }
  }

  /// Cria a entrada do alerta [alertaId] (ou de um evento sem envio, como
  /// "cronômetro ativado"). [status] `null` = evento sem envio.
  Future<void> registrarAlerta({
    required String alertaId,
    required String tipo,
    String? status = StatusAlertaHistorico.enviando,
    double? latitude,
    double? longitude,
    double? precisao,
    String? contexto,
    DateTime? quando,
  }) async {
    try {
      final l10n = await L10nHeadlessService.obter();
      await _db.inserirAlertaHistorico({
        'alerta_id': alertaId,
        'tipo': tipo,
        'status': status,
        'titulo': tituloDoTipo(l10n, tipo),
        'descricao': contexto ?? '',
        'categoria': categoria,
        'timestamp': (quando ?? DateTime.now()).toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'precisao': precisao,
        'contexto': contexto,
      });
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha ao registrar o alerta $alertaId: $e');
    }
  }

  /// Evento sem envio (cronômetro ativado/desarmado, despertador
  /// confirmado), com a posição conhecida no momento.
  Future<void> registrarEvento({required String tipo, String? contexto, Position? posicao}) async {
    final pos = posicao ?? await posicaoConhecida();
    await registrarAlerta(
      alertaId: novoAlertaId(),
      tipo: tipo,
      status: null,
      latitude: pos?.latitude,
      longitude: pos?.longitude,
      precisao: pos?.accuracy,
      contexto: contexto,
    );
  }

  /// Alerta do cronômetro aos contatos ([tipo]: [TipoAlertaHistorico.cronometroExpirado]
  /// ou [TipoAlertaHistorico.tentativaDesarmeIncorreto]): entrada no
  /// Histórico com a posição do momento, documento na nuvem com o mesmo id
  /// (primeiro, como sempre) e o status real do envio; depois o SMS (só
  /// Android). [eventoId] reaproveita um id já reservado pelo chamador.
  Future<void> dispararAlertaCronometro({
    required String tipo,
    String? motivo,
    Position? posicao,
    String? eventoId,
  }) async {
    final alertaId = eventoId ?? novoAlertaId();
    final pos = posicao ?? await posicaoConhecida();
    await registrarAlerta(
      alertaId: alertaId,
      tipo: tipo,
      latitude: pos?.latitude,
      longitude: pos?.longitude,
      precisao: pos?.accuracy,
      contexto: motivo,
    );
    try {
      final status = await FirebaseSyncService().enviarAlertaCronometro(
        alertaId: alertaId,
        subtipo: tipo,
        motivo: motivo,
        latitude: pos?.latitude,
        longitude: pos?.longitude,
        precisao: pos?.accuracy,
      );
      await marcarStatus(alertaId, status);
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha no alerta do cronômetro: $e');
      await marcarStatus(alertaId, StatusAlertaHistorico.falhou);
    }
    try {
      await EmergencyAlertService().dispararAlertaTentativaDesarmeIncorreto(
        motivo: motivo,
        posicaoEmMemoria: pos,
        registrarHistorico: false,
      );
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha no SMS do alerta do cronômetro: $e');
    }
  }

  /// Posição já conhecida, sem esperar o GPS: a do ciclo do cronômetro ou a
  /// última do sistema.
  Future<Position?> posicaoConhecida() async {
    final emMemoria = LocationService().ultimaPosicao;
    if (emMemoria != null) return emMemoria;
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  /// Muda o status do alerta. Um alerta "enviado" nunca volta para
  /// "enviando"/"pendente"/"falhou".
  Future<void> marcarStatus(String alertaId, String status) async {
    try {
      final atual = await _db.buscarAlertaHistorico(alertaId);
      if (atual == null) return;
      if (atual['status'] == StatusAlertaHistorico.enviado) return;
      await _db.atualizarAlertaHistorico(alertaId, {'status': status});
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha ao atualizar o status de $alertaId: $e');
    }
  }

  Future<void> atualizarPosicao(String alertaId, Position posicao) async {
    try {
      await _db.atualizarAlertaHistorico(alertaId, {
        'latitude': posicao.latitude,
        'longitude': posicao.longitude,
        'precisao': posicao.accuracy,
      });
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha ao atualizar a posição de $alertaId: $e');
    }
  }

  Future<void> anexarFoto(String alertaId, {String? fotoUrl, String? fotoLocal}) async {
    final campos = <String, dynamic>{
      if (fotoUrl != null) 'foto_url': fotoUrl,
      if (fotoLocal != null) 'foto_local': fotoLocal,
    };
    if (campos.isEmpty) return;
    try {
      await _db.atualizarAlertaHistorico(alertaId, campos);
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha ao anexar a foto a $alertaId: $e');
    }
  }

  /// Cópia da foto do SOS na pasta privada do app (Documents, com proteção
  /// de arquivo completa — nunca na galeria), para o Histórico. Devolve o
  /// caminho, ou `null` se a cópia falhar.
  Future<String?> guardarCopiaLocalFoto(String caminhoOrigem, String alertaId) async {
    try {
      final documentos = await getApplicationDocumentsDirectory();
      final pasta = Directory(p.join(documentos.path, _pastaFotos));
      if (!await pasta.exists()) await pasta.create(recursive: true);
      final destino = p.join(pasta.path, '$alertaId.jpg');
      await File(caminhoOrigem).copy(destino);
      await ProtecaoArquivoService().proteger([pasta.path, destino]);
      await anexarFoto(alertaId, fotoLocal: destino);
      return destino;
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Falha ao guardar a cópia local da foto: $e');
      return null;
    }
  }

  /// Apaga a cópia local da foto de uma entrada que está sendo removida.
  Future<void> apagarFotoLocal(String? caminho) async {
    if (caminho == null || caminho.isEmpty) return;
    try {
      final arquivo = File(caminho);
      if (await arquivo.exists()) await arquivo.delete();
    } catch (_) {}
  }

  /// Traz para o SQLite os alertas da conta que ainda não existem aqui
  /// (pelo `alerta_id`) e confirma os que ficaram "enviando"/"pendente":
  ///   - `usuarios/{uid}/alertas` (gravados pelo próprio app);
  ///   - `usuarios/{uid}/historico_alertas` (registro gravado pelo servidor
  ///     para os alertas que ele dispara — cronômetro e despertador com o
  ///     app fechado).
  /// A foto (`sos_fisico_foto`) entra na entrada do alerta pelo `alertaId`;
  /// fotos antigas sem `alertaId` vão para o SOS mais próximo antes delas.
  Future<void> importarDoFirestore(String uid) async {
    final usuario = FirebaseFirestore.instance.collection('usuarios').doc(uid);
    try {
      final existentes = await _db.statusDosAlertasHistorico();
      final snapshot = await usuario
          .collection('alertas')
          .orderBy('criadoEm', descending: true)
          .limit(300)
          .get()
          .timeout(const Duration(seconds: 20));

      final fotos = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      final sosPorHorario = <MapEntry<DateTime, String>>[];
      for (final doc in snapshot.docs) {
        final dados = doc.data();
        final tipoFirestore = dados['tipo'] as String?;
        final criadoEm = (dados['criadoEm'] as Timestamp?)?.toDate();
        if (tipoFirestore == 'sos_fisico_foto') {
          fotos.add(doc);
          continue;
        }
        final tipo = _tipoLocal(tipoFirestore, dados);
        if (tipo == null) continue;
        if (tipoFirestore == 'sos_fisico' && criadoEm != null) {
          sosPorHorario.add(MapEntry(criadoEm, doc.id));
        }
        await _importarOuConfirmar(existentes, doc.id, tipo, dados, criadoEm);
      }

      for (final foto in fotos) {
        final dados = foto.data();
        final url = dados['fotoUrl'] as String?;
        if (url == null) continue;
        var alvo = dados['alertaId'] as String?;
        if (alvo == null) {
          final quando = (dados['criadoEm'] as Timestamp?)?.toDate();
          if (quando == null) continue;
          MapEntry<DateTime, String>? maisProximo;
          for (final sos in sosPorHorario) {
            final diferenca = quando.difference(sos.key);
            if (diferenca.isNegative || diferenca > const Duration(minutes: 10)) continue;
            if (maisProximo == null || sos.key.isAfter(maisProximo.key)) maisProximo = sos;
          }
          alvo = maisProximo?.value;
        }
        if (alvo == null) continue;
        final atual = await _db.buscarAlertaHistorico(alvo);
        if (atual != null && (atual['foto_url'] as String?) == null) {
          await anexarFoto(alvo, fotoUrl: url);
        }
      }
    } catch (e) {
      debugPrint('⚠️ [HistoricoAlertas] Importação de usuarios/$uid/alertas não concluída: $e');
    }

    try {
      final existentes = await _db.statusDosAlertasHistorico();
      final snapshot = await usuario
          .collection('historico_alertas')
          .limit(300)
          .get()
          .timeout(const Duration(seconds: 20));
      for (final doc in snapshot.docs) {
        final dados = doc.data();
        final alertaId = (dados['alertaId'] as String?) ?? doc.id;
        final criadoEm = _data(dados['criadoEm']) ?? _data(dados['disparadoEm']);
        final tipo = _tipoLocal(dados['tipo'] as String?, dados) ?? TipoAlertaHistorico.alertaServidor;
        await _importarOuConfirmar(existentes, alertaId, tipo, dados, criadoEm);
        final url = dados['fotoUrl'] as String?;
        if (url != null) {
          final atual = await _db.buscarAlertaHistorico(alertaId);
          if (atual != null && atual['foto_url'] == null) await anexarFoto(alertaId, fotoUrl: url);
        }
      }
    } catch (e) {
      // Sem a coleção (ou sem permissão de leitura) ainda: nada a importar.
      debugPrint('ℹ️ [HistoricoAlertas] historico_alertas do servidor indisponível: $e');
    }
  }

  Future<void> _importarOuConfirmar(
    Map<String, String?> existentes,
    String alertaId,
    String tipo,
    Map<String, dynamic> dados,
    DateTime? criadoEm,
  ) async {
    if (existentes.containsKey(alertaId)) {
      final status = existentes[alertaId];
      if (status == StatusAlertaHistorico.enviando || status == StatusAlertaHistorico.pendente) {
        await marcarStatus(alertaId, StatusAlertaHistorico.enviado);
      }
      return;
    }
    final ultima = dados['ultimaLocalizacao'];
    double? numero(Object? v) => v is num ? v.toDouble() : null;
    await registrarAlerta(
      alertaId: alertaId,
      tipo: tipo,
      status: TipoAlertaHistorico.semEnvio.contains(tipo) ? null : StatusAlertaHistorico.enviado,
      latitude: numero(dados['latitude']) ?? (ultima is Map ? numero(ultima['lat']) : null),
      longitude: numero(dados['longitude']) ?? (ultima is Map ? numero(ultima['lng']) : null),
      precisao: numero(dados['precisao']),
      contexto: (dados['contexto'] as String?) ?? (dados['motivo'] as String?),
      quando: criadoEm,
    );
    existentes[alertaId] = StatusAlertaHistorico.enviado;
  }

  static DateTime? _data(Object? valor) {
    if (valor is Timestamp) return valor.toDate();
    if (valor is int) return DateTime.fromMillisecondsSinceEpoch(valor);
    if (valor is String) return DateTime.tryParse(valor);
    return null;
  }

  /// Tipo local de um documento do Firestore; `null` = não é um alerta do
  /// histórico.
  static String? _tipoLocal(String? tipoFirestore, Map<String, dynamic> dados) {
    final subtipo = dados['subtipo'] as String?;
    if (subtipo != null && subtipo.isNotEmpty) return subtipo;
    switch (tipoFirestore) {
      case 'sos_fisico':
        final origem = (dados['origem'] as String?) ?? '';
        return origem.contains('widget') ? TipoAlertaHistorico.sosWidget : TipoAlertaHistorico.sosManual;
      case 'tentativa_desarme_incorreto':
        return TipoAlertaHistorico.tentativaDesarmeIncorreto;
      case TipoAlertaHistorico.sosManual:
      case TipoAlertaHistorico.sosWidget:
      case TipoAlertaHistorico.cronometroExpirado:
      case TipoAlertaHistorico.cronometroAtivado:
      case TipoAlertaHistorico.cronometroDesarmado:
      case TipoAlertaHistorico.despertadorConfirmado:
      case TipoAlertaHistorico.despertadorExpirado:
      case TipoAlertaHistorico.despertadorPinIncorreto:
      case TipoAlertaHistorico.despertadorTentativaApagar:
        return tipoFirestore;
      default:
        return null;
    }
  }
}
