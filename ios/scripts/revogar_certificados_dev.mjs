// Revoga certificados "Apple Development" antigos criados pelo CI, antes do
// archive do TestFlight (ver .github/workflows/ios-testflight.yml).
//
// Por quê: cada execução roda num Mac novo, sem chave privada no keychain, e
// a assinatura automática do xcodebuild (com a chave da App Store Connect
// API) cria um certificado Apple Development NOVO a cada archive. A conta tem
// um limite — no build de 04/10 o archive falhou com "Your account has
// reached the maximum number of certificates".
//
// Travas (nunca mexe em mais nada):
//   - só tipos DEVELOPMENT / IOS_DEVELOPMENT (NUNCA distribuição);
//   - só os criados pela chave da API ("Created via API");
//   - mantém o mais recente.
//
// Uso: node ios/scripts/revogar_certificados_dev.mjs
//   env KEY_ID, ISSUER_ID, KEY_PATH (.p8); DRY_RUN=1 só lista.
// Nunca derruba o build: qualquer falha vira aviso e sai com código 0.

import {readFileSync} from "node:fs";
import {createPrivateKey, sign} from "node:crypto";

const API = "https://api.appstoreconnect.apple.com/v1";
const TIPOS_PERMITIDOS = new Set(["DEVELOPMENT", "IOS_DEVELOPMENT"]);
const MARCA_API = "Created via API";

function base64url(dados) {
  return Buffer.from(dados).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function gerarJwt({keyId, issuerId, keyPath}) {
  const agora = Math.floor(Date.now() / 1000);
  const cabecalho = base64url(JSON.stringify({alg: "ES256", kid: keyId, typ: "JWT"}));
  const corpo = base64url(JSON.stringify({iss: issuerId, iat: agora, exp: agora + 15 * 60, aud: "appstoreconnect-v1"}));
  const chave = createPrivateKey(readFileSync(keyPath, "utf8"));
  const assinatura = sign("sha256", Buffer.from(`${cabecalho}.${corpo}`), {key: chave, dsaEncoding: "ieee-p1363"});
  return `${cabecalho}.${corpo}.${base64url(assinatura)}`;
}

async function listarCertificadosDev(token) {
  const lista = [];
  let url = `${API}/certificates?filter[certificateType]=${[...TIPOS_PERMITIDOS].join(",")}&limit=200`;
  while (url) {
    const r = await fetch(url, {headers: {Authorization: `Bearer ${token}`}});
    if (!r.ok) throw new Error(`listar certificados: HTTP ${r.status} ${await r.text()}`);
    const json = await r.json();
    lista.push(...json.data);
    url = json.links && json.links.next;
  }
  return lista;
}

const criadoPelaApi = (c) =>
  [c.attributes.displayName, c.attributes.name].some((n) => typeof n === "string" && n.includes(MARCA_API));

async function main() {
  const {KEY_ID: keyId, ISSUER_ID: issuerId, KEY_PATH: keyPath, DRY_RUN: dryRun} = process.env;
  if (!keyId || !issuerId || !keyPath) throw new Error("faltam KEY_ID, ISSUER_ID ou KEY_PATH");
  const token = gerarJwt({keyId, issuerId, keyPath});

  const todos = await listarCertificadosDev(token);
  const candidatos = todos
      .filter((c) => TIPOS_PERMITIDOS.has(c.attributes.certificateType))
      .filter(criadoPelaApi)
      .sort((a, b) => String(b.attributes.expirationDate).localeCompare(String(a.attributes.expirationDate)));

  console.log(`Certificados de desenvolvimento na conta: ${todos.length}; criados pela API: ${candidatos.length}.`);
  const [maisRecente, ...antigos] = candidatos;
  if (maisRecente) {
    console.log(`Mantido (mais recente): ${maisRecente.id} — vence em ${maisRecente.attributes.expirationDate}.`);
  }

  let revogados = 0;
  for (const c of antigos) {
    // Defesa extra: confere o tipo de novo antes de apagar.
    if (!TIPOS_PERMITIDOS.has(c.attributes.certificateType) || !criadoPelaApi(c)) continue;
    const descricao = `${c.id} (${c.attributes.certificateType}, ${c.attributes.displayName}, vence ${c.attributes.expirationDate})`;
    if (dryRun) {
      console.log(`[simulação] revogaria ${descricao}`);
      continue;
    }
    const r = await fetch(`${API}/certificates/${c.id}`, {method: "DELETE", headers: {Authorization: `Bearer ${token}`}});
    if (r.status === 204) {
      revogados++;
      console.log(`Revogado ${descricao}`);
    } else {
      console.log(`::warning::Não revogou ${descricao}: HTTP ${r.status} ${await r.text()}`);
    }
  }
  console.log(`Total de certificados de desenvolvimento revogados: ${revogados}.`);
}

main().catch((e) => {
  console.log(`::warning::Limpeza de certificados não concluída (o archive segue): ${e.message}`);
});
