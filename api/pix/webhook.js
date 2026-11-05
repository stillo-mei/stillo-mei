// POST /api/pix/webhook?chave=SEGREDO  -> aviso da Rede de que um Pix mudou de status.
// O conteúdo do aviso NÃO é usado como prova de pagamento: o app consulta a Rede de novo.
const { admin } = require("../_lib/supabase");
const { verificarPagamento } = require("../_lib/pedidos");

function acharTid(b) {
  if (!b || typeof b !== "object") return null;
  for (const k of ["tid", "transactionId", "TransactionId"]) if (b[k]) return String(b[k]);
  for (const k of ["data", "transaction", "payload", "authorization"]) { const t = acharTid(b[k]); if (t) return t; }
  if (Array.isArray(b.events)) for (const ev of b.events) { const t = acharTid(ev); if (t) return t; }
  return null;
}

module.exports = async (req, res) => {
  try {
    const segredo = process.env.EREDE_WEBHOOK_SEGREDO;
    if (segredo && req.query.chave !== segredo) return res.status(401).json({ erro: "não autorizado" });
    const tid = acharTid(req.body);
    if (!tid) return res.status(200).json({ ok: true, ignorado: "sem tid" });
    const { data: p } = await admin().from("pedidos").select("*").eq("dados->pix->>tid", tid).maybeSingle();
    if (!p) return res.status(200).json({ ok: true, ignorado: "pedido não encontrado" });
    const r = await verificarPagamento(p);
    return res.status(200).json({ ok: true, status: r.status });
  } catch (e) {
    console.error(e);
    return res.status(500).json({ ok: false });
  }
};
