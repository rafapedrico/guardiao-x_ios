import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

/// Nome e telefone escolhidos na agenda (telefone como veio da agenda,
/// sem normalizar — cada chamador normaliza do seu jeito).
class ContatoDaAgenda {
  const ContatoDaAgenda({required this.nome, required this.telefone});

  final String nome;
  final String telefone;
}

/// "Adicionar Contato da Agenda" — compartilhado pela aba Monitoramento e
/// pelos contatos de emergência (Configurações).
///
/// Usa o nome e os telefones que vêm NO RESULTADO do seletor nativo: no
/// iOS, o `CNContactPickerViewController` dá acesso pontual ao contato
/// escolhido mesmo com Contatos em "Acesso Limitado". Antes, o fluxo
/// relia o contato com `FlutterContacts.get(id)`, que devolve `null` para
/// contatos fora da lista liberada — e nada era preenchido. `get()` agora
/// é só complemento: se devolver `null`, seguem os dados do seletor.
///
/// Com mais de um telefone, pergunta qual usar. Devolve `null` se o
/// usuário cancelar ou se não houver telefone (já avisado aqui).
Future<ContatoDaAgenda?> escolherContatoDaAgenda(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final mensageiro = ScaffoldMessenger.of(context);

  final status = await FlutterContacts.permissions.request(PermissionType.read);
  final bool permitido = status == PermissionStatus.granted || status == PermissionStatus.limited;
  if (!permitido) {
    mensageiro.showSnackBar(
      SnackBar(
        content: Text(l10n.contatosPermissaoNegada),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.redAccent,
      ),
    );
    return null;
  }

  Contact? escolhido;
  try {
    escolhido = await FlutterContacts.native.showPicker(properties: {ContactProperty.phone});
  } catch (_) {
    escolhido = null;
  }
  if (escolhido == null) return null; // cancelou

  var nome = (escolhido.displayName ?? '').trim();
  var telefones = _telefonesDistintos(escolhido.phones);

  // Complemento: só quando o seletor não trouxe o que precisamos.
  final id = escolhido.id;
  if ((telefones.isEmpty || nome.isEmpty) && id != null) {
    try {
      final completo = await FlutterContacts.get(id, properties: {ContactProperty.phone});
      if (completo != null) {
        if (nome.isEmpty) nome = (completo.displayName ?? '').trim();
        if (telefones.isEmpty) telefones = _telefonesDistintos(completo.phones);
      }
    } catch (_) {
      // Fora da lista liberada / sem permissão: segue com o do seletor.
    }
  }

  if (telefones.isEmpty) {
    mensageiro.showSnackBar(
      SnackBar(content: Text(l10n.contatoSemTelefone), behavior: SnackBarBehavior.floating),
    );
    return null;
  }

  Phone? telefone = telefones.first;
  if (telefones.length > 1) {
    if (!context.mounted) return null;
    telefone = await showDialog<Phone>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(l10n.contatoEscolherTelefone(nome.isNotEmpty ? nome : telefones.first.number)),
        children: [
          for (final t in telefones)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(t),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.phone_outlined, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.number, style: const TextStyle(fontSize: 15)),
                        if (_rotulo(t) case final rotulo?)
                          Text(rotulo, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (telefone == null) return null; // fechou sem escolher
  }

  return ContatoDaAgenda(nome: nome, telefone: telefone.number);
}

/// Sem repetidos (o mesmo número com formatação diferente conta uma vez).
List<Phone> _telefonesDistintos(List<Phone> telefones) {
  final vistos = <String>{};
  final lista = <Phone>[];
  for (final t in telefones) {
    final digitos = t.number.replaceAll(RegExp(r'\D'), '');
    if (digitos.isEmpty || !vistos.add(digitos)) continue;
    lista.add(t);
  }
  return lista;
}

/// Rótulo personalizado da agenda ("Trabalho", "Casa"…), quando houver.
String? _rotulo(Phone telefone) {
  final custom = telefone.label.customLabel?.trim();
  return (custom == null || custom.isEmpty) ? null : custom;
}
