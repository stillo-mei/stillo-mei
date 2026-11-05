// Cliente Supabase com a chave de serviço (somente no servidor; nunca no navegador).
const { createClient } = require("@supabase/supabase-js");

let _admin = null;
function admin() {
  if (!_admin) {
    const url = process.env.SUPABASE_URL;
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) throw new Error("SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY não configurados na Vercel.");
    _admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  }
  return _admin;
}

// Identifica o usuário a partir do token enviado pelo app (Authorization: Bearer <token>).
async function usuarioDaRequisicao(req) {
  const h = req.headers.authorization || "";
  const token = h.startsWith("Bearer ") ? h.slice(7) : "";
  if (!token) return null;
  const { data, error } = await admin().auth.getUser(token);
  if (error || !data || !data.user) return null;
  return data.user;
}

async function ehEquipe(userId) {
  const { data } = await admin().from("equipe").select("user_id").eq("user_id", userId).maybeSingle();
  return !!data;
}

module.exports = { admin, usuarioDaRequisicao, ehEquipe };
