import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Serviço de login social (Google e Apple) via Firebase Auth —
/// complementa [FirebaseAuthService] (e-mail/senha, ver
/// `lib/services/firebase_auth_service.dart`), sem alterar nada lá.
///
/// Facebook REMOVIDO em 2026-08-23 (decisão de arquitetura — reduzir
/// superfície de manutenção; o login social ficou restrito a provedores
/// que o próprio Firebase Auth garante e-mail verificado automaticamente).
///
/// CONTRATO comum aos 2 métodos, para a [LoginScreen] poder tratar ambos
/// da mesma forma:
/// - Retorna `null` quando o PRÓPRIO USUÁRIO cancela o fluxo (fechou o
///   seletor de conta Google, fechou a aba do Apple Sign In) — nunca
///   lança exceção só por cancelamento.
/// - Qualquer outra falha real (rede, configuração ausente/incorreta,
///   credencial rejeitada pelo Firebase) propaga a exceção original
///   (`FirebaseAuthException` ou a exceção nativa do respectivo plugin)
///   para quem chamou tratar/exibir.
///
/// NOTA DE CONFIGURAÇÃO (fora do escopo deste arquivo — exige acesso aos
/// consoles/contas de desenvolvedor do usuário, não só código):
/// - **Google**: precisa do SHA-1 (debug e release) da assinatura deste
///   app cadastrado no Firebase Console (Project Settings > app Android
///   "guardiaox") — sem isso o Google devolve `DEVELOPER_ERROR` mesmo com
///   o código 100% correto.
/// - **Apple**: "Sign in with Apple" exige Apple Developer Program (pago)
///   + um Services ID + um domínio/endpoint de redirect verificado — ver
///   [_appleWebAuthOptions] abaixo (hoje só placeholders). Sem isso o
///   botão abre a aba do navegador e falha no redirect de volta pro app.
///   Além disso (migração iOS, Guideline 4.8 da App Store): a revogação
///   do token na exclusão de conta (ver [signInWithApple]/
///   `appleSignInService.js`) exige uma chave "Sign in with Apple"
///   separada (Apple Developer → Keys) + os segredos `APPLE_TEAM_ID`/
///   `APPLE_SIWA_KEY_ID`/`APPLE_SIWA_PRIVATE_KEY` da Cloud Function —
///   ver `docs/checklist-final-mac-app-store-connect-2026-09-12.md`.
///
/// Tempo mínimo para um `GoogleSignInExceptionCode.canceled` ser tratado
/// como um cancelamento genuíno do usuário (ver [signInWithGoogle]) — um
/// `canceled` chegando depois disso é tratado como uma falha real
/// disfarçada (ex: rejeição OAuth do servidor após a conta já ter sido
/// escolhida), nunca como desistência silenciosa.
///
/// AJUSTADO (2026-09-06, medição ao vivo via `flutter run --release` no
/// Razr): o limiar original de 3s foi calibrado em cima de UMA variante
/// do erro OAuth ("not registered", ~4s de atraso) — uma variante
/// DIFERENTE do MESMO problema ("Invalid key value", SHA-1 não
/// propagado/cadastrado) resolveu bem mais rápido, entre 1,7s e 2,5s,
/// passando DIRETO pelo limiar antigo e voltando em silêncio de novo —
/// exatamente o bug que esta classe existe pra evitar. 1s cobre as duas
/// variantes já observadas com folga, mantendo margem segura acima de um
/// cancelamento genuíno de verdade (usuário fecha o seletor SEM escolher
/// nada — não dá tempo de nem completar `onUiEntrySelected`, muito mais
/// rápido que 1s).
const Duration _limiarCancelamentoGenuino = Duration(seconds: 1);

/// Lançada por [SocialAuthService.signInWithGoogle] quando o Android
/// reporta `GoogleSignInExceptionCode.canceled` tarde demais para ser um
/// cancelamento genuíno (ver [_limiarCancelamentoGenuino]) — carrega o
/// tempo decorrido e a exceção original só para diagnóstico; sempre
/// tratada pelo `catch` genérico de `LoginScreen._fazerLoginSocial`
/// (nunca por engano como um cancelamento silencioso).
class GoogleSignInCanceladoSuspeitoException implements Exception {
  GoogleSignInCanceladoSuspeitoException(this.decorrido, this.original);

  final Duration decorrido;
  final GoogleSignInException original;

  @override
  String toString() =>
      'O Google/Android reportou "cancelado" ${decorrido.inSeconds}s depois '
      'de uma conta já ter sido selecionada no seletor — tempo longo demais '
      'para ser uma desistência genuína do usuário. Provavelmente uma '
      'falha real de configuração OAuth (SHA-1/pacote não propagado no '
      'Google Cloud Console) sendo mascarada como cancelamento pelo '
      'Android/Credential Manager. Exceção original: $original';
}

/// Lançada por [SocialAuthService.signInWithGoogle] quando já existe uma
/// conta (normalmente e-mail/senha) com o MESMO e-mail desta conta Google
/// — ver documentação completa no ponto onde é lançada. [credencialGoogle]
/// é o credential JÁ MONTADO a partir do idToken do Google, pronto para
/// `linkWithCredential` assim que a identidade for confirmada pela senha
/// da conta existente (ver `LoginScreen._exibirDialogoVincularContaGoogle`).
class ContaGoogleParaVincularException implements Exception {
  ContaGoogleParaVincularException(this.email, this.credencialGoogle);

  final String email;
  final OAuthCredential credencialGoogle;

  @override
  String toString() =>
      'Já existe uma conta com senha para $email — confirme a senha dela '
      'para vincular esta conta Google.';
}

class SocialAuthService {
  SocialAuthService._internal();
  static final SocialAuthService _instance = SocialAuthService._internal();
  factory SocialAuthService() => _instance;

  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ================================================================
  // GOOGLE
  // ================================================================

  /// `true` assim que [GoogleSignIn.instance.initialize] for chamado com
  /// sucesso pela primeira vez — a API 7.x exige essa chamada ANTES de
  /// qualquer outro método da instância singleton, e chamá-la de novo a
  /// cada tentativa de login seria redundante (a própria instância já é
  /// reaproveitada entre chamadas).
  bool _googleSignInInicializado = false;

  /// Client ID OAuth do tipo "Web" (client_type 3) do projeto Firebase
  /// "guardiaox" — ver `android/app/google-services.json`. CORREÇÃO
  /// (bug real diagnosticado em teste, 2026-08-10): diferente da API
  /// 6.x (que resolvia isso sozinha a partir do google-services.json),
  /// a 7.x EXIGE esse valor explicitamente em Android
  /// (`GoogleSignInExceptionCode.clientConfigurationError: serverClientId
  /// must be provided on Android` — erro real observado em teste). Tem
  /// que ser o client ID do tipo Web (não o Android), pois é a
  /// audiência que o Firebase espera ao validar o idToken em
  /// `GoogleAuthProvider.credential`.
  static const String _googleServerClientId =
      '555863351772-vrlhh2c4kv0a1ci7eu34i36rq5jro327.apps.googleusercontent.com';

  /// CORREÇÃO (bug real diagnosticado em teste, 2026-08-10 — login com
  /// Google travando indefinidamente, sem erro nenhum): migrado da API
  /// "clássica" (`GoogleSignIn().signIn()`, removida/descontinuada em
  /// runtime pelo próprio Play Services) para a API 7.x baseada em
  /// Credential Manager — instância singleton (`GoogleSignIn.instance`),
  /// `initialize()` obrigatório antes de qualquer chamada, e
  /// `authenticate()` no lugar de `signIn()`. Autenticação (identidade,
  /// `idToken`) e autorização (`accessToken`/escopos, via
  /// `authorizationClient`) agora são passos SEPARADOS — o Firebase só
  /// precisa do `idToken` para `GoogleAuthProvider.credential` (mesmo
  /// padrão da documentação oficial do FlutterFire).
  ///
  /// SEGUNDO BUG REAL (2026-08-11, aparelho Android 9/API 28 mais
  /// antigo — "moto g7 play"): mesmo a API 7.x/Credential Manager pode
  /// ficar PENDURADA para sempre em `authenticate()` (nem sucesso, nem
  /// exceção) quando o Google Play Services do aparelho está
  /// desatualizado/não suporta bem o Credential Manager — o botão fica
  /// girando indefinidamente, EXATAMENTE o mesmo sintoma do bug original
  /// de App Check (ver `main.dart`), só que num ponto diferente do
  /// fluxo. `.timeout(...)` aqui NÃO conserta o Credential Manager do
  /// aparelho (isso é uma limitação de SO/Play Services fora do
  /// controle deste app), mas garante que o usuário sempre receba um
  /// erro claro (capturado pelo `catch` genérico de
  /// [LoginScreen._fazerLoginSocial]) em vez de um spinner infinito sem
  /// nenhum feedback.
  /// CORREÇÃO (2026-09-05, pedido explícito do usuário — "login com Google
  /// falhando silenciosamente no app baixado da Play Store: é acionado,
  /// mas não abre o seletor de contas e não mostra nenhum erro"): cada
  /// etapa agora tem seu PRÓPRIO try/catch, só para `debugPrint` — nunca
  /// muda o TIPO da exceção relançada (a UI, ver
  /// `LoginScreen._fazerLoginSocial`/`_mensagemErroLoginSocial`, continua
  /// tratando `FirebaseAuthException`/`GoogleSignInException` exatamente
  /// como antes) — só identifica em qual das 4 etapas a falha aconteceu,
  /// ANTES de propagar. Combinado com a mudança em `LoginScreen`, que
  /// agora exibe o texto EXATO de `e.toString()` (+ stack trace completo)
  /// num diálogo (com botão "Copiar"), em vez de só a mensagem genérica —
  /// essencial para diagnosticar remotamente uma falha que só reproduz em
  /// produção (assinatura/SHA de release, Play Services desatualizado,
  /// etc.), sem acesso a logcat do aparelho do usuário.
  ///
  /// IMPORTANTE — cada `rethrow` abaixo é OBRIGATÓRIO, nunca remover: é
  /// ele que propaga a exceção até `LoginScreen._fazerLoginSocial`, onde
  /// o diálogo de erro é exibido. Removê-lo faria o erro morrer
  /// silenciosamente aqui dentro — exatamente o sintoma original que esta
  /// correção existe para resolver.
  Future<UserCredential?> signInWithGoogle() async {
    if (!_googleSignInInicializado) {
      try {
        await GoogleSignIn.instance
            .initialize(serverClientId: _googleServerClientId)
            .timeout(const Duration(seconds: 15));
        _googleSignInInicializado = true;
      } catch (e, s) {
        debugPrint('❌ [SocialAuthService] Etapa 1/4 (initialize) falhou: $e\n$s');
        rethrow;
      }
    }

    final GoogleSignInAccount googleUser;
    final cronometro = Stopwatch()..start();
    try {
      googleUser = await GoogleSignIn.instance
          .authenticate()
          .timeout(const Duration(seconds: 45));
    } on GoogleSignInException catch (e) {
      // CORREÇÃO DE BUG REAL (2026-09-06, pedido explícito do usuário —
      // "seleciona a conta e volta silenciosamente pra tela de login, sem
      // avançar nem mostrar erro"): um cancelamento GENUÍNO (o usuário
      // fecha o seletor de contas sem escolher nada) é praticamente
      // instantâneo. Confirmado via logcat ao vivo (Razr, 2026-09-05): o
      // mesmo `DEVELOPER_ERROR`/"not registered to use OAuth2.0" que já
      // vínhamos caçando pode acontecer DEPOIS que o usuário já escolheu
      // uma conta de verdade — e o Android/Credential Manager, em vez de
      // propagar esse erro real, encerra a sessão e reporta pro plugin
      // como `GoogleSignInExceptionCode.canceled` (mesmo código de uma
      // desistência genuína), fazendo nosso `return null` de baixo (que
      // deliberadamente nunca mostra nada, por contrato — ver
      // documentação do cabeçalho da classe) mascarar uma falha real como
      // se fosse uma simples desistência do usuário.
      //
      // Como não há como diferenciar os dois casos pelo `code` sozinho,
      // usa o TEMPO decorrido como heurística: `canceled` chegando bem
      // depois do início (usuário claramente já interagiu com o seletor)
      // é tratado como uma falha disfarçada, não um cancelamento — exibe
      // o diálogo de erro em vez de voltar em silêncio.
      debugPrint('❌ [SocialAuthService] Etapa 2/4 (authenticate) — código: '
          '${e.code}, descrição: ${e.description}, decorrido: ${cronometro.elapsedMilliseconds}ms');
      if (e.code == GoogleSignInExceptionCode.canceled) {
        if (cronometro.elapsed < _limiarCancelamentoGenuino) {
          return null; // Cancelamento rápido — genuinamente o usuário desistiu.
        }
        throw GoogleSignInCanceladoSuspeitoException(cronometro.elapsed, e);
      }
      rethrow;
    } catch (e, s) {
      // Cobre principalmente o `TimeoutException` dos 45s (ver histórico
      // documentado acima: Credential Manager pendurado para sempre em
      // aparelhos com Play Services desatualizado) e qualquer
      // `PlatformException` nativa não modelada como `GoogleSignInException`.
      debugPrint('❌ [SocialAuthService] Etapa 2/4 (authenticate) falhou '
          '(${e.runtimeType}): $e\n$s');
      rethrow;
    }

    final String? idToken;
    try {
      idToken = googleUser.authentication.idToken;
    } catch (e, s) {
      debugPrint('❌ [SocialAuthService] Etapa 3/4 (ler idToken) falhou: $e\n$s');
      rethrow;
    }
    // Defensivo: `idToken` é nullable no plugin (`GoogleSignInAuthentication`,
    // ver `google_sign_in` 7.x) — na prática só deveria vir nulo se o
    // `serverClientId` estiver mal configurado ou o Google devolver uma
    // resposta incompleta. Sem esta checagem, `GoogleAuthProvider.credential`
    // seguiria adiante com `idToken: null` e o Firebase falharia mais
    // abaixo com um erro genérico difícil de diagnosticar — melhor
    // sinalizar aqui, no ponto exato da causa.
    if (idToken == null) {
      debugPrint('❌ [SocialAuthService] Etapa 3/4 (ler idToken) falhou: '
          'idToken nulo (serverClientId mal configurado ou resposta '
          'incompleta do Google) — conta: ${googleUser.email}.');
      throw FirebaseAuthException(
        code: 'invalid-credential',
        message: 'O Google não retornou um idToken válido para esta conta.',
      );
    }

    final OAuthCredential credential = GoogleAuthProvider.credential(idToken: idToken);
    try {
      return await _auth.signInWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      debugPrint('❌ [SocialAuthService] Etapa 4/4 (signInWithCredential) '
          'falhou: ${e.code} — ${e.message}');
      // CORREÇÃO (2026-09-06, pedido explícito do usuário — "se tentar
      // logar de um telefone novo vai dar aviso de que este e-mail já
      // está sendo usado... precisamos da recuperação, com confirmação
      // de e-mail para garantir que o usuário é o real"): este código
      // específico significa que já existe uma conta (normalmente
      // e-mail/senha, criada em [CadastroScreen]) com o MESMO e-mail
      // desta conta Google — o Firebase recusa a autenticação direta por
      // segurança (não funde contas de provedores diferentes sozinho).
      // `e.email` + `e.credential` (aqui, o [credential] que acabamos de
      // montar) são exatamente o par que a própria documentação do
      // Firebase Auth prevê para RESOLVER isso — ver
      // [ContaGoogleParaVincularException], tratada por
      // `LoginScreen._exibirDialogoVincularContaGoogle`: pede a SENHA da
      // conta existente (prova real de identidade — não é "recuperação
      // automática só por dizer o e-mail") e, uma vez confirmada, vincula
      // este credential do Google a ela via `linkWithCredential` — depois
      // disso, os dois métodos funcionam nessa MESMA conta.
      if (e.code == 'account-exists-with-different-credential' && e.email != null) {
        throw ContaGoogleParaVincularException(e.email!, credential);
      }
      rethrow;
    } catch (e, s) {
      debugPrint('❌ [SocialAuthService] Etapa 4/4 (signInWithCredential) '
          'falhou (${e.runtimeType}): $e\n$s');
      rethrow;
    }
  }

  // ================================================================
  // UTILITÁRIO DE DIAGNÓSTICO/TESTE
  // ================================================================

  /// Encerra qualquer sessão/cache LOCAL de login social (Google +
  /// Firebase) — usado pelo botão de diagnóstico da [LoginScreen] (pedido
  /// do usuário, 2026-08-10, para poder testar o login do zero sem
  /// reaproveitar uma conta/sessão já em cache no aparelho).
  ///
  /// [GoogleSignIn.disconnect] é mais completo que [GoogleSignIn.signOut]:
  /// além de encerrar a sessão, REVOGA o acesso concedido e limpa por
  /// completo a conta lembrada localmente pelo plugin — sem isso, o
  /// próximo toque no botão do Google pode pular direto para a MESMA
  /// conta de antes (sign-in silencioso) em vez de mostrar o seletor de
  /// contas de novo. Best-effort: nunca lança exceção (cada etapa é
  /// independente e protegida, mesmo que a conta já esteja desconectada).
  Future<void> encerrarSessoesSociais() async {
    try {
      if (!_googleSignInInicializado) {
        await GoogleSignIn.instance.initialize(serverClientId: _googleServerClientId);
        _googleSignInInicializado = true;
      }
    } catch (_) {}
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    try {
      await GoogleSignIn.instance.disconnect();
    } catch (_) {}
    try {
      await _auth.signOut();
    } catch (_) {}
  }

  // ================================================================
  // APPLE
  // ================================================================

  /// Services ID + redirect da configuração "Sign in with Apple" feita no
  /// Apple Developer (developer.apple.com > Certificates, IDs & Profiles >
  /// Identifiers > Services IDs) — OBRIGATÓRIO no Android/Web: diferente
  /// do iOS nativo, aqui o plugin abre um fluxo OAuth via Chrome Custom
  /// Tab que precisa saber para onde voltar. PLACEHOLDERS — substitua
  /// pelos valores reais do Apple Developer Program antes de publicar.
  static final WebAuthenticationOptions _appleWebAuthOptions =
      WebAuthenticationOptions(
    clientId: 'com.example.security_check_app.signin',
    redirectUri: Uri.parse(
      'https://guardiaox.firebaseapp.com/__/auth/handler',
    ),
  );

  /// Mesmo bundle id do app iOS (ver `ios/Runner.xcodeproj`, Fase 0 da
  /// migração) — `client_id` correto para o backend trocar o
  /// `authorizationCode` do fluxo NATIVO (iOS/macOS) por um
  /// refresh_token (ver [signInWithApple]/`appleSignInService.js`). O
  /// fluxo web/Android usa [_appleWebAuthOptions.clientId] (Services ID)
  /// em vez deste valor.
  static const String _appleBundleId = 'com.rmfglobal.guardiaox';

  Future<UserCredential?> signInWithApple() async {
    // Nonce aleatório: gerado localmente (helper oficial do próprio
    // pacote), hasheado (SHA-256) e enviado na REQUISIÇÃO à Apple; a Apple
    // embute o hash dentro do `identityToken` (JWT) devolvido, e o
    // Firebase exige o valor CRU (`rawNonce`) na credencial pra provar que
    // o token não foi reaproveitado (proteção contra replay attack).
    // Usar outro campo (como `state`) no lugar do rawNonce real faz o
    // Firebase rejeitar o login com `auth/invalid-credential`.
    final String rawNonce = generateNonce();
    final String nonceHasheado =
        sha256.convert(utf8.encode(rawNonce)).toString();

    final AuthorizationCredentialAppleID appleCredential;
    try {
      appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: nonceHasheado,
        webAuthenticationOptions: _appleWebAuthOptions,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        return null; // Cancelado pelo usuário
      }
      rethrow;
    }

    final String? identityToken = appleCredential.identityToken;
    if (identityToken == null) return null;

    final OAuthCredential credential = OAuthProvider('apple.com').credential(
      idToken: identityToken,
      rawNonce: rawNonce,
    );
    final userCredential = await _auth.signInWithCredential(credential);

    // MIGRAÇÃO iOS — Guideline 4.8 da App Store (achado no checklist
    // final, 2026-09-12): registra o `authorizationCode` desta
    // autorização no backend (ver `appleSignInService.js`), que o troca
    // por um refresh_token para poder revogá-lo de verdade se o usuário
    // excluir a conta depois (ver `ExclusaoContaService`/
    // `exclusaoContaService.js`). Fire-and-forget, DEPOIS do login já
    // ter sido concluído com sucesso acima — nunca atrasa nem faz o
    // login falhar se o registro em si der errado (best-effort também
    // do lado do backend, ver documentação completa lá).
    unawaited(_registrarAutorizacaoApple(appleCredential.authorizationCode));

    return userCredential;
  }

  /// Ver documentação completa da chamada em [signInWithApple]. Nunca
  /// lança exceção — qualquer falha (rede, backend indisponível) só é
  /// logada; o usuário já está logado normalmente de qualquer forma.
  Future<void> _registrarAutorizacaoApple(String authorizationCode) async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('registrarAutorizacaoApple')
          .call<Map<String, dynamic>>({
        'authorizationCode': authorizationCode,
        // Fluxo nativo (iOS/macOS) usa o bundle id como client_id; fluxo
        // web (Android, via Chrome Custom Tab) usa o Services ID
        // configurado em [_appleWebAuthOptions] — a Apple recusa a
        // troca por refresh_token se o client_id não bater com o que
        // originou o authorizationCode.
        'clientId': Platform.isIOS ? _appleBundleId : _appleWebAuthOptions.clientId,
      });
    } catch (e) {
      debugPrint('⚠️ [SocialAuthService] Falha ao registrar autorização Apple '
          '(revogação na exclusão de conta pode não funcionar depois): $e');
    }
  }
}
