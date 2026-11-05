// GET /api/pix/status?pedido=ID  -> consulta a Rede e confirma o pedido se o Pix foi pago.
const { admin, usuarioDaRequisicao, ehEquipe } = require("../_lib/supabase");
const { verificarPagamento } = require("../_lib/pedidos");

module.exports = async (req, res) => {
  try {
    const user = await usuarioDaRequisicao(req);
    if (!user) return res.status(401).json({ erro: "Sessão expirada. Entre novamente." });
    const id = String(req.query.pedido || "");
    const { data: p } = await admin().from("pedidos").select("*").eq("id", id).maybeSingle();
    if (!p || (p.uid !== user.id && !(await ehEquipe(user.id)))) return res.status(404).json({ erro: "Pedido não encontrado." });
    const r = await verificarPagamento(p);
    return res.json(r);
  } catch (e) {
    console.error(e);
    return res.status(500).json({ erro: "Não foi possível consultar o pagamento agora." });
  }
};
