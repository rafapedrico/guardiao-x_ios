// Configuração do Firebase para o projeto "guardiaox".
//
// O bloco `android` foi escrito à mão originalmente (ver histórico do
// repositório Android em `com.rmfglobal.guardiaox`/`alerta_de_seguranca`) e
// é mantido aqui EXATAMENTE como estava — esta cópia iOS nunca modifica o
// registro do app Android no Firebase Console, apenas reaproveita os
// mesmos valores já existentes.
//
// O bloco `ios` foi gerado por `flutterfire configure --platforms=ios`
// (2026-09-12), que registrou um app iOS NOVO e aditivo dentro do MESMO
// projeto Firebase "guardiaox" (project number 555863351772) — nenhum app
// Android existente foi alterado ou removido nesse processo.
library firebase_options;

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'DefaultFirebaseOptions não foi configurado para Web. '
        'Rode `flutterfire configure` para gerar as credenciais reais.',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions só foi configurado para Android e iOS '
          'neste projeto. Rode `flutterfire configure` para adicionar '
          'suporte a ${defaultTargetPlatform.name}.',
        );
    }
  }

  /// Extraído de android/app/google-services.json (projeto "guardiaox").
  ///
  /// CORREÇÃO DE BUG REAL (2026-09-06, auditoria de limpeza do login
  /// Google): `appId` apontava para `...1b76bbad7fe800e14def19`, o
  /// registro do pacote ANTIGO `com.example.security_check_app` (resíduo
  /// de antes do projeto ser renomeado, já removido do Firebase Console —
  /// ver `google-services.json`, que só tem `com.rmfglobal.guardiaox`
  /// agora). `apiKey`/`messagingSenderId`/`projectId`/`storageBucket` são
  /// idênticos entre os dois registros (mesmo projeto Firebase), por isso
  /// o app continuava funcionando apesar do `appId` errado — mas
  /// Analytics/Crashlytics/FCM atribuíam eventos ao app "fantasma" errado
  /// no Console. Corrigido para o `appId` real de `com.rmfglobal.guardiaox`.
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAD3cnaZu1w7EeBvgoazJYXnEd5nAP1R7M',
    appId: '1:555863351772:android:f8cdca1bbe926aa74def19',
    messagingSenderId: '555863351772',
    projectId: 'guardiaox',
    storageBucket: 'guardiaox.firebasestorage.app',
  );

  /// App iOS registrado em 2026-09-12 via `flutterfire configure
  /// --platforms=ios`, dentro do mesmo projeto Firebase "guardiaox" —
  /// aditivo, não substitui nem reconfigura o app Android acima.
  /// Bundle id `com.rmfglobal.guardiaox` (igual ao `applicationId`
  /// Android). `iosClientId`/`androidClientId` vêm do mesmo Client OAuth
  /// já usado pelo `google_sign_in` — necessário para o login social
  /// Google funcionar também no iOS.
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyByn-vSLAMomrLE2KrOLCLdO5QqyNzZwbg',
    appId: '1:555863351772:ios:9aa22f628e8209814def19',
    messagingSenderId: '555863351772',
    projectId: 'guardiaox',
    storageBucket: 'guardiaox.firebasestorage.app',
    androidClientId: '555863351772-0d6vepdg74rm4bqoqt2h30eobnjdcu2n.apps.googleusercontent.com',
    iosClientId: '555863351772-r65lv7u2r0mq6n9ocedjoesafglrld27.apps.googleusercontent.com',
    iosBundleId: 'com.rmfglobal.guardiaox',
  );
}
