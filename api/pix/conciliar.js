// Tarefa automática (Vercel Cron): confere Pix pendentes, caso algum aviso da Rede se perca.
const { admin } = require("../_lib/supabase");
const { verificarPagamento } = require("../_lib/pedidos");

module.exports = async (req, res) => {
  try {
    const segredo = process.env.CRON_SECRET;
    if (segredo && req.headers.authorization !== "Bearer " + segredo) return res.status(401).json({ erro: "não autorizado" });
    const desde = new Date(Date.now() - 2 * 864e5).toISOString();
    const { data, error } = await admin().from("pedidos").select("*")
      .eq("status", "aguardando_pagamento").gte("atualizado_em", desde).not("dados->pix->>tid", "is", null).limit(100);
    if (error) throw error;
    let confirmados = 0;
    for (const p of data || []) { try { const r = await verificarPagamento(p); if (r.pago) confirmados++; } catch (e) { console.error(p.id, e); } }
    return res.json({ ok: true, verificados: (data || []).length, confirmados });
  } catch (e) {
    console.error(e);
    return res.status(500).json({ ok: false });
  }
};
