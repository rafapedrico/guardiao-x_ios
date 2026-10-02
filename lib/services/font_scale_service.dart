import 'package:flutter/foundation.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serviço central para persistência e leitura do fator de escala de
/// fonte escolhido pelo usuário (acessibilidade visual). Segue o mesmo
/// padrão do [WallpaperService]: persiste no SharedPreferences e expõe
/// um [ValueNotifier] global para que TODAS as telas do app atualizem
/// o tamanho das letras instantaneamente assim que o usuário mudar a
/// preferência.
class FontScaleService {
  static const String prefsKey = 'fator_tamanho_fonte';

  // Valores sugeridos de fator de escala. Reduzidos em 2026-10-02 (1º
  // teste no iPhone: 1.3/1.6 estouravam vários layouts) — ver
  // [_migrarValoresAntigos].
  static const double pequeno = 1.0;
  static const double padrao = 1.15;
  static const double grande = 1.3;

  /// Versão da escala salva em [prefsKey]. Sem esta marca não daria para
  /// migrar: o antigo "Padrão" (1.3) tem o MESMO valor do novo "Grande".
  static const String _prefsVersaoKey = 'fator_tamanho_fonte_versao';
  static const int _versaoAtual = 2;

  static const double defaultValue = padrao;

  /// Notifica em tempo real qualquer widget que precise reagir à troca
  /// do tamanho da fonte (ex: MaterialApp via MediaQuery/TextScaler).
  static final ValueNotifier<double> fontScaleNotifier =
      ValueNotifier<double>(defaultValue);

  /// Deve ser chamado uma vez na inicialização do app (ex: main.dart)
  /// para carregar o valor persistido e popular o [fontScaleNotifier].
  static Future<void> inicializar() async {
    fontScaleNotifier.value = await carregar();
  }

  /// Salva o fator de escala escolhido e atualiza o [fontScaleNotifier]
  /// imediatamente, fazendo com que todo o app seja redesenhado com o
  /// novo tamanho de fonte na hora.
  static Future<void> salvar(double fator) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(prefsKey, fator);
    await prefs.setInt(_prefsVersaoKey, _versaoAtual);
    fontScaleNotifier.value = fator;
  }

  /// Recupera o fator salvo, ou o padrão caso não exista.
  static Future<double> carregar() async {
    final prefs = await SharedPreferences.getInstance();
    final double? salvo = prefs.getDouble(prefsKey);
    if (salvo == null) return defaultValue;
    if ((prefs.getInt(_prefsVersaoKey) ?? 1) >= _versaoAtual) return salvo;

    final double migrado = _migrarValoresAntigos(salvo);
    await prefs.setDouble(prefsKey, migrado);
    await prefs.setInt(_prefsVersaoKey, _versaoAtual);
    return migrado;
  }

  /// Escala v1 -> v2: 1.3 ("Padrão") vira 1.15 e 1.6 ("Grande") vira 1.3;
  /// 1.0 ("Pequeno") não muda. Qualquer outro valor cai no rótulo mais
  /// próximo da escala nova.
  static double _migrarValoresAntigos(double antigo) {
    if (antigo <= pequeno) return pequeno;
    if (antigo >= 1.6) return grande;
    if (antigo >= 1.3) return padrao;
    return antigo > padrao ? padrao : antigo;
  }

  /// Rótulo amigável para exibição na UI, de acordo com o fator atual —
  /// traduzido via [AppLocalizations], nunca hardcoded.
  static String rotuloPara(double fator, AppLocalizations l10n) {
    if (fator <= pequeno) return l10n.fontTamanhoPequeno;
    if (fator >= grande) return l10n.fontTamanhoGrande;
    return l10n.fontTamanhoPadrao;
  }
}
