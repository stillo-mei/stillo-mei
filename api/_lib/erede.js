// Integração Pix com a e.Rede (Rede Itaú).
// Baseado no manual de integração e.Rede (Portal do Desenvolvedor Rede):
//   POST /v1/transactions  { kind: "Pix", reference, amount, qrCode: { dateTimeExpiration } }
//   GET  /v1/transactions/{tid}  -> authorization.status ("Approved" quando pago)
// IMPORTANTE: confirme nomes de campos e o tipo de autenticação no Portal do Desenvolvedor
// da Rede antes de ir para produção. Tudo o que pode variar está em variáveis de ambiente
// e a resposta bruta de cada chamada fica gravada na tabela "pagamentos" para conferência.

const AMBIENTE = (process.env.EREDE_AMBIENTE || "sandbox").toLowerCase();
const BASE = process.env.EREDE_BASE_URL ||
  (AMBIENTE === "producao" ? "https://api.userede.com.br/erede/v1" : "https://sandbox-erede.useredecloud.com.br/v1");
const KIND = process.env.EREDE_PIX_KIND || "Pix";

let tokenCache = { valor: null, expira: 0 };

async function cabecalhoAutorizacao() {
  const modo = (process.env.EREDE_AUTH || "basic").toLowerCase();
  if (modo === "oauth") {
    // Para o caso de a Rede exigir OAuth 2.0 (client_credentials) na sua credencial.
    if (tokenCache.valor && Date.now() < tokenCache.expira - 60000) return "Bearer " + tokenCache.valor;
    const url = process.env.EREDE_OAUTH_URL;
    if (!url) throw new Error("EREDE_OAUTH_URL não configurada.");
    const basic = Buffer.from(process.env.EREDE_CLIENT_ID + ":" + process.env.EREDE_CLIENT_SECRET).toString("base64");
    const r = await fetch(url, { method: "POST", headers: { Authorization: "Basic " + basic, "Content-Type": "application/x-www-form-urlencoded" }, body: "grant_type=client_credentials" });
    const j = await r.json().catch(() => ({}));
    if (!r.ok || !j.access_token) throw new Error("Falha ao obter token da Rede (" + r.status + ").");
    tokenCache = { valor: j.access_token, expira: Date.now() + (Number(j.expires_in) || 300) * 1000 };
    return "Bearer " + j.access_token;
  }
  const pv = process.env.EREDE_PV, chave = process.env.EREDE_CHAVE;
  if (!pv || !chave) throw new Error("EREDE_PV e EREDE_CHAVE não configurados na Vercel.");
  return "Basic " + Buffer.from(pv + ":" + chave).toString("base64");
}

// Data/hora de Brasília no formato AAAA-MM-DDThh:mm:ss
function dataHoraBrasilia(d) {
  const p = new Intl.DateTimeFormat("sv-SE", { timeZone: "America/Sao_Paulo", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false }).format(d);
  return p.replace(" ", "T");
}

async function chamar(metodo, caminho, corpo) {
  const r = await fetch(BASE + caminho, {
    method: metodo,
    headers: { Authorization: await cabecalhoAutorizacao(), "Content-Type": "application/json", Accept: "application/json" },
    body: corpo ? JSON.stringify(corpo) : undefined
  });
  const texto = await r.text();
  let json = {}; try { json = texto ? JSON.parse(texto) : {}; } catch (e) { json = { bruto: texto }; }
  return { http: r.status, json };
}

const pegar = (o, caminhos) => { for (const c of caminhos) { const v = c.split(".").reduce((a, k) => (a == null ? a : a[k]), o); if (v != null && v !== "") return v; } return null; };

async function criarPix({ reference, valorCentavos, expiraEm }) {
  const corpo = { kind: KIND, reference, amount: valorCentavos, qrCode: { dateTimeExpiration: dataHoraBrasilia(expiraEm) } };
  const { http, json } = await chamar("POST", "/transactions", corpo);
  const returnCode = String(pegar(json, ["returnCode"]) || "");
  const ok = http >= 200 && http < 300 && (returnCode === "" || returnCode === "00");
  return {
    ok, http, returnCode,
    mensagem: pegar(json, ["returnMessage", "message"]) || "",
    tid: pegar(json, ["tid", "transactionId"]),
    copiaECola: pegar(json, ["qrCodeResponse.qrCodeData", "qrCode.qrCodeData", "qrCodeData", "qrCodeResponse.emv"]),
    imagem: pegar(json, ["qrCodeResponse.qrCodeImage", "qrCode.qrCodeImage", "qrCodeImage"]),
    expiraEm: expiraEm.toISOString(),
    bruto: json, enviado: corpo
  };
}

async function consultarPix(tid) {
  const { http, json } = await chamar("GET", "/transactions/" + encodeURIComponent(tid));
  const status = String(pegar(json, ["authorization.status", "status", "qrCodeResponse.status"]) || "");
  const returnCode = String(pegar(json, ["returnCode", "authorization.returnCode"]) || "");
  return {
    http, status, returnCode,
    pago: /^(approved|paid|pago|aprovad)/i.test(status),
    expirado: returnCode === "3036" || /expired|expirad/i.test(status),
    valorCentavos: Number(pegar(json, ["authorization.amount", "amount"])) || null,
    nsu: pegar(json, ["authorization.nsu", "nsu"]),
    endToEndId: pegar(json, ["authorization.endToEndId", "endToEndId", "authorization.txId", "txId"]),
    pagoEm: pegar(json, ["authorization.dateTime", "authorization.paymentDateTime", "dateTime"]),
    bruto: json
  };
}

module.exports = { criarPix, consultarPix, AMBIENTE };
