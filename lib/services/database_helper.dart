import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import 'pin_hash.dart';
import 'protecao_arquivo_service.dart';


class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;

  /// Notificador global (contador incremental) disparado toda vez que um
  /// novo evento é gravado no histórico local (ver [inserirEventoHistorico]).
  /// Telas que exibem o histórico (ex: `HistoricoTab`) escutam este
  /// notificador para recarregar a lista IMEDIATAMENTE quando um evento é
  /// gravado com o app já em primeiro plano — sem depender de app
  /// minimizado/reaberto (`AppLifecycleState.resumed`), que só cobre o
  /// caso de o alerta ter disparado através de uma Activity nativa
  /// separada por cima da MainActivity (ver `cronometro_disparado_screen.dart`),
  /// nunca o caso de uma tentativa MANUAL de desarme resolvida sem sair
  /// da própria `SegurancaTab` (ver `seguranca_tab.dart`).
  static final ValueNotifier<int> historicoAtualizadoNotifier =
      ValueNotifier<int>(0);

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'security_check.db');

    final db = await openDatabase(
      path,
      version: 21,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    // iOS: o banco (PIN, histórico de alertas com localização e foto) fica
    // cifrado até o primeiro desbloqueio depois de ligar o aparelho
    // (completeUntilFirstUserAuthentication) — o app grava com a tela
    // bloqueada (alertas recebidos, status de entrega, alertas enviados).
    if (Platform.isIOS) {
      await ProtecaoArquivoService().proteger([
        path,
        '$path-journal',
        '$path-wal',
        '$path-shm',
      ]);
    }
    return db;
  }



  Future<void> _onCreate(Database db, int version) async {
    // Table: user_config
    await db.execute('''
      CREATE TABLE user_config (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        pin_real TEXT,
        tempo_padrao_timer INTEGER,
        enviar_whatsapp_simultaneo INTEGER NOT NULL DEFAULT 0,
        tipo_plano TEXT NOT NULL DEFAULT 'free',
        plano_de_fundo_url TEXT,
        senha_pendente TEXT,
        timestamp_alteracao_senha TEXT,
        timestamp_solicitacao_auditoria TEXT,
        auditoria_liberada_sessao INTEGER NOT NULL DEFAULT 0,
        aguardando_confirmacao_pin INTEGER NOT NULL DEFAULT 0,
        contexto_timer_ativo TEXT,
        timestamp_expiracao_alarme TEXT,
        som_alarme_selecionado INTEGER NOT NULL DEFAULT 1,
        duracao_som_alarme INTEGER NOT NULL DEFAULT 30,
        idioma_selecionado TEXT NOT NULL DEFAULT 'pt',
        telefone TEXT
      )
    ''');


    // Table: contacts (up to 3 contacts) - legado, mantido por compatibilidade
    await db.execute('''
      CREATE TABLE contacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nome TEXT NOT NULL,
        telefone_whatsapp TEXT NOT NULL,
        limite_mensal_alertas INTEGER NOT NULL DEFAULT 10
      )
    ''');

    // Table: contatos_emergencia - tabela isolada e dedicada exclusivamente
    // aos contatos de emergência da aba Família (até 3 contatos), com
    // integração via Agenda do celular (flutter_contacts).
    // Colunas exclusao_pendente/timestamp_solicitacao implementam a trava
    // de segurança de 2h antes da remoção definitiva de um contato.
    await db.execute('''
      CREATE TABLE contatos_emergencia (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nome TEXT NOT NULL,
        telefone TEXT NOT NULL,
        exclusao_pendente INTEGER NOT NULL DEFAULT 0,
        timestamp_solicitacao TEXT,
        whatsapp_habilitado INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Table: historico - registra eventos administrativos do aplicativo
    // nas categorias 'seguranca', 'familia' e 'sistema', exibidos
    // normalmente na aba Histórico.
    await db.execute('''
      CREATE TABLE historico (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        titulo TEXT NOT NULL,
        descricao TEXT NOT NULL,
        categoria TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        alerta_id TEXT,
        tipo TEXT,
        status TEXT,
        latitude REAL,
        longitude REAL,
        precisao REAL,
        foto_url TEXT,
        foto_local TEXT,
        contexto TEXT
      )
    ''');
    await db.execute(
        'CREATE UNIQUE INDEX IF NOT EXISTS idx_historico_alerta_id ON historico(alerta_id)');

    // Table: alarmes_rotina - gerenciador de múltiplos alarmes de rotina
    // (estilo despertador do iPhone), usado pela aba Família. Cada
    // alarme possui hora/minuto, dias da semana de repetição (armazenados
    // como string CSV, ex: "1,3,5" para Seg/Qua/Sex, onde 1=Segunda até
    // 7=Domingo), estado ativo/inativo e uma etiqueta/nome livre.
    await db.execute('''
      CREATE TABLE alarmes_rotina (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        hora INTEGER NOT NULL,
        minuto INTEGER NOT NULL,
        dias_semana TEXT NOT NULL,
        ativo INTEGER NOT NULL DEFAULT 1,
        etiqueta TEXT,
        contexto_personalizado TEXT,
        minutos_tolerancia INTEGER NOT NULL DEFAULT 10,
        ultimo_disparo_epoch INTEGER,
        alarme_pausado INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Table: monitoramento_contatos - lista de contatos da aba
    // Monitoramento, TOTALMENTE INDEPENDENTE de 'contatos_emergencia'
    // (que continua exclusiva do alarme/pânico). Cada linha representa um
    // familiar com quem o usuário pode trocar permissão de localização
    // GPS em tempo real, nas DUAS direções possíveis, cada uma com seu
    // próprio ciclo de aprovação via `permissoes_monitoramento` no
    // Firestore (ver MonitoramentoService):
    // - status_ver_localizacao: estado da MINHA solicitação para ver a
    //   localização DELE ('nao_solicitado', 'pendente', 'aprovado',
    //   'negado', 'expirado').
    // - status_compartilhamento: estado do compartilhamento da MINHA
    //   localização COM ELE ('inexistente', 'pendente', 'aprovado',
    //   'bloqueado') — só deixa de ser 'inexistente' quando ELE solicitou
    //   minha localização ao menos uma vez.
    // uid_contato fica NULL até a primeira resolução por telefone (ver
    // Cloud Function callable 'solicitarMonitoramento').
    await db.execute('''
      CREATE TABLE monitoramento_contatos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nome TEXT NOT NULL,
        telefone TEXT NOT NULL,
        uid_contato TEXT,
        status_ver_localizacao TEXT NOT NULL DEFAULT 'nao_solicitado',
        status_compartilhamento TEXT NOT NULL DEFAULT 'inexistente',
        criado_em INTEGER NOT NULL
      )
    ''');

    // Table: alertas_terceiros_recebidos - alertas de emergência de
    // OUTROS usuários recebidos via Push FCM (ver FcmService/
    // NotificacaoService), persistidos localmente para: (1) permitir um
    // indicador de "não visualizado" no HomeScreen e (2) aparecerem como
    // itens clicáveis na aba Histórico, roteando para o mapa (alertas de
    // localização) ou para a tela de foto (alertas com foto_url).
    // id_entrega é UNIQUE para nunca duplicar caso o FCM reentregue a
    // mesma mensagem.
    await db.execute('''
      CREATE TABLE alertas_terceiros_recebidos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        id_entrega TEXT UNIQUE,
        nome_remetente TEXT,
        mensagem TEXT NOT NULL,
        latitude REAL,
        longitude REAL,
        foto_url TEXT,
        recebido_em TEXT NOT NULL,
        visualizado INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Table: fila_retry_upload_sos - fila de resiliência offline (ver
    // RetryUploadService): quando o upload da foto do SOS ao Firebase
    // Storage falha (sem internet/Wi-Fi/4G no momento do disparo), o SMS
    // com o link já foi enviado com fallback via GSM normalmente, mas o
    // PAYLOAD do upload (caminho local da foto já copiada para um
    // diretório permanente do app + metadados) fica registrado aqui para
    // ser reenviado automaticamente assim que a conectividade voltar,
    // sem exigir nenhuma ação do usuário.
    await db.execute('''
      CREATE TABLE fila_retry_upload_sos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        foto_path TEXT NOT NULL,
        origem TEXT NOT NULL,
        latitude REAL,
        longitude REAL,
        criado_em TEXT NOT NULL,
        tentativas INTEGER NOT NULL DEFAULT 0,
        alerta_id TEXT
      )
    ''');
    await db.execute(_sqlTabelaEntregas);
  }

  /// Status de entrega de cada alerta a cada contato (avisos do servidor
  /// ao remetente — ver AvisoEntregaService). Mesma tabela do Android.
  static const String _sqlTabelaEntregas = '''
      CREATE TABLE IF NOT EXISTS entregas_alerta_contato (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        alerta_id TEXT NOT NULL,
        contato TEXT NOT NULL,
        nome TEXT,
        status TEXT NOT NULL,
        texto TEXT,
        atualizado_em TEXT NOT NULL,
        UNIQUE(alerta_id, contato)
      )
    ''';




  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Migration from v1 to v2: add plano_de_fundo_url
    if (oldVersion < 2) {
      // Add plano_de_fundo_url to user_config
      await db.execute('ALTER TABLE user_config ADD COLUMN plano_de_fundo_url TEXT');
    }
    // Migration from v2 to v3: add senha_pendente e timestamp_alteracao_senha
    // (regra de segurança de 2h para troca de senha)
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE user_config ADD COLUMN senha_pendente TEXT');
      await db.execute('ALTER TABLE user_config ADD COLUMN timestamp_alteracao_senha TEXT');
    }
    // Migration from v3 to v4: cria a tabela isolada 'contatos_emergencia',
    // usada pela aba Família para até 3 contatos vindos da Agenda do celular.
    if (oldVersion < 4) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS contatos_emergencia (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          nome TEXT NOT NULL,
          telefone TEXT NOT NULL
        )
      ''');
    }
    // Migration from v4 to v5: adiciona a trava de segurança de 2h para
    // exclusão de contatos de emergência (exclusao_pendente/timestamp_solicitacao).
    if (oldVersion < 5) {
      await db.execute(
        "ALTER TABLE contatos_emergencia ADD COLUMN exclusao_pendente INTEGER NOT NULL DEFAULT 0",
      );
      await db.execute(
        'ALTER TABLE contatos_emergencia ADD COLUMN timestamp_solicitacao TEXT',
      );
    }
    // Migration from v5 to v6: cria a tabela 'historico', usada para
    // registrar os eventos administrativos do aplicativo, exibidos na
    // aba Histórico.
    if (oldVersion < 6) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS historico (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          titulo TEXT NOT NULL,
          descricao TEXT NOT NULL,
          categoria TEXT NOT NULL,
          timestamp TEXT NOT NULL
        )
      ''');
    }
    // Migration from v6 to v7: adiciona os campos de controle da trava de
    // segurança temporal (3h) para liberação da Auditoria de Eventos
    // Sensíveis (registros mais críticos da categoria 'seguranca').
    // - timestamp_solicitacao_auditoria: marca quando o usuário solicitou
    //   a liberação, usado para calcular as 3h de carência.
    // - auditoria_liberada_sessao: flag zerada a cada cold start do app
    //   (ver main.dart), garantindo que a visualização liberada nunca
    //   sobreviva a um fechamento/reabertura completa do aplicativo.
    if (oldVersion < 7) {
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN timestamp_solicitacao_auditoria TEXT',
      );
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN auditoria_liberada_sessao INTEGER NOT NULL DEFAULT 0',
      );
    }
    // Migration from v7 to v8: cria a tabela 'alarmes_rotina', usada pelo
    // novo gerenciador de múltiplos alarmes de rotina da aba Família
    // (estilo despertador do iPhone).
    if (oldVersion < 8) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS alarmes_rotina (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          hora INTEGER NOT NULL,
          minuto INTEGER NOT NULL,
          dias_semana TEXT NOT NULL,
          ativo INTEGER NOT NULL DEFAULT 1,
          etiqueta TEXT
        )
      ''');
    }
    // Migration from v8 to v9: adiciona os campos de controle do disparo
    // de emergência via alarme NATIVO (android_alarm_manager_plus), que
    // roda de forma confiável mesmo com o app fechado/em background:
    // - aguardando_confirmacao_pin: flag persistida indicando que um
    //   disparo de emergência já ocorreu (SMS já enviado pelo callback
    //   headless) e o app deve exibir a tela de bloqueio de PIN assim
    //   que for reaberto (cold start), até que o PIN correto seja
    //   digitado.
    // - contexto_timer_ativo: espelha em disco o texto digitado pelo
    //   usuário no campo "Dica de Contexto" no exato momento em que o
    //   cronômetro de check-in é iniciado, permitindo que o callback
    //   headless (que não tem acesso à UI/memória do app) monte a mesma
    //   mensagem de SMS de emergência.
    // - timestamp_expiracao_alarme: guarda o instante (epoch ms) em que
    //   o alarme nativo está agendado para disparar, usado apenas para
    //   fins de auditoria/depuração.
    if (oldVersion < 9) {
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN aguardando_confirmacao_pin INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN contexto_timer_ativo TEXT',
      );
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN timestamp_expiracao_alarme TEXT',
      );
    }
    // Migration from v9 to v10: adiciona os campos necessários para a
    // Etapa 3 (Alarmes de Rotina Múltiplos e Recorrentes) na tabela
    // 'alarmes_rotina':
    // - contexto_personalizado: dica de contexto PRÓPRIA de cada alarme
    //   de rotina (independente do campo de contexto do check-in manual
    //   em SegurancaTab), usada para montar a mensagem de SMS de
    //   emergência caso o check-in de rotina não seja confirmado a tempo.
    // - minutos_tolerancia: quantos minutos o usuário tem, após a
    //   notificação de check-in de rotina ser exibida, para confirmar
    //   "Cheguei bem" antes do disparo automático de emergência.
    // - ultimo_disparo_epoch: timestamp (epoch ms) do último disparo
    //   NATIVO já processado para este alarme, usado internamente pelo
    //   RotinaAlarmeService para fins de auditoria/depuração.
    if (oldVersion < 10) {
      await db.execute(
        'ALTER TABLE alarmes_rotina ADD COLUMN contexto_personalizado TEXT',
      );
      await db.execute(
        'ALTER TABLE alarmes_rotina ADD COLUMN minutos_tolerancia INTEGER NOT NULL DEFAULT 10',
      );
      await db.execute(
        'ALTER TABLE alarmes_rotina ADD COLUMN ultimo_disparo_epoch INTEGER',
      );
    }
    // Migration from v10 to v11: adiciona os campos de controle do
    // Alerta Sonoro Customizável (Etapa 1 da Expansão Global) e do
    // idioma preferido do usuário (Etapa 2 - Internacionalização):
    // - som_alarme_selecionado: número (1 a 10) do som escolhido pelo
    //   usuário para tocar em loop quando o cronômetro de check-in
    //   chegar a zero.
    // - duracao_som_alarme: duração (em segundos) configurada para o
    //   toque do alerta sonoro.
    // - idioma_selecionado: código do idioma da UI (ver
    //   lib/services/localization_service.dart), suportando os 11
    //   idiomas globais mapeados na Etapa 2.
    if (oldVersion < 11) {
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN som_alarme_selecionado INTEGER NOT NULL DEFAULT 1',
      );
      await db.execute(
        'ALTER TABLE user_config ADD COLUMN duracao_som_alarme INTEGER NOT NULL DEFAULT 30',
      );
      await db.execute(
        "ALTER TABLE user_config ADD COLUMN idioma_selecionado TEXT NOT NULL DEFAULT 'pt'",
      );
    }
    // Migration from v11 to v12: adiciona o campo 'alarme_pausado' na
    // tabela 'alarmes_rotina', usado pelo botão "Pausar Alarme" exibido
    // na tela nativa de confirmação de check-in de rotina
    // (RotinaCheckinAlarmActivity/pin_dialog.dart). Quando pausado
    // (1), o alarme de rotina permanece cadastrado (não é excluído),
    // porém o callback headless de disparo (_callbackCheckinRotina)
    // ignora o próximo disparo, e a aba Família exibe "Alarme Pausado"
    // no lugar do horário normal.
    if (oldVersion < 12) {
      await db.execute(
        'ALTER TABLE alarmes_rotina ADD COLUMN alarme_pausado INTEGER NOT NULL DEFAULT 0',
      );
    }
    // Migration from v12 to v13: correção defensiva para instalações cujo
    // banco foi criado diretamente na versão 12 por uma versão anterior de
    // _onCreate que esquecia de incluir colunas já adicionadas pelas
    // migrações v9/v10/v12 acima (aguardando_confirmacao_pin,
    // contexto_timer_ativo, timestamp_expiracao_alarme, em user_config; e
    // contexto_personalizado, minutos_tolerancia, ultimo_disparo_epoch,
    // alarme_pausado, em alarmes_rotina) — causando erros
    // "no such column" ao salvar alarmes de rotina ou o check-in de
    // segurança. Cada ALTER TABLE é protegida por try/catch para ignorar
    // "duplicate column" em quem já passou pelas migrações antigas
    // normalmente e já possui essas colunas.
    if (oldVersion < 13) {
      Future<void> adicionarColunaSeAusente(String sql) async {
        try {
          await db.execute(sql);
        } catch (_) {
          // Coluna já existe — ignora.
        }
      }

      await adicionarColunaSeAusente(
        'ALTER TABLE user_config ADD COLUMN aguardando_confirmacao_pin INTEGER NOT NULL DEFAULT 0',
      );
      await adicionarColunaSeAusente(
        'ALTER TABLE user_config ADD COLUMN contexto_timer_ativo TEXT',
      );
      await adicionarColunaSeAusente(
        'ALTER TABLE user_config ADD COLUMN timestamp_expiracao_alarme TEXT',
      );
      await adicionarColunaSeAusente(
        'ALTER TABLE alarmes_rotina ADD COLUMN contexto_personalizado TEXT',
      );
      await adicionarColunaSeAusente(
        'ALTER TABLE alarmes_rotina ADD COLUMN minutos_tolerancia INTEGER NOT NULL DEFAULT 10',
      );
      await adicionarColunaSeAusente(
        'ALTER TABLE alarmes_rotina ADD COLUMN ultimo_disparo_epoch INTEGER',
      );
      await adicionarColunaSeAusente(
        'ALTER TABLE alarmes_rotina ADD COLUMN alarme_pausado INTEGER NOT NULL DEFAULT 0',
      );
    }
    // Migration from v13 to v14: adiciona 'whatsapp_habilitado' na tabela
    // 'contatos_emergencia' — chave por contato ("Notificar via WhatsApp
    // ($0.10 USD)", ver ConfiguracoesTab) da arquitetura híbrida de
    // alertas: só contatos com esta flag ligada podem gerar cobrança de
    // WhatsApp de contingência.
    // COLUNA MORTA DESDE 2026-08-11: removida toda a integração de
    // WhatsApp/Twilio (a pedido do usuário) — 'whatsapp_habilitado'
    // permanece fisicamente na tabela (mesma convenção das demais
    // migrações deste arquivo, nunca DROP/RENAME COLUMN), mas não é mais
    // lida nem gravada pelo app.
    if (oldVersion < 14) {
      try {
        await db.execute(
          'ALTER TABLE contatos_emergencia ADD COLUMN whatsapp_habilitado INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {
        // Coluna já existe — ignora.
      }
    }
    // Migration from v14 to v15: cria a tabela 'monitoramento_contatos',
    // usada pela nova aba Monitoramento — lista de contatos TOTALMENTE
    // INDEPENDENTE de 'contatos_emergencia', com permissão bilateral de
    // compartilhamento de localização GPS em tempo real via Firestore
    // (coleção `permissoes_monitoramento`, ver MonitoramentoService).
    if (oldVersion < 15) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS monitoramento_contatos (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          nome TEXT NOT NULL,
          telefone TEXT NOT NULL,
          uid_contato TEXT,
          status_ver_localizacao TEXT NOT NULL DEFAULT 'nao_solicitado',
          status_compartilhamento TEXT NOT NULL DEFAULT 'inexistente',
          criado_em INTEGER NOT NULL
        )
      ''');
    }
    // Migration from v15 to v16: substitui o campo morto 'forcando_whatsapp'
    // (nunca lido por nenhuma lógica de envio — resquício de uma versão
    // anterior à arquitetura híbrida de alertas) pela chave GLOBAL real
    // "Enviar também via WhatsApp" (ver [UserConfig]/ConfiguracoesTab). A
    // coluna antiga 'forcando_whatsapp' permanece fisicamente na tabela —
    // mesma convenção das demais migrações deste arquivo, que nunca fazem
    // DROP/RENAME COLUMN por segurança de compatibilidade entre versões
    // do SQLite nos aparelhos.
    // COLUNA TAMBÉM MORTA DESDE 2026-08-11: removida toda a integração de
    // WhatsApp/Twilio (a pedido do usuário) — 'enviar_whatsapp_simultaneo'
    // segue a mesma convenção acima (permanece na tabela, não é mais
    // lida nem gravada pelo app).
    if (oldVersion < 16) {
      try {
        await db.execute(
          'ALTER TABLE user_config ADD COLUMN enviar_whatsapp_simultaneo INTEGER NOT NULL DEFAULT 0',
        );
      } catch (_) {
        // Coluna já existe — ignora.
      }
    }
    // Migration from v16 to v17: cria a tabela 'alertas_terceiros_recebidos'
    // — alertas de emergência de outros usuários recebidos via Push FCM,
    // persistidos localmente para o indicador de "não visualizado" no
    // HomeScreen e para aparecerem como itens clicáveis na aba Histórico
    // (ver NotificacaoService/FcmService/AlertasRecebidosService).
    if (oldVersion < 17) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS alertas_terceiros_recebidos (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          id_entrega TEXT UNIQUE,
          nome_remetente TEXT,
          mensagem TEXT NOT NULL,
          latitude REAL,
          longitude REAL,
          foto_url TEXT,
          recebido_em TEXT NOT NULL,
          visualizado INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    // Migration from v17 to v18: cria a tabela 'fila_retry_upload_sos' —
    // fila de resiliência offline para reenviar o upload da foto do SOS
    // à nuvem quando a chamada de rede falhar no momento do disparo (ver
    // RetryUploadService/SosDisparoService).
    if (oldVersion < 18) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS fila_retry_upload_sos (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          foto_path TEXT NOT NULL,
          origem TEXT NOT NULL,
          latitude REAL,
          longitude REAL,
          criado_em TEXT NOT NULL,
          tentativas INTEGER NOT NULL DEFAULT 0
        )
      ''');
    }
    // Migration from v18 to v19: cria a coluna 'telefone' em 'user_config'
    // — cache local do número de contato (ver
    // `FirebaseSyncService.salvarTelefonePerfil`), usado como fallback de
    // exibição em "Meu Perfil" quando o Firestore (fonte de verdade) não
    // estiver acessível no momento (sem internet).
    if (oldVersion < 19) {
      try {
        await db.execute('ALTER TABLE user_config ADD COLUMN telefone TEXT');
      } catch (_) {
        // Coluna já existe — ignora.
      }
    }
    // Migration from v19 to v20: histórico estruturado dos alertas
    // enviados (uma entrada por alerta, identificada por `alerta_id`, com
    // status do envio, localização e foto — ver HistoricoAlertasService),
    // `alerta_id` na fila de retry da foto e o PIN guardado como hash com
    // sal (ver PinHash) em vez de texto puro.
    if (oldVersion < 20) {
      const colunasHistorico = {
        'alerta_id': 'TEXT',
        'tipo': 'TEXT',
        'status': 'TEXT',
        'latitude': 'REAL',
        'longitude': 'REAL',
        'precisao': 'REAL',
        'foto_url': 'TEXT',
        'foto_local': 'TEXT',
        'contexto': 'TEXT',
      };
      for (final coluna in colunasHistorico.entries) {
        try {
          await db.execute('ALTER TABLE historico ADD COLUMN ${coluna.key} ${coluna.value}');
        } catch (_) {
          // Coluna já existe — ignora.
        }
      }
      await db.execute(
          'CREATE UNIQUE INDEX IF NOT EXISTS idx_historico_alerta_id ON historico(alerta_id)');
      try {
        await db.execute('ALTER TABLE fila_retry_upload_sos ADD COLUMN alerta_id TEXT');
      } catch (_) {}

      final configs = await db.query('user_config', columns: ['id', 'pin_real', 'senha_pendente']);
      for (final config in configs) {
        await db.update(
          'user_config',
          {
            'pin_real': PinHash.migrar(config['pin_real'] as String?),
            'senha_pendente': PinHash.migrar(config['senha_pendente'] as String?),
          },
          where: 'id = ?',
          whereArgs: [config['id']],
        );
      }
    }
    // Migration from v20 to v21: status de entrega por contato.
    if (oldVersion < 21) {
      await db.execute(_sqlTabelaEntregas);
    }
  }








  // ====================
  // USER CONFIG METHODS
  // ====================

  Future<int> insertUserConfig(Map<String, dynamic> config) async {
    final db = await database;
    return await db.insert('user_config', config);
  }

  Future<Map<String, dynamic>?> getUserConfig() async {
    final db = await database;
    final result = await db.query('user_config', limit: 1);
    return result.isNotEmpty ? result.first : null;
  }

  Future<int> updateUserConfig(Map<String, dynamic> config) async {
    final db = await database;
    return await db.update(
      'user_config',
      config,
      where: 'id = ?',
      whereArgs: [config['id']],
    );
  }

  /// Grava/atualiza o cache LOCAL do número de contato (ver
  /// `FirebaseSyncService.salvarTelefonePerfil` — o Firestore continua
  /// sendo a fonte de verdade; este cache só existe para exibição em "Meu
  /// Perfil" quando o Firestore não estiver acessível). Autossuficiente:
  /// cria a linha de `user_config` se ainda não existir uma (cenário
  /// possível logo após o login social, antes de qualquer outra tela ter
  /// chamado [_ensureUserConfig]-equivalente).
  Future<void> salvarTelefoneLocal(String telefone) async {
    final config = await getUserConfig();
    if (config == null) {
      await insertUserConfig({
        'pin_real': null,
        'tempo_padrao_timer': 15,
        'tipo_plano': 'free',
        'telefone': telefone,
      });
    } else {
      await updateUserConfig({'id': config['id'], 'telefone': telefone});
    }
  }

  // ==========================================
  // PIN REAL: PRIMEIRO CADASTRO x ALTERAÇÃO
  // ==========================================
  // Regra de negócio:
  // 1) Primeiro acesso (nenhum PIN cadastrado ainda): o PIN informado é
  //    efetivado INSTANTANEAMENTE em 'pin_real', sem qualquer carência.
  // 2) Alteração de um PIN já existente: a nova senha fica pendente por
  //    2 horas ('senha_pendente' + 'timestamp_alteracao_senha'),
  //    mantendo o PIN atual válido até que o prazo de segurança se
  //    cumpra.
  //
  // Retorna `true` se o PIN foi efetivado instantaneamente (primeiro
  // cadastro), ou `false` se ficou pendente por 2h (alteração).
  Future<bool> salvarOuAgendarPinReal(int userConfigId, String novoPin) async {
    final config = await getUserConfig();
    final String? pinAtual = config?['pin_real'] as String?;
    final bool possuiPinAtivo = pinAtual != null && pinAtual.trim().isNotEmpty;

    if (!possuiPinAtivo) {
      // Regra 1: primeiro cadastro — efetivação instantânea, sem carência.
      await updateUserConfig({
        'id': userConfigId,
        'pin_real': PinHash.gerar(novoPin),
        // Garante que não fique nenhuma alteração pendente residual.
        'senha_pendente': null,
        'timestamp_alteracao_senha': null,
      });
      return true;
    }

    // Regra 2: já existe um PIN ativo — aplica a carência de 2h.
    final agora = DateTime.now().millisecondsSinceEpoch.toString();
    await updateUserConfig({
      'id': userConfigId,
      'senha_pendente': PinHash.gerar(novoPin),
      'timestamp_alteracao_senha': agora,
    });
    return false;
  }

  // ==========================================
  // EFETIVAÇÃO CENTRALIZADA DA SENHA PENDENTE
  // ==========================================
  // Regra de segurança de 2h para ALTERAÇÃO de PIN (regra 2 acima): a
  // verificação "já passaram 2h desde a solicitação? então promove a
  // senha_pendente para pin_real" precisa ser executada de forma
  // consistente independente de qual tela o usuário abrir primeiro
  // (Segurança, Configurações, ou logo no cold start do app). Por isso
  // essa lógica fica centralizada aqui no DatabaseHelper, e é chamada por
  // todos os pontos de entrada relevantes, evitando que o app fique
  // "preso" mostrando o PIN antigo como pendente apenas porque a tela de
  // Segurança específica não foi visitada.
  //
  // Retorna `true` se uma senha pendente foi efetivada nesta chamada
  // (promovida a pin_real), ou `false` caso não houvesse nada pendente ou
  // o prazo de 2h ainda não tenha se cumprido.
  Future<bool> processarSenhaPendenteSeExpirada() async {
    final config = await getUserConfig();
    if (config == null) return false;

    final String? senhaPendente = config['senha_pendente'] as String?;
    final String? timestampStr = config['timestamp_alteracao_senha'] as String?;
    if (senhaPendente == null || timestampStr == null) return false;

    final timestampSolicitacao = int.tryParse(timestampStr);
    if (timestampSolicitacao == null) return false;

    final agora = DateTime.now().millisecondsSinceEpoch;
    final decorrido = agora - timestampSolicitacao;
    const prazoSegurancaMs = 7200000; // 2 horas em milissegundos

    if (decorrido < prazoSegurancaMs) {
      // Ainda dentro da carência: o PIN atual continua sendo o único válido.
      return false;
    }

    // Prazo de segurança cumprido: promove a senha pendente a PIN ativo.
    final id = config['id'] as int;
    await updateUserConfig({
      'id': id,
      'pin_real': senhaPendente,
      'senha_pendente': null,
      'timestamp_alteracao_senha': null,
    });
    return true;
  }

  // =================
  // CONTACTS METHODS
  // =================

  Future<int> insertContact(Map<String, dynamic> contact) async {
    final db = await database;
    return await db.insert('contacts', contact);
  }

  Future<List<Map<String, dynamic>>> getContacts() async {
    final db = await database;
    return await db.query('contacts', orderBy: 'id ASC');
  }

  Future<int> updateContact(Map<String, dynamic> contact) async {
    final db = await database;
    return await db.update(
      'contacts',
      contact,
      where: 'id = ?',
      whereArgs: [contact['id']],
    );
  }

  Future<int> deleteContact(int id) async {
    final db = await database;
    return await db.delete('contacts', where: 'id = ?', whereArgs: [id]);
  }

  // ==============================
  // CONTATOS DE EMERGÊNCIA METHODS
  // ==============================
  // Tabela isolada e dedicada exclusivamente aos contatos de emergência
  // cadastrados na aba Família (até 3 contatos), integrados via Agenda
  // do celular (flutter_contacts). Totalmente independente de user_config.

  /// Retorna todos os contatos de emergência cadastrados, ordenados por id.
  Future<List<Map<String, dynamic>>> getContatosEmergencia() async {
    final db = await database;
    return await db.query('contatos_emergencia', orderBy: 'id ASC');
  }

  /// Insere um novo contato de emergência. Retorna o id gerado.
  Future<int> inserirContatoEmergencia(Map<String, dynamic> contato) async {
    final db = await database;
    return await db.insert('contatos_emergencia', contato);
  }

  /// Remove um contato de emergência pelo id (exclusão IMEDIATA/definitiva).
  /// Usado apenas internamente após o prazo de segurança de 2h ter expirado.
  Future<int> deletarContatoEmergencia(int id) async {
    final db = await database;
    return await db.delete('contatos_emergencia', where: 'id = ?', whereArgs: [id]);
  }

  /// Marca um contato de emergência como "exclusão pendente", iniciando a
  /// trava de segurança de 2h. O contato NÃO é removido imediatamente,
  /// apenas sinalizado com o timestamp da solicitação. Continua sendo
  /// retornado normalmente por getContatosEmergencia() (e portanto ainda
  /// recebe alertas de emergência) até que o prazo expire.
  Future<int> solicitarExclusaoContatoEmergencia(int id) async {
    final db = await database;
    final agora = DateTime.now().millisecondsSinceEpoch.toString();
    return await db.update(
      'contatos_emergencia',
      {
        'exclusao_pendente': 1,
        'timestamp_solicitacao': agora,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Verifica todos os contatos com exclusão pendente e remove
  /// definitivamente aqueles cujo prazo de segurança de 2 horas já
  /// tenha expirado desde a solicitação.
  Future<void> processarExclusoesPendentesExpiradas() async {
    final db = await database;
    const prazoSegurancaMs = 7200000; // 2 horas em milissegundos
    final agora = DateTime.now().millisecondsSinceEpoch;

    final pendentes = await db.query(
      'contatos_emergencia',
      where: 'exclusao_pendente = 1',
    );

    for (final contato in pendentes) {
      final timestampStr = contato['timestamp_solicitacao'] as String?;
      final timestampSolicitacao = timestampStr != null ? int.tryParse(timestampStr) : null;
      if (timestampSolicitacao == null) continue;

      if (agora - timestampSolicitacao >= prazoSegurancaMs) {
        final id = contato['id'] as int;
        await db.delete('contatos_emergencia', where: 'id = ?', whereArgs: [id]);
      }
    }
  }

  // ====================
  // HISTORICO METHODS
  // ====================
  // Tabela 'historico' usada para registrar eventos administrativos do
  // aplicativo nas categorias 'seguranca', 'familia' e 'sistema', todos
  // exibidos de forma transparente na aba Histórico.

  /// Insere um novo evento no histórico. [categoria] deve ser uma das
  /// strings: 'seguranca', 'familia', 'sistema' ou 'critico'.
  ///
  /// IMPORTANTE — separação de privacidade: a categoria 'critico' é
  /// EXCLUSIVA para os alarmes de emergência e disparos de SMS de socorro
  /// (o registro mais sensível do aplicativo). Ela NUNCA deve aparecer na
  /// tela de Histórico Geral (ver [getHistorico]), sendo retornada apenas
  /// por [getEventosSensiveis], usada pelo filtro "Alertas enviados" da
  /// aba Histórico, protegida pelo PIN de acesso (ver
  /// [auditoriaDesbloqueadaNaSessao]/[desbloquearAuditoria]).
  Future<int> inserirEventoHistorico({
    required String titulo,
    required String descricao,
    required String categoria,
  }) async {
    final db = await database;
    final id = await db.insert('historico', {
      'titulo': titulo,
      'descricao': descricao,
      'categoria': categoria,
      'timestamp': DateTime.now().toIso8601String(),
    });
    // Avisa qualquer tela ouvindo (ver [historicoAtualizadoNotifier]) que
    // um novo evento acabou de ser gravado, para recarregar a lista já em
    // primeiro plano.
    historicoAtualizadoNotifier.value++;
    return id;
  }

  /// Retorna os eventos do histórico exibidos na tela de Histórico Geral
  /// (abas Todos/Segurança/Família/Sistema), ordenados do mais recente
  /// para o mais antigo.
  ///
  /// Regra de negócio de privacidade/blindagem: os registros da categoria
  /// 'critico' (alarmes de emergência e disparos de SMS de socorro) são
  /// EXCLUÍDOS explicitamente desta consulta, independentemente de
  /// qualquer status de liberação da Auditoria. Esses eventos só podem
  /// ser vistos dentro do cofre de Auditoria de Eventos Sensíveis (ver
  /// [getEventosSensiveis]), nunca aqui.
  Future<List<Map<String, dynamic>>> getHistorico() async {
    final db = await database;
    return await db.query(
      'historico',
      where: 'categoria != ?',
      whereArgs: ['critico'],
      orderBy: 'id DESC',
    );
  }

  /// Retorna somente os eventos do histórico da categoria 'critico', que
  /// são os registros mais críticos/sensíveis do aplicativo (alarmes de
  /// emergência e disparos de SMS de socorro para os contatos
  /// cadastrados). Usados exclusivamente pela tela de Auditoria de
  /// Eventos Sensíveis, que só libera essa visualização após a trava de
  /// segurança de 3 horas.
  Future<List<Map<String, dynamic>>> getEventosSensiveis() async {
    final db = await database;
    return await db.query(
      'historico',
      where: 'categoria = ?',
      whereArgs: ['critico'],
      orderBy: 'id DESC',
    );
  }


  /// Remove um único evento do histórico pelo id. Usado pelo gesto de
  /// "arrastar para excluir" (Dismissible) na aba Histórico.
  Future<int> deletarEventoHistorico(int id) async {
    final db = await database;
    return await db.delete('historico', where: 'id = ?', whereArgs: [id]);
  }

  /// Entrada ESTRUTURADA de um alerta enviado (ver HistoricoAlertasService).
  /// [dados] traz as colunas da tabela, inclusive `alerta_id`, que é único:
  /// um segundo insert do mesmo alerta é ignorado e retorna `false`.
  Future<bool> inserirAlertaHistorico(Map<String, dynamic> dados) async {
    final db = await database;
    final id = await db.insert('historico', dados, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (id == 0) return false;
    historicoAtualizadoNotifier.value++;
    return true;
  }

  /// Atualiza só as colunas em [campos] da entrada do alerta [alertaId].
  Future<void> atualizarAlertaHistorico(String alertaId, Map<String, dynamic> campos) async {
    final db = await database;
    final linhas = await db.update('historico', campos, where: 'alerta_id = ?', whereArgs: [alertaId]);
    if (linhas > 0) historicoAtualizadoNotifier.value++;
  }

  Future<Map<String, dynamic>?> buscarAlertaHistorico(String alertaId) async {
    final db = await database;
    final linhas = await db.query('historico', where: 'alerta_id = ?', whereArgs: [alertaId], limit: 1);
    return linhas.isEmpty ? null : linhas.first;
  }

  /// `alerta_id` → `status` de todas as entradas estruturadas — usado pela
  /// importação do Firestore para não duplicar nada.
  Future<Map<String, String?>> statusDosAlertasHistorico() async {
    final db = await database;
    final linhas = await db.query('historico',
        columns: ['alerta_id', 'status'], where: 'alerta_id IS NOT NULL');
    return {for (final l in linhas) l['alerta_id'] as String: l['status'] as String?};
  }

  /// Grava (substitui) o status de entrega do alerta [alertaId] ao [contato].
  Future<void> salvarEntregaContato({
    required String alertaId,
    required String contato,
    required String nome,
    required String status,
    required String texto,
  }) async {
    final db = await database;
    await db.insert(
      'entregas_alerta_contato',
      {
        'alerta_id': alertaId,
        'contato': contato,
        'nome': nome,
        'status': status,
        'texto': texto,
        'atualizado_em': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    historicoAtualizadoNotifier.value++;
  }

  Future<List<Map<String, dynamic>>> entregasDoAlerta(String alertaId) async {
    final db = await database;
    return db.query('entregas_alerta_contato',
        where: 'alerta_id = ?', whereArgs: [alertaId], orderBy: 'nome ASC');
  }

  /// Alerta ENVIADO mais recente dentro de [janela] (aviso de entrega sem
  /// `alertaId`).
  Future<String?> alertaMaisRecenteEnviado(Duration janela) async {
    final db = await database;
    final desde = DateTime.now().subtract(janela).toIso8601String();
    final linhas = await db.query(
      'historico',
      columns: ['alerta_id'],
      where: "categoria = 'critico' AND alerta_id IS NOT NULL AND timestamp >= ? AND "
          "tipo IN ('sos_manual','sos_widget','cronometro_expirado','tentativa_desarme_incorreto','despertador_expirado')",
      whereArgs: [desde],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    return linhas.isEmpty ? null : linhas.first['alerta_id'] as String?;
  }

  /// Remove TODOS os eventos locais de uma [categoria] específica —
  /// usado pela opção "Limpar Histórico" (ex: 'sistema', ou 'critico'
  /// pela tela de Auditoria de Eventos Sensíveis).
  Future<void> limparHistoricoPorCategoria(String categoria) async {
    final db = await database;
    await db.delete('historico', where: 'categoria = ?', whereArgs: [categoria]);
  }

  /// Remove TODOS os eventos locais exibidos na aba Histórico Geral —
  /// ou seja, tudo MENOS a categoria 'critico' (exclusiva da tela de
  /// Auditoria de Eventos Sensíveis, nunca tocada por esta função). Usado
  /// pela opção "Limpar Histórico" quando o filtro "Todos" está
  /// selecionado.
  Future<void> limparHistoricoGeral() async {
    final db = await database;
    await db.delete('historico', where: 'categoria != ?', whereArgs: ['critico']);
  }

  // ==========================================
  // AUDITORIA DE EVENTOS SENSÍVEIS (trava por PIN)
  // ==========================================
  // Recurso de proteção de dados que exige a confirmação do PIN de acesso
  // do usuário (o mesmo cadastrado em Configurações — ver
  // [DatabaseHelper.salvarOuAgendarPinReal]) antes de liberar a
  // visualização dos eventos mais sensíveis (categoria 'critico':
  // alarmes de emergência e disparos de SMS de socorro do próprio
  // usuário), evitando acesso não autorizado a esses registros caso o
  // dispositivo seja acessado por terceiros.
  //
  // Histórico: até 2026-09, esse acesso também exigia aguardar um prazo
  // de carência de 2h após uma solicitação explícita (ver histórico do
  // Git para a implementação anterior). Essa carência foi removida a
  // pedido do responsável pelo produto — a confirmação do PIN passou a
  // ser a única barreira de acesso.

  /// true se o usuário já confirmou o PIN de acesso nesta sessão do app
  /// (resetado a cada cold start — ver [resetarSessaoAuditoria] — e ao
  /// bloquear manualmente de novo — ver [bloquearAuditoriaNovamente]).
  Future<bool> auditoriaDesbloqueadaNaSessao() async {
    final config = await getUserConfig();
    if (config == null) return false;
    return (config['auditoria_liberada_sessao'] as int?) == 1;
  }

  /// Marca a sessão atual como desbloqueada, chamado depois que
  /// [PinDialogContent] confirma que o usuário digitou o PIN de acesso
  /// correto.
  Future<void> desbloquearAuditoria() async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({'id': id, 'auditoria_liberada_sessao': 1});
  }

  /// Deve ser chamado uma única vez, logo na inicialização do app (cold
  /// start), para resetar a flag 'auditoria_liberada_sessao'. Isso
  /// garante que, assim que o aplicativo for totalmente fechado e
  /// reaberto, o PIN precise ser confirmado de novo.
  Future<void> resetarSessaoAuditoria() async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({'id': id, 'auditoria_liberada_sessao': 0});
  }

  /// Bloqueia novamente o acesso aos registros sensíveis, acionado pelo
  /// botão "Bloquear Novamente" na aba Histórico já liberada. Exige uma
  /// NOVA confirmação de PIN para o próximo acesso.
  Future<void> bloquearAuditoriaNovamente() async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({'id': id, 'auditoria_liberada_sessao': 0});
  }


  // ==========================================
  // ALARMES DE ROTINA (Gerenciador estilo despertador)
  // ==========================================
  // Tabela 'alarmes_rotina', usada pela aba Família para gerenciar
  // múltiplos alarmes de rotina/check-in, no estilo do despertador do
  // iPhone. Cada alarme possui hora, minuto, dias da semana de repetição
  // (string CSV, ex: "1,3,5", onde 1=Segunda ... 7=Domingo), um estado
  // ativo/inativo (alternável rapidamente via switch) e uma etiqueta
  // livre descrevendo o propósito do alarme (ex: "Chegada no trabalho").

  /// Insere um novo alarme de rotina. Retorna o id gerado.
  Future<int> inserirAlarme(Map<String, dynamic> alarme) async {
    final db = await database;
    return await db.insert('alarmes_rotina', alarme);
  }

  /// Retorna todos os alarmes de rotina cadastrados, ordenados por
  /// horário (hora e minuto) para facilitar a visualização cronológica.
  Future<List<Map<String, dynamic>>> listarAlarmes() async {
    final db = await database;
    return await db.query('alarmes_rotina', orderBy: 'hora ASC, minuto ASC');
  }

  /// Atualiza os dados de um alarme de rotina já existente (hora, minuto,
  /// dias da semana, etiqueta e/ou estado ativo). O mapa [alarme] deve
  /// conter obrigatoriamente a chave 'id'.
  Future<int> atualizarAlarme(Map<String, dynamic> alarme) async {
    final db = await database;
    return await db.update(
      'alarmes_rotina',
      alarme,
      where: 'id = ?',
      whereArgs: [alarme['id']],
    );
  }

  /// Alterna rapidamente o estado ativo/inativo de um alarme (usado pelo
  /// SwitchListTile na listagem da aba Família), sem precisar reenviar os
  /// demais campos do alarme.
  Future<int> alternarAtivoAlarme(int id, bool ativo) async {
    final db = await database;
    return await db.update(
      'alarmes_rotina',
      {'ativo': ativo ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Remove definitivamente um alarme de rotina pelo id.
  Future<int> deletarAlarme(int id) async {
    final db = await database;
    return await db.delete('alarmes_rotina', where: 'id = ?', whereArgs: [id]);
  }

  /// Busca um único alarme de rotina pelo id. Usado pelo callback headless
  /// do [RotinaAlarmeService] (Etapa 3), que roda em um isolate/engine
  /// separado e recebe apenas o id do alarme como parâmetro, precisando
  /// consultar o restante dos dados (contexto, tolerância etc.) no SQLite.
  Future<Map<String, dynamic>?> buscarAlarmePorId(int id) async {
    final db = await database;
    final result = await db.query('alarmes_rotina', where: 'id = ?', whereArgs: [id], limit: 1);
    return result.isNotEmpty ? result.first : null;
  }

  /// Atualiza apenas o timestamp (epoch ms) do último disparo NATIVO já
  /// processado para este alarme de rotina, usado para fins de
  /// auditoria/depuração pelo [RotinaAlarmeService].
  Future<int> marcarUltimoDisparo(int id, int epoch) async {
    final db = await database;
    return await db.update(
      'alarmes_rotina',
      {'ultimo_disparo_epoch': epoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Marca/desmarca o alarme de rotina [id] como "pausado"
  /// (`alarme_pausado`), acionado pelo botão "Pausar Alarme"/"Alarme
  /// Pausado" (ver [RotinaAlarmeService.pausarAlarme] e a aba Família).
  /// Quando pausado, o alarme permanece cadastrado (não é excluído),
  /// mas o próximo disparo é ignorado pelo callback headless.
Future<int> definirAlarmePausado(int id, dynamic statusPausa) async {
    final db = await database;
    final valorStr = statusPausa is bool 
        ? (statusPausa ? '1' : '0') 
        : statusPausa.toString();
        
    return await db.update(
      'alarmes_rotina',
      {'alarme_pausado': valorStr},
      where: 'id = ?',
      whereArgs: [id],
    );
  }



  // ==========================================================
  // [TEMPORÁRIO/DEBUG] RESET MANUAL DE SENHA PARA TESTES FÍSICOS
  // ==========================================================
  // ATENÇÃO: Função exclusiva para uso durante testes de desenvolvimento.
  // Executa um UPDATE direto na tabela 'user_config', limpando os campos
  // 'pin_real', 'senha_pendente' e 'timestamp_alteracao_senha', forçando
  // o aplicativo a voltar ao estado de "Primeiro Acesso" (sem PIN
  // cadastrado), permitindo cadastrar uma nova senha instantaneamente,
  // sem a carência de 2h. REMOVER antes de qualquer build de produção.
  Future<void> debugResetarSenhaParaPrimeiroAcesso() async {
    final db = await database;
    await db.rawUpdate('''
      UPDATE user_config
      SET pin_real = NULL,
          senha_pendente = NULL,
          timestamp_alteracao_senha = NULL
    ''');
  }

  // ==========================================================
  // DISPARO DE EMERGÊNCIA VIA ALARME NATIVO (background/headless)
  // ==========================================================
  // Conjunto de métodos usados tanto pela UI (SegurancaTab) quanto pelo
  // callback headless do AlarmeService (que roda em um isolate/engine
  // separado, sem acesso a nenhum estado em memória do app principal).
  // Por isso TODO o contexto necessário para o disparo (contatos, dica de
  // contexto, PIN esperado etc.) precisa estar persistido em disco.

  /// Marca no banco que o cronômetro de check-in foi iniciado, salvando a
  /// dica de contexto digitada pelo usuário (usada para montar a mensagem
  /// de SMS) e o timestamp (epoch ms) em que o alarme nativo está
  /// agendado para disparar. Chamado pela SegurancaTab ao iniciar o
  /// cronômetro, IMEDIATAMENTE ANTES de agendar o alarme nativo via
  /// AlarmeService.
  Future<void> salvarContextoTimerAtivo({
    required String contexto,
    required DateTime timestampExpiracao,
  }) async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({
      'id': id,
      'contexto_timer_ativo': contexto,
      'timestamp_expiracao_alarme':
          timestampExpiracao.millisecondsSinceEpoch.toString(),
    });
  }

  /// Limpa a dica de contexto e o timestamp de expiração persistidos por
  /// [salvarContextoTimerAtivo] — chamado por `SegurancaTab._pararTimer`
  /// sempre que o cronômetro de check-in é encerrado por qualquer
  /// caminho NORMAL (PIN correto, alerta já disparado localmente).
  ///
  /// CORREÇÃO DE BUG REAL (2026-08-23): sem isto, esses dois campos
  /// ficavam para sempre no banco após QUALQUER ciclo — a próxima vez
  /// que `SegurancaTab` fosse recriada (ver bug de perda de State ao
  /// navegar para "Início", corrigido em `SegurancaTab._restaurarCronometroAtivoSePersistido`)
  /// poderia "ressuscitar" um ciclo já encerrado há muito tempo como se
  /// ainda estivesse ativo, sempre que, por coincidência, esse timestamp
  /// antigo ainda estivesse no futuro (cronômetros longos) ou fosse mal
  /// interpretado. `limparAguardandoConfirmacaoPin` já limpava os dois
  /// campos, mas só no caminho de PÓS-disparo (PIN digitado na tela de
  /// bloqueio) — este método cobre o caminho, muito mais comum, de
  /// desarme NORMAL antes do prazo vencer.
  Future<void> limparContextoTimerAtivo() async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({
      'id': id,
      'contexto_timer_ativo': null,
      'timestamp_expiracao_alarme': null,
    });
  }

  /// Marca no banco que um disparo de emergência JÁ OCORREU (o SMS já foi
  /// enviado pelo callback headless) e que o app deve exibir a tela de
  /// bloqueio de PIN assim que for reaberto, até que o PIN correto seja
  /// digitado. Chamado exclusivamente pelo callback estático headless do
  /// AlarmeService, portanto usa sua PRÓPRIA instância de banco (o
  /// singleton `database` é resolvido normalmente, pois cada isolate/
  /// engine abre sua própria conexão sqflite apontando para o mesmo
  /// arquivo físico do banco).
  Future<void> marcarAguardandoConfirmacaoPin() async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({
      'id': id,
      'aguardando_confirmacao_pin': 1,
    });
  }

  /// Limpa a flag de bloqueio, chamada quando o usuário digita o PIN
  /// correto na TelaBloqueioPin (tanto no cenário de tolerância com o app
  /// aberto quanto no cenário de cold start pós-disparo em background).
  Future<void> limparAguardandoConfirmacaoPin() async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({
      'id': id,
      'aguardando_confirmacao_pin': 0,
      'contexto_timer_ativo': null,
      'timestamp_expiracao_alarme': null,
    });
  }

  /// Verifica se o app deve exibir a tela de bloqueio de PIN assim que for
  /// aberto (cold start), usado por main.dart/HomeScreen.
  Future<bool> isAguardandoConfirmacaoPin() async {
    final config = await getUserConfig();
    if (config == null) return false;
    return (config['aguardando_confirmacao_pin'] as int?) == 1;
  }

  // ==========================================================
  // ALERTA SONORO CUSTOMIZÁVEL (Etapa 1 - Expansão Global)
  // ==========================================================
  // Persistência das escolhas de som (1 a 10) e duração (segundos) do
  // alerta sonoro disparado ao término do cronômetro de check-in. Estes
  // métodos espelham/complementam a persistência feita via
  // SharedPreferences pelo AlarmeSonoroService, mantendo também um
  // registro no SQLite (user_config) para consistência com o restante
  // das preferências do usuário.

  Future<void> salvarSomAlarmeSelecionado(int numeroSom) async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({'id': id, 'som_alarme_selecionado': numeroSom});
  }

  Future<void> salvarDuracaoSomAlarme(int segundos) async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({'id': id, 'duracao_som_alarme': segundos});
  }

  // ==========================================================
  // IDIOMA SELECIONADO (Etapa 2 - Internacionalização)
  // ==========================================================
  // Persiste o código do idioma escolhido pelo usuário (ver
  // lib/services/localization_service.dart para a lista completa dos 11
  // idiomas globais suportados).

  Future<void> salvarIdiomaSelecionado(String codigoIdioma) async {
    final config = await getUserConfig();
    if (config == null) return;
    final id = config['id'] as int;
    await updateUserConfig({'id': id, 'idioma_selecionado': codigoIdioma});
  }

  // ==========================================================
  // MONITORAMENTO — CONTATOS E STATUS DE PERMISSÃO (aba Monitoramento)
  // ==========================================================
  // Tabela 'monitoramento_contatos', totalmente independente de
  // 'contatos_emergencia'. Cada contato pode ter até duas relações de
  // permissão simultâneas e independentes no Firestore (coleção
  // `permissoes_monitoramento`, ver MonitoramentoService):
  //   Bloco A ("ver localização dele"): status_ver_localizacao.
  //   Bloco B ("compartilhar minha localização com ele"): status_compartilhamento.
  // As colunas de status aqui são um CACHE local (para exibição imediata
  // e uso offline) — a fonte de verdade é sempre o documento no
  // Firestore, mantido sincronizado pelos listeners do MonitoramentoService.

  /// Retorna todos os contatos de monitoramento cadastrados, ordenados
  /// por id.
  Future<List<Map<String, dynamic>>> listarContatosMonitoramento() async {
    final db = await database;
    return await db.query('monitoramento_contatos', orderBy: 'id ASC');
  }

  /// Busca um único contato de monitoramento pelo id.
  Future<Map<String, dynamic>?> buscarContatoMonitoramentoPorId(int id) async {
    final db = await database;
    final result = await db.query(
      'monitoramento_contatos',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return result.isNotEmpty ? result.first : null;
  }

  /// Busca um contato de monitoramento já resolvido para o [uid] informado
  /// — usado para localizar/criar a linha local correspondente quando uma
  /// solicitação de localização é RECEBIDA de alguém que ainda não estava
  /// na lista local (ver MonitoramentoService.responderSolicitacao).
  Future<Map<String, dynamic>?> buscarContatoMonitoramentoPorUid(
    String uid,
  ) async {
    final db = await database;
    final result = await db.query(
      'monitoramento_contatos',
      where: 'uid_contato = ?',
      whereArgs: [uid],
      limit: 1,
    );
    return result.isNotEmpty ? result.first : null;
  }

  /// Insere um novo contato de monitoramento. Retorna o id gerado.
  Future<int> inserirContatoMonitoramento({
    required String nome,
    required String telefone,
  }) async {
    final db = await database;
    return await db.insert('monitoramento_contatos', {
      'nome': nome,
      'telefone': telefone,
      'criado_em': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Edita apenas o nome (apelido local) de um contato de monitoramento já
  /// cadastrado — o telefone não é editável após criado, pois é a chave de
  /// resolução do uid no Firestore.
  Future<int> atualizarNomeContatoMonitoramento(int id, String nome) async {
    final db = await database;
    return await db.update(
      'monitoramento_contatos',
      {'nome': nome},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Remove definitivamente um contato de monitoramento pelo id. Exclusão
  /// IMEDIATA (sem trava de 2h, diferente de contatos_emergencia) — não
  /// revoga, por si só, nenhuma permissão já concedida no Firestore.
  Future<int> deletarContatoMonitoramento(int id) async {
    final db = await database;
    return await db.delete(
      'monitoramento_contatos',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Grava o uid do Firebase Auth resolvido para este contato (pelo
  /// telefone, via Cloud Function callable 'solicitarMonitoramento').
  Future<int> atualizarUidContatoMonitoramento(int id, String uid) async {
    final db = await database;
    return await db.update(
      'monitoramento_contatos',
      {'uid_contato': uid},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Apaga o que foi resolvido na NUVEM para os contatos de monitoramento
  /// (uid e status em cache), mantendo nome e telefone. [somenteUid]
  /// restringe às linhas cujo uid resolvido é esse. Usado quando o cache
  /// pertence a outra conta (ver MonitoramentoService.listarContatos).
  Future<int> limparResolucaoContatosMonitoramento({String? somenteUid}) async {
    final db = await database;
    return await db.update(
      'monitoramento_contatos',
      {
        'uid_contato': null,
        'status_ver_localizacao': 'nao_solicitado',
        'status_compartilhamento': 'inexistente',
      },
      where: somenteUid == null ? null : 'uid_contato = ?',
      whereArgs: somenteUid == null ? null : [somenteUid],
    );
  }

  /// Atualiza o cache local do status do Bloco A ("ver localização dele"):
  /// 'nao_solicitado' | 'pendente' | 'aprovado' | 'negado' | 'expirado'.
  Future<int> atualizarStatusVerLocalizacao(int id, String status) async {
    final db = await database;
    return await db.update(
      'monitoramento_contatos',
      {'status_ver_localizacao': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Atualiza o cache local do status do Bloco B ("compartilhar minha
  /// localização com ele"): 'inexistente' | 'pendente' | 'aprovado' |
  /// 'bloqueado'.
  Future<int> atualizarStatusCompartilhamento(int id, String status) async {
    final db = await database;
    return await db.update(
      'monitoramento_contatos',
      {'status_compartilhamento': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ==========================================================
  // ALERTAS DE TERCEIROS RECEBIDOS (indicador de não visualizado +
  // aba Histórico) — ver AlertasRecebidosService/FcmService.
  // ==========================================================

  /// Insere um alerta de terceiro recebido via Push FCM. Idempotente por
  /// `id_entrega` (UNIQUE) — se o FCM reentregar a mesma mensagem, a
  /// segunda tentativa é silenciosamente ignorada (`ConflictAlgorithm.ignore`)
  /// em vez de duplicar a linha.
  Future<void> inserirAlertaTerceiroRecebido({
    String? idEntrega,
    String? nomeRemetente,
    required String mensagem,
    double? latitude,
    double? longitude,
    String? fotoUrl,
  }) async {
    final db = await database;
    await db.insert(
      'alertas_terceiros_recebidos',
      {
        'id_entrega': idEntrega,
        'nome_remetente': nomeRemetente,
        'mensagem': mensagem,
        'latitude': latitude,
        'longitude': longitude,
        'foto_url': fotoUrl,
        'recebido_em': DateTime.now().toIso8601String(),
        'visualizado': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Retorna todos os alertas de terceiros recebidos, mais recente primeiro.
  Future<List<Map<String, dynamic>>> getAlertasTerceirosRecebidos() async {
    final db = await database;
    return await db.query('alertas_terceiros_recebidos', orderBy: 'id DESC');
  }

  /// Conta quantos alertas de terceiros recebidos ainda não foram
  /// visualizados — usado para o badge no ícone da aba Histórico.
  Future<int> contarAlertasTerceirosNaoVisualizados() async {
    final db = await database;
    final resultado = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM alertas_terceiros_recebidos WHERE visualizado = 0',
    );
    return Sqflite.firstIntValue(resultado) ?? 0;
  }

  /// Marca um alerta de terceiro como visualizado pelo seu [id] local.
  Future<void> marcarAlertaTerceiroVisualizado(int id) async {
    final db = await database;
    await db.update(
      'alertas_terceiros_recebidos',
      {'visualizado': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Remove definitivamente um alerta de terceiro recebido pelo seu [id]
  /// local — acionado pelo gesto de "arrastar para excluir" (Dismissible)
  /// na aba Histórico.
  Future<void> deletarAlertaTerceiroRecebido(int id) async {
    final db = await database;
    await db.delete('alertas_terceiros_recebidos', where: 'id = ?', whereArgs: [id]);
  }

  /// Remove TODOS os alertas de terceiros recebidos de uma vez — usado
  /// pela opção "Limpar Histórico" quando o filtro "Alerta de segurança
  /// recebido" está selecionado.
  Future<void> limparAlertasTerceirosRecebidos() async {
    final db = await database;
    await db.delete('alertas_terceiros_recebidos');
  }

  /// Marca um alerta de terceiro como visualizado pelo seu [idEntrega] —
  /// usado quando só temos esse identificador (ex: toque direto na
  /// notificação Push, sem passar pela lista da aba Histórico).
  Future<void> marcarAlertaTerceiroVisualizadoPorIdEntrega(String idEntrega) async {
    final db = await database;
    await db.update(
      'alertas_terceiros_recebidos',
      {'visualizado': 1},
      where: 'id_entrega = ?',
      whereArgs: [idEntrega],
    );
  }

  // ==========================================================
  // FILA DE RETRY OFFLINE (ver RetryUploadService)
  // ==========================================================

  /// Enfileira um upload de foto do SOS que falhou por falta de
  /// conectividade — [fotoPath] deve já ser um caminho PERMANENTE (não o
  /// arquivo temporário original da captura, que o SO pode reciclar a
  /// qualquer momento), ver [RetryUploadService.enfileirar].
  Future<int> enfileirarRetryUploadSos({
    required String fotoPath,
    required String origem,
    double? latitude,
    double? longitude,
    String? alertaId,
  }) async {
    final db = await database;
    return await db.insert('fila_retry_upload_sos', {
      'foto_path': fotoPath,
      'origem': origem,
      'latitude': latitude,
      'longitude': longitude,
      'alerta_id': alertaId,
      'criado_em': DateTime.now().toIso8601String(),
      'tentativas': 0,
    });
  }

  /// Lista todos os uploads de SOS ainda pendentes de reenvio, do mais
  /// antigo para o mais novo (ordem de chegada).
  Future<List<Map<String, dynamic>>> listarRetryUploadSosPendentes() async {
    final db = await database;
    return await db.query('fila_retry_upload_sos', orderBy: 'id ASC');
  }

  /// Remove um item da fila — chamado assim que o reenvio for concluído
  /// com sucesso (upload + SMS/nuvem despachados).
  Future<void> removerRetryUploadSos(int id) async {
    final db = await database;
    await db.delete('fila_retry_upload_sos', where: 'id = ?', whereArgs: [id]);
  }

  /// Incrementa o contador de tentativas de um item que falhou de novo —
  /// usado por [RetryUploadService] para desistir depois de um número
  /// máximo de tentativas, evitando reter arquivos de foto órfãos
  /// indefinidamente no armazenamento do aparelho.
  Future<void> incrementarTentativaRetryUploadSos(int id) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE fila_retry_upload_sos SET tentativas = tentativas + 1 WHERE id = ?',
      [id],
    );
  }

  /// Apaga TODAS as linhas de TODAS as tabelas locais — usado
  /// exclusivamente pelo fluxo de "Excluir Conta e Dados"
  /// (ver `ExclusaoContaService`), nunca por um logout comum (que
  /// deliberadamente preserva os dados locais para um possível novo
  /// login no mesmo aparelho). Diferente de apagar o arquivo do banco
  /// inteiro, `DELETE FROM` em cada tabela mantém o schema intacto (sem
  /// precisar fechar/reabrir a conexão já em uso pelo resto do app) e é
  /// suficiente, já que a conta associada a esses dados deixará de
  /// existir no Firebase Auth logo em seguida.
  ///
  /// Cada tabela é apagada isoladamente, protegida por try/catch: uma
  /// falha isolada (ex: tabela ainda não migrada nesta instalação) nunca
  /// deve impedir a limpeza das demais.
  Future<void> apagarTudoLocal() async {
    final db = await database;
    const tabelas = [
      'user_config',
      'contacts',
      'contatos_emergencia',
      'historico',
      'alarmes_rotina',
      'monitoramento_contatos',
      'alertas_terceiros_recebidos',
      'fila_retry_upload_sos',
      'entregas_alerta_contato',
    ];
    for (final tabela in tabelas) {
      try {
        await db.delete(tabela);
      } catch (e) {
        debugPrint('⚠️ [DatabaseHelper] Falha ao limpar a tabela "$tabela": $e');
      }
    }
  }
}


