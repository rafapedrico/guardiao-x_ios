import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:uuid/uuid.dart';

import 'firebase_auth_service.dart';

/// Eventos best-effort emitidos por [PremiumPurchaseService.eventos] —
/// só para a UI reagir (loading/snackbar/diálogo de erro etc.). NUNCA a
/// fonte de verdade sobre se o usuário É Premium — isso continua sendo
/// exclusivamente [PlanoCicloService] (`isPremium` em `usuarios/{uid}`
/// no Firestore, só gravável pelo Admin SDK).
enum PremiumCompraEvento { pendente, concedida, semDireito, erro, erroValidacao, cancelada }

/// Serviço responsável pelo fluxo REAL de compra da assinatura mensal do
/// Plano Premium via Google Play Billing — fecha a lacuna documentada em
/// [PremiumPriceService] (que só consultava o PREÇO exibido na tela,
/// nunca comprava de fato) e em `functions/planoCicloService.js` (não
/// existia, neste projeto, nenhuma verificação de recibo de compra).
///
/// FLUXO COMPLETO:
/// 1. [comprarPremium] dispara `InAppPurchase.buyNonConsumable` — mesmo
///    para assinaturas: o plugin `in_app_purchase` não tem um
///    `buySubscription` separado, `buyNonConsumable` é o método correto
///    também para produtos do tipo `subs` no Play Billing.
/// 2. O RESULTADO não vem do retorno de [comprarPremium] (que só
///    confirma que a UI nativa de pagamento foi aberta) — chega depois,
///    de forma ASSÍNCRONA, pelo `purchaseStream` do plugin. [iniciar]
///    assina esse stream uma única vez, no boot do app (ver
///    `main.dart::iniciarServicosPosLoginOuDashboard`), nunca a partir de
///    um widget: a tela que abriu a compra pode não existir mais quando
///    o resultado chegar.
/// 3. Toda compra em estado `purchased`/`restored` é enviada à Cloud
///    Function `validarCompraPremium`, que consulta a Play Developer API
///    de verdade antes de conceder `isPremium` (ver
///    `functions/premiumPurchaseService.js`) — o cliente NUNCA decide
///    sozinho que uma compra é válida.
/// 4. [InAppPurchase.completePurchase] é chamado ao final de QUALQUER
///    desfecho (sucesso, sem direito, erro, cancelamento) sempre que
///    `pendingCompletePurchase` indicar que é necessário — obrigatório
///    pelo Play Billing: uma compra não confirmada em até 3 dias é
///    automaticamente estornada pelo Google.
///
/// MIGRAÇÃO iOS (Fase 5, 2026-09-12): o fluxo acima (`buyNonConsumable`
/// + `purchaseStream` + validação no backend) já era 100% cross-platform
/// — só [comprarPremium] precisou de um ramo iOS de verdade (ver
/// [_kNamespaceAppAccountToken] abaixo). A validação no backend passou a
/// consultar a App Store Server API da Apple (biblioteca oficial
/// `@apple/app-store-server-library`) em vez da Play Developer API
/// quando `platform: 'ios'` — ver `functions/premiumPurchaseService.js`.
/// **Não testado contra a App Store de verdade** (sem Mac/conta Apple
/// Developer neste ambiente) — recomendado testar no Sandbox da Apple
/// antes de liberar para usuários reais.
class PremiumPurchaseService {
  PremiumPurchaseService._internal();
  static final PremiumPurchaseService _instance = PremiumPurchaseService._internal();
  factory PremiumPurchaseService() => _instance;

  /// Id do produto de assinatura mensal cadastrado no Play Console
  /// (Monetise > Products > Subscriptions) — precisa ser EXATAMENTE
  /// este id lá. Mesmo id usado em [PremiumPriceService] (consulta de
  /// preço) e em `functions/premiumPurchaseService.js` (validação).
  static const String idProdutoPremium = 'assinatura_mensal';

  /// Namespace fixo usado para derivar um `appAccountToken` UUID v5
  /// DETERMINÍSTICO a partir do uid do Firebase (ver [comprarPremium]) —
  /// StoreKit 2 exige um UUID de verdade nesse campo; passar o uid puro
  /// (uma string arbitrária) faz a Apple descartá-lo SILENCIOSAMENTE,
  /// deixando `appAccountToken` nulo do lado do backend (bug real e
  /// documentado do plugin — ver issues do `flutter/flutter` sobre
  /// `appAccountToken` retornando null). MESMO valor, hardcoded de forma
  /// idêntica, em `functions/premiumPurchaseService.js`
  /// (`NAMESPACE_APP_ACCOUNT_TOKEN`) — NUNCA alterar depois da primeira
  /// compra real no iOS, ou a checagem antifraude do backend para de
  /// bater com uids que já compraram.
  static const String _kNamespaceAppAccountToken =
      '0ab5674b-b258-4492-9068-4e0fdf0c98ef';

  StreamSubscription<List<PurchaseDetails>>? _subscricao;
  bool _iniciado = false;

  final StreamController<PremiumCompraEvento> _eventosController =
      StreamController<PremiumCompraEvento>.broadcast();

  /// Stream best-effort para a UI (loading/snackbar/diálogo) reagir aos
  /// desfechos da compra — perder um listener aqui (tela fechada no meio
  /// do fluxo) nunca afeta o resultado real, que já foi ou será
  /// processado de qualquer forma pelo `purchaseStream` nativo.
  Stream<PremiumCompraEvento> get eventos => _eventosController.stream;

  /// Assina o `purchaseStream` do plugin — deve ser chamado UMA única
  /// vez por sessão do engine, no boot do app. Idempotente (chamadas
  /// repetidas são ignoradas).
  void iniciar() {
    if (_iniciado) return;
    _iniciado = true;

    _subscricao = InAppPurchase.instance.purchaseStream.listen(
      _aoReceberAtualizacoesDeCompra,
      onError: (Object erro) {
        debugPrint('⚠️ [PremiumPurchaseService] Erro no purchaseStream: $erro');
      },
    );

    // Rejoga (pelo MESMO purchaseStream acima) qualquer compra que o
    // usuário já possui mas cuja validação com o backend não tenha sido
    // concluída ainda (ex: uma chamada anterior a `validarCompraPremium`
    // falhou por falta de rede, ou o app foi fechado/morto entre o
    // pagamento e a validação) — mesma filosofia de retry automático já
    // usada em `RetryUploadService` no resto do app: nunca exigir que o
    // usuário perceba/reporte manualmente que "pagou mas não recebeu".
    // Best-effort — uma falha aqui só adia a próxima tentativa para o
    // próximo boot, nunca trava o app.
    unawaited(
      InAppPurchase.instance.restorePurchases().catchError((Object e) {
        debugPrint('⚠️ [PremiumPurchaseService] restorePurchases() falhou (não crítico): $e');
      }),
    );
  }

  /// Cancela a assinatura ao `purchaseStream` — só para testes/cleanup;
  /// nunca chamado no fluxo normal do app (o serviço vive pela sessão
  /// inteira do engine).
  void encerrar() {
    _subscricao?.cancel();
    _subscricao = null;
    _iniciado = false;
  }

  /// Dispara a compra da assinatura mensal do Plano Premium. Retorna
  /// `false` sem abrir nada se não houver sessão, a loja estiver
  /// indisponível ou o produto não for encontrado (mesmo tratamento
  /// permissivo/silencioso de [PremiumPriceService]) — o CHAMADOR decide
  /// se quer mostrar algum feedback nesses casos (ex: manter o texto
  /// genérico já exibido).
  ///
  /// O resultado da compra em si NÃO vem do retorno deste método — ver
  /// documentação da classe.
  Future<bool> comprarPremium() async {
    final String? uid = FirebaseAuthService().uidAtual;
    if (uid == null) {
      debugPrint('⚠️ [PremiumPurchaseService] Sem sessão autenticada — compra cancelada.');
      return false;
    }

    final bool disponivel = await InAppPurchase.instance.isAvailable();
    if (!disponivel) {
      debugPrint('⚠️ [PremiumPurchaseService] Loja indisponível neste aparelho/conta.');
      return false;
    }

    final ProductDetailsResponse resposta =
        await InAppPurchase.instance.queryProductDetails({idProdutoPremium});
    if (resposta.error != null || resposta.productDetails.isEmpty) {
      debugPrint(
          '⚠️ [PremiumPurchaseService] Produto "$idProdutoPremium" indisponível na loja '
          '(erro: ${resposta.error}, notFoundIDs: ${resposta.notFoundIDs}).');
      return false;
    }

    final ProductDetails produto = resposta.productDetails.first;

    // ANTI-FRAUDE (ver documentação completa em
    // `functions/premiumPurchaseService.js::validarCompraPremium`):
    // amarra esta compra ao uid do Firebase de quem está comprando AGORA
    // — sem isso, um único purchaseToken/transação válida poderia, em
    // tese, ser reenviado por outras contas Firebase para reivindicar o
    // mesmo Premium de graça.
    //
    // Android: `GooglePlayPurchaseParam.applicationUserName` aceita
    // qualquer string — o uid puro é enviado direto como
    // `obfuscatedAccountId`.
    //
    // iOS: StoreKit 2 exige um UUID de verdade no campo equivalente
    // (`appAccountToken`) — ver [_kNamespaceAppAccountToken]. Derivado de
    // forma DETERMINÍSTICA a partir do uid (UUID v5, RFC 4122), nunca
    // um UUID aleatório: assim o backend recalcula o MESMO valor a
    // partir do uid autenticado da chamada, sem precisar de nenhum
    // registro/round-trip prévio antes da compra.
    final PurchaseParam purchaseParam = Platform.isAndroid
        ? GooglePlayPurchaseParam(productDetails: produto, applicationUserName: uid)
        : PurchaseParam(
            productDetails: produto,
            applicationUserName: const Uuid().v5(_kNamespaceAppAccountToken, uid),
          );

    try {
      await InAppPurchase.instance.buyNonConsumable(purchaseParam: purchaseParam);
      return true;
    } catch (e) {
      debugPrint('⚠️ [PremiumPurchaseService] Falha ao iniciar a compra: $e');
      return false;
    }
  }

  Future<void> _aoReceberAtualizacoesDeCompra(List<PurchaseDetails> compras) async {
    for (final PurchaseDetails compra in compras) {
      // Outro produto (não deveria existir nenhum outro configurado
      // neste app, mas nunca custa ser explícito) — ignora e nem sequer
      // completa, para não interferir em nenhum outro fluxo de compra.
      if (compra.productID != idProdutoPremium) continue;

      switch (compra.status) {
        case PurchaseStatus.pending:
          debugPrint('⏳ [PremiumPurchaseService] Compra pendente (aguardando confirmação)...');
          _eventosController.add(PremiumCompraEvento.pendente);
          break;

        case PurchaseStatus.error:
          debugPrint('❌ [PremiumPurchaseService] Erro na compra: ${compra.error}');
          _eventosController.add(PremiumCompraEvento.erro);
          break;

        case PurchaseStatus.canceled:
          debugPrint('🚫 [PremiumPurchaseService] Compra cancelada pelo usuário.');
          _eventosController.add(PremiumCompraEvento.cancelada);
          break;

        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _validarEConceder(compra);
          break;
      }

      // OBRIGATÓRIO pelo Play Billing: sem isso, a compra fica "pendente
      // de confirmação" indefinidamente e o Google a reembolsa
      // automaticamente em até 3 dias. Chamado em TODO desfecho acima
      // (sucesso, sem direito, erro, cancelamento) sempre que o plugin
      // sinalizar que é necessário — nunca condicionado a nada ter dado
      // certo (ver [_validarEConceder]: mesmo uma falha de rede na
      // validação completa a compra do lado do Play Billing; a
      // recuperação para esse caso é o `restorePurchases()` no próximo
      // boot, ver [iniciar]).
      if (compra.pendingCompletePurchase) {
        await InAppPurchase.instance.completePurchase(compra);
      }
    }
  }

  Future<void> _validarEConceder(PurchaseDetails compra) async {
    try {
      final HttpsCallableResult<dynamic> resultado = await FirebaseFunctions.instance
          .httpsCallable('validarCompraPremium')
          .call(<String, dynamic>{
        // No iOS (StoreKit 2/`in_app_purchase_storekit`), este campo é a
        // JWS assinada da transação (`jwsRepresentation`) — o backend
        // verifica a assinatura direto com a App Store Server API, em
        // vez de um token opaco como no Android.
        'purchaseToken': compra.verificationData.serverVerificationData,
        'productId': compra.productID,
        'platform': Platform.isIOS ? 'ios' : 'android',
      });

      final Map<dynamic, dynamic>? dados = resultado.data as Map<dynamic, dynamic>?;
      final bool isPremium = dados?['isPremium'] == true;

      if (isPremium) {
        debugPrint('✅ [PremiumPurchaseService] Premium validado e concedido com sucesso.');
        _eventosController.add(PremiumCompraEvento.concedida);
      } else {
        debugPrint(
            '⚠️ [PremiumPurchaseService] Compra validada mas sem direito a Premium agora '
            '(estado: ${dados?['subscriptionState']}).');
        _eventosController.add(PremiumCompraEvento.semDireito);
      }
    } catch (e) {
      // Falha de REDE/BACKEND ao validar — a compra JÁ foi feita de
      // verdade na Play Store (o pagamento já ocorreu do lado do
      // Google), então isto NÃO significa que a compra falhou. A
      // recuperação automática para este caso é o `restorePurchases()`
      // chamado a cada boot em [iniciar], que rejoga esta mesma compra
      // pelo purchaseStream até a validação finalmente ter sucesso.
      debugPrint('⚠️ [PremiumPurchaseService] Falha ao validar a compra com o backend: $e');
      _eventosController.add(PremiumCompraEvento.erroValidacao);
    }
  }
}
