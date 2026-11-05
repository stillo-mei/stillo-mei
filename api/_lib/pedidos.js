// Regras de pedido usadas pelo servidor (preço oficial, prazo e confirmação de pagamento).
const { admin } = require("./supabase");
const { consultarPix } = require("./erede");

const AUTO_MSG = {
  pagamento_confirmado: "Recebemos seu pagamento. Obrigado!",
  aguardando_documentos: "Falta enviar documentos para começarmos. Veja a lista no pedido.",
  em_analise: "Nossa equipe está analisando suas informações."
};

async function catalogo() {
  const { data, error } = await admin().from("config").select("dados").eq("id", "catalogo").single();
  if (error) throw error;
  return data.dados;
}

function servicoDoCatalogo(cat, codigo) { return (cat.servicos || []).find(s => s.codigo === codigo) || null; }
function precoOficial(srv) { return srv.gratuito ? 0 : Number(srv.preco) || 0; }

function addDiasUteis(iso, n) {
  const d = new Date(iso); let a = 0;
  while (a < n) { d.setDate(d.getDate() + 1); const w = d.getDay(); if (w !== 0 && w !== 6) a++; }
  return d.toISOString();
}

async function registrar(pedidoId, operacao, tid, valor, status, resposta) {
  await admin().from("pagamentos").insert({ pedido_id: pedidoId, operacao, tid, valor, status, resposta });
}

// Consulta a e.Rede e, se o Pix foi pago, confirma o pedido. Nunca confia em dados enviados pelo navegador
// ou pelo webhook: a confirmação sempre vem de uma nova consulta à Rede.
async function verificarPagamento(pedido) {
  if (!pedido || pedido.status !== "aguardando_pagamento") return { status: pedido && pedido.status, pago: pedido && pedido.status !== "aguardando_pagamento" };
  const pix = pedido.dados && pedido.dados.pix;
  if (!pix || !pix.tid) return { status: pedido.status, pago: false };
  const c = await consultarPix(pix.tid);
  await registrar(pedido.id, "consulta", pix.tid, pix.valor, c.status || ("http " + c.http), c.bruto);
  if (!c.pago) return { status: pedido.status, pago: false, expirado: c.expirado };

  const valorEsperado = Math.round(Number(pix.valor) * 100);
  if (c.valorCentavos && c.valorCentavos !== valorEsperado) {
    await registrar(pedido.id, "divergencia_valor", pix.tid, pix.valor, "valor " + c.valorCentavos, c.bruto);
    return { status: pedido.status, pago: false, divergencia: true };
  }

  const cat = await catalogo();
  const srv = servicoDoCatalogo(cat, pedido.servico) || { documentos: [], prazoDias: 3 };
  const docs = Object.values(pedido.dados.documentos || {});
  const faltando = (srv.documentos || []).filter(d => d.obrigatorio && !docs.some(x => x.docTipo === d.id));
  const prox = faltando.length ? "aguardando_documentos" : "em_analise";
  const t = new Date().toISOString();
  const patch = {
    status: prox, pagoEm: t, naoLido: true, novoParaStillo: true,
    prazoFinal: addDiasUteis(t, Number(srv.prazoDias) || 3),
    pagamento: { metodo: "pix", valor: Number(pix.valor), confirmadoEm: t, comprovante: "CMP-" + pedido.id, tid: pix.tid, nsu: c.nsu || null, endToEndId: c.endToEndId || null, pagoNaRedeEm: c.pagoEm || null, simulado: false, manual: false },
    historico: {
      ["h" + Date.now() + "p"]: { em: t, status: "pagamento_confirmado", texto: AUTO_MSG.pagamento_confirmado, por: "sistema" },
      ["h" + Date.now() + "q"]: { em: t, status: prox, texto: AUTO_MSG[prox], por: "sistema" }
    }
  };
  if (faltando.length) patch.pendencia = "Envie: " + faltando.map(d => d.nome).join("; ") + ".";
  const { error } = await admin().rpc("merge_pedido", { p_id: pedido.id, p_patch: patch });
  if (error) throw error;
  await registrar(pedido.id, "confirmado", pix.tid, pix.valor, "Approved", c.bruto);
  return { status: prox, pago: true };
}

module.exports = { catalogo, servicoDoCatalogo, precoOficial, verificarPagamento, registrar };
