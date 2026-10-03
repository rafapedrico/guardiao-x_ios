import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Serviço central de autenticação do "Guardião X" — Firebase Auth real
/// (e-mail/senha), com barreira estrita de e-mail verificado: nenhuma
/// sessão dá acesso ao app sem que `emailVerified == true` (ver
/// verificação em [LoginScreen] e envio do e-mail em [CadastroScreen]).
/// Login social (Google/Apple) fica em [SocialAuthService] — cada um
/// deles, no primeiro login sem telefone cadastrado, passa por
/// `CompletarPerfilScreen` (nome + telefone como campo de perfil comum,
/// sem SMS OTP — decisão de arquitetura 2026-08-23; unicidade garantida
/// server-side, ver `FirebaseSyncService.salvarTelefonePerfil`) antes de
/// liberar o acesso.
///
/// POLÍTICA DE SEGURANÇA (Opção A): sessões do Firebase Auth NUNCA
/// sobrevivem a um cold start NORMAL — `main()` chama [logout] logo após
/// inicializar o Firebase, antes de `runApp`, para que o app sempre
/// reabra na `LoginScreen` e exija credenciais de novo (ver
/// `_telaInicial` em `main.dart`). EXCEÇÃO deliberada: um cold start via
/// SOS físico (botão de Volume+ com o app fechado, ver
/// `LockscreenCameraActivity`/`main.dart`) NÃO chama [logout] — esse
/// fluxo nunca exibe nenhuma UI de conta (só a câmera), então preservar
/// a sessão não expõe nada a quem estiver com o aparelho, e é o que
/// permite o SOS físico disparar com Push/link real da foto
/// mesmo 100% a frio (sem essa exceção, `uidAtual` ficava sempre `null`
/// nesse cenário, e o SOS físico caía sempre no SMS de fallback sem
/// link real).
///
/// Toda a arquitetura híbrida de alertas (vínculo telefone/fcmToken,
/// regras do Firestore) depende de um `uid` real: é ele que passa a
/// identificar o documento em `usuarios/{uid}` no lugar do antigo
/// `ApiService.usuarioIdPadrao` fixo.
class FirebaseAuthService {
  FirebaseAuthService._internal();
  static final FirebaseAuthService _instance = FirebaseAuthService._internal();
  factory FirebaseAuthService() => _instance;

  FirebaseAuth get _auth => FirebaseAuth.instance;

  /// `uid` do usuário autenticado no momento, ou `null` se não houver
  /// sessão ativa.
  String? get uidAtual => _auth.currentUser?.uid;

  User? get usuarioAtual => _auth.currentUser;

  /// Stream do estado de autenticação, usada por `main.dart` para decidir
  /// entre `LoginScreen` e o fluxo principal do app.
  Stream<User?> get mudancasDeEstado => _auth.authStateChanges();

  /// Resolve o `uid` com segurança contra a corrida de restauração da
  /// sessão: `currentUser`/[uidAtual] é uma leitura SÍNCRONA do SDK, mas
  /// logo após `Firebase.initializeApp()` (caso de um engine recém-criado,
  /// ver `LockscreenCameraActivity`/`RotinaCheckinAlarmActivity`), o SDK
  /// ainda pode estar restaurando de forma ASSÍNCRONA, em segundo plano, a
  /// sessão persistida em disco — nesses primeiros instantes,
  /// `currentUser` pode retornar `null` mesmo havendo uma sessão válida
  /// salva, fazendo o chamador concluir (incorretamente) "sem sessão" e
  /// cair num fallback sem nuvem/link real (bug real observado no SOS via
  /// botão físico: a foto — P2, que roda alguns segundos DEPOIS do
  /// disparo inicial — às vezes usava o SMS de fallback com link falso).
  ///
  /// Caminho rápido: se [uidAtual] já está disponível, devolve na hora,
  /// sem nenhuma espera (não atrasa o caso comum, imensa maioria das
  /// chamadas). Só quando `null`, aguarda a primeira emissão de
  /// [mudancasDeEstado] (o SDK garante emitir assim que a restauração
  /// termina, com o usuário real OU `null` se de fato não há sessão) —
  /// com um teto de tempo para nunca travar um fluxo de emergência
  /// esperando indefinidamente por uma sessão que genuinamente não existe.
  Future<String?> aguardarUidPronto({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final String? imediato = uidAtual;
    if (imediato != null) return imediato;

    try {
      final User? usuario = await mudancasDeEstado.first.timeout(timeout);
      return usuario?.uid;
    } catch (e) {
      debugPrint(
          '⚠️ [FirebaseAuthService] Timeout/erro aguardando restauração da sessão — seguindo com uidAtual atual ($uidAtual): $e');
      return uidAtual;
    }
  }

  /// Cria a conta com e-mail/senha. Lança [FirebaseAuthException] em caso
  /// de falha (e-mail já em uso, senha fraca, etc.) — quem chama deve
  /// tratar e exibir a mensagem adequada.
  Future<UserCredential> criarConta({
    required String email,
    required String senha,
  }) {
    return _auth.createUserWithEmailAndPassword(email: email, password: senha);
  }

  /// Login com e-mail/senha. Lança [FirebaseAuthException] em caso de
  /// falha (usuário inexistente, senha incorreta, etc.).
  Future<UserCredential> login({
    required String email,
    required String senha,
  }) {
    return _auth.signInWithEmailAndPassword(email: email, password: senha);
  }

  /// Envia o e-mail de redefinição de senha do Firebase Auth ("Esqueci
  /// minha senha", ver `RecuperarSenhaDialog`). Lança
  /// [FirebaseAuthException] em caso de falha (e-mail inválido, sem
  /// conta cadastrada, sem rede, etc.) — quem chama deve tratar e exibir
  /// a mensagem adequada, mesmo padrão de [login]/[criarConta].
  ///
  /// [languageCode] (reespecificação do usuário, 2026-08-16): sem
  /// informar, o Firebase Auth envia o TEMPLATE do e-mail (assunto, corpo,
  /// botão) sempre em inglês, o idioma padrão do projeto — independente do
  /// idioma que o usuário escolheu dentro do app. `setLanguageCode` avisa
  /// o SDK, ANTES do envio, para usar a tradução do template configurada
  /// no Firebase Console para esse código (`pt`, `es`, `en`, etc.) — ver
  /// [RecuperarSenhaDialog], que passa
  /// `Localizations.localeOf(context).languageCode`. Best-effort: uma
  /// falha aqui (ex: código de idioma sem template configurado no
  /// Console) nunca deve impedir o envio do e-mail em si — só o idioma do
  /// texto que fica comprometido (cai no padrão do projeto).
  Future<void> recuperarSenha({
    required String email,
    String? languageCode,
  }) async {
    if (languageCode != null && languageCode.isNotEmpty) {
      try {
        await _auth.setLanguageCode(languageCode);
      } catch (e) {
        debugPrint(
            '⚠️ [FirebaseAuthService] Falha ao definir idioma ($languageCode) do e-mail de recuperação: $e');
      }
    }
    return _auth.sendPasswordResetEmail(email: email);
  }

  // Métodos de verificação de telefone por SMS OTP (Firebase Phone Auth)
  // REMOVIDOS em 2026-08-23 (decisão de arquitetura: zerar custo de SMS +
  // simplificar onboarding). O telefone agora é um campo de perfil comum,
  // gravado via `FirebaseSyncService.salvarTelefonePerfil` — ver
  // `telefonePerfilService.js` para a garantia de unicidade que substitui
  // a antiga prova de posse por SMS.

  Future<void> logout() async {
    try {
      await _auth.signOut();
    } catch (e) {
      debugPrint('⚠️ [FirebaseAuthService] Falha ao encerrar sessão: $e');
    }
  }

  /// Recarrega os dados do usuário atual diretamente do servidor —
  /// necessário para obter o valor mais recente de `emailVerified`: o
  /// SDK mantém um snapshot local que só reflete uma verificação
  /// concluída (o usuário clicou no link do e-mail) depois de um reload
  /// explícito. Chamado pela [LoginScreen] antes de checar
  /// `emailVerified`, garantindo que a barreira de e-mail verificado
  /// nunca libere acesso com base num estado desatualizado em cache.
  Future<void> recarregarUsuarioAtual() async {
    await _auth.currentUser?.reload();
  }

  /// Envia (ou reenvia) o e-mail de verificação para o usuário
  /// atualmente autenticado. Não faz nada se não houver sessão ativa.
  Future<void> enviarEmailVerificacao() async {
    await _auth.currentUser?.sendEmailVerification();
  }

  /// Força a renovação do ID token do usuário atual — necessária ANTES
  /// de qualquer chamada autenticada ao Firestore feita logo após
  /// [Firebase.initializeApp] no cold start (ver `main.dart`,
  /// sincronização do `fcmToken` a partir da sessão recém-restaurada).
  ///
  /// BUG REAL CONFIRMADO (2026-08-15, via logcat): a sessão é restaurada
  /// SINCRONAMENTE pelo SDK ([uidAtual] já não é nulo imediatamente após
  /// `Firebase.initializeApp()`), mas o ID token usado pelo SDK do
  /// Firestore para AUTORIZAR a chamada ainda não está necessariamente
  /// pronto/anexado nesse instante exato — a primeira escrita
  /// autenticada do cold start falhava com
  /// `[cloud_firestore/permission-denied]` mesmo com um `uid` válido e
  /// as regras corretas (`request.auth.uid == usuarioId`), porque
  /// `request.auth` ainda não estava totalmente populado no momento em
  /// que a chamada saiu. `getIdToken(true)` força essa renovação e só
  /// retorna depois que o token está de fato pronto, eliminando a
  /// corrida. Protegida por try/catch: sem sessão ativa (`currentUser ==
  /// null`) ou qualquer falha de rede, é um no-op seguro — o chamador
  /// decide o que fazer a seguir.
  Future<void> garantirTokenPronto() async {
    try {
      await _auth.currentUser?.getIdToken(true);
    } catch (e) {
      debugPrint('⚠️ [FirebaseAuthService] Falha ao renovar o ID token: $e');
    }
  }

  /// Revoga qualquer sessão em OUTRO aparelho da MESMA conta (pedido
  /// explícito do usuário, 2026-09-06: "perdi o celular antigo, a sessão
  /// dele deve parar de funcionar quando eu logar de novo em um
  /// aparelho novo") — chama a callable `revogarSessoesEmOutrosDispositivos`
  /// (Admin SDK, ver `functions/sessaoDispositivoService.js`), que só
  /// revoga o PRÓPRIO uid autenticado do chamador. DELIBERADAMENTE não
  /// tem nenhuma relação com número de telefone — só o UID importa.
  ///
  /// O corte é feito no servidor no instante do login DESTE aparelho
  /// (`auth_time`), então a sessão atual continua válida (bug corrigido em
  /// 2026-10-03: cortar em "agora" deslogava o próprio aparelho, e a
  /// renovação abaixo não salvava, porque usa o mesmo refresh token).
  /// [garantirTokenPronto] continua garantindo um ID token fresco. Best-effort
  /// (nunca lança): chamada uma vez por login bem-sucedido, ver
  /// `LoginScreen._finalizarLoginComSucesso`.
  Future<void> revogarSessoesEmOutrosDispositivosEAtualizarToken() async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('revogarSessoesEmOutrosDispositivos')
          .call()
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('⚠️ [FirebaseAuthService] Falha ao revogar sessões em outros '
          'aparelhos (sessão antiga pode continuar ativa por mais tempo): $e');
      return; // Sem revogação, não há necessidade de renovar nada aqui.
    }
    await garantirTokenPronto();
  }
}
