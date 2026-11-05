// POST /api/pix/criar  { pedidoId }  -> gera (ou reaproveita) o QR Code Pix do pedido.
const { admin, usuarioDaRequisicao } = require("../_lib/supabase");
const { criarPix } = require("../_lib/erede");
const { catalogo, servicoDoCatalogo, precoOficial, registrar } = require("../_lib/pedidos");

module.exports = async (req, res) => {
  try {
    if (req.method !== "POST") return res.status(405).json({ erro: "Método não permitido." });
    const user = await usuarioDaRequisicao(req);
    if (!user) return res.status(401).json({ erro: "Entre na sua conta para pagar." });
    const pedidoId = String((req.body && req.body.pedidoId) || "");
    const { data: p } = await admin().from("pedidos").select("*").eq("id", pedidoId).maybeSingle();
    if (!p || p.uid !== user.id) return res.status(404).json({ erro: "Pedido não encontrado." });
    if (p.status !== "aguardando_pagamento") return res.status(409).json({ erro: "Este pedido não está aguardando pagamento.", status: p.status });

    const srv = servicoDoCatalogo(await catalogo(), p.servico);
    if (!srv || srv.ativo === false) return res.status(400).json({ erro: "Serviço indisponível no momento." });
    const preco = precoOficial(srv);
    if (!(preco > 0)) return res.status(400).json({ erro: "Este serviço não exige pagamento." });

    const atual = p.dados && p.dados.pix;
    if (atual && atual.tid && Number(atual.valor) === preco && new Date(atual.expiraEm).getTime() > Date.now() + 2 * 60000) {
      return res.json({ pix: atual });
    }

    const tentativa = ((atual && atual.tentativa) || 0) + 1;
    const reference = (p.id.replace(/[^A-Za-z0-9]/g, "") + "P" + tentativa).slice(-16);
    const minutos = Number(process.env.PIX_VALIDADE_MINUTOS) || 30;
    const r = await criarPix({ reference, valorCentavos: Math.round(preco * 100), expiraEm: new Date(Date.now() + minutos * 60000) });
    await registrar(p.id, "criar", r.tid, preco, r.ok ? "criado" : ("erro " + (r.returnCode || r.http)), { enviado: r.enviado, resposta: r.bruto });
    if (!r.ok || !r.tid || !r.copiaECola) {
      return res.status(502).json({ erro: "Não foi possível gerar o Pix agora. Tente de novo em instantes." + (r.mensagem ? " (" + r.mensagem + ")" : "") });
    }
    const pix = { tid: r.tid, copiaECola: r.copiaECola, imagem: r.imagem || null, expiraEm: r.expiraEm, valor: preco, reference, tentativa, criadoEm: new Date().toISOString() };
    const { error } = await admin().rpc("merge_pedido", { p_id: p.id, p_patch: { pix } });
    if (error) throw error;
    return res.json({ pix });
  } catch (e) {
    console.error(e);
    return res.status(500).json({ erro: "Erro ao gerar o Pix. Tente novamente." });
  }
};
