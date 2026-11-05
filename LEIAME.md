# Stillo MEI · Resolva Agora — versão de produção

App do cliente + Painel Stillo, com login por código no e-mail, banco Supabase,
documentos privados e pagamento **Pix pela e.Rede (Rede Itaú)** com confirmação automática.

Endereço planejado: **https://mei.stillogestao.com.br**
Atendimento: **contato@stillogestao.com.br**

## Estrutura

| Pasta / arquivo | O que é |
|---|---|
| `public/index.html` | O app (cliente e painel). Abre em modo demonstração enquanto `config.js` estiver vazio. |
| `public/config.js` | URL e chave **pública** (anon) do Supabase. |
| `api/pix/criar.js` | Gera o QR Code Pix na e.Rede com o preço oficial do catálogo. |
| `api/pix/status.js` | Consulta a e.Rede e confirma o pedido quando o Pix é pago. |
| `api/pix/webhook.js` | Recebe o aviso da Rede e reconsulta antes de confirmar. |
| `api/pix/conciliar.js` | Rotina a cada 5 min que confere Pix pendentes (Vercel Cron). |
| `supabase/schema.sql` | Tabelas, regras de acesso, travas de segurança, arquivos e catálogo inicial. |
| `.env.example` | Lista de variáveis secretas para cadastrar na Vercel. |

## Implantação, em ordem

1. **GitHub** — crie um repositório privado `stillo-mei` e envie todos estes arquivos.
2. **Supabase** (região São Paulo) — rode `supabase/schema.sql` no SQL Editor; configure Auth (URL do site, modelos de e-mail com `{{ .Token }}`, SMTP próprio).
3. **config.js** — preencha `SUPABASE_URL` e `SUPABASE_ANON_KEY`.
4. **Vercel** (plano Pro) — importe o repositório (Framework: Other), cadastre as variáveis do `.env.example` e publique.
5. **Cloudflare** — CNAME `mei` → destino informado pela Vercel, com nuvem **cinza (DNS only)**.
6. **e.Rede** — Pix habilitado no Portal Rede, PV e chave de integração (sandbox e produção), webhook `https://mei.stillogestao.com.br/api/pix/webhook?chave=SEU_SEGREDO`.
7. **Primeiro acesso** — entre no app com seu e-mail e rode o trecho `insert into public.equipe ...` (fim do `schema.sql`).
8. **Homologação** — pedidos de teste nos 5 serviços com Pix do sandbox; depois produção com um Pix real de valor baixo.

O passo a passo detalhado está no guia de implantação entregue junto com este pacote.

## Segurança (resumo técnico)

- RLS em todas as tabelas: cliente vê só os próprios dados; equipe (tabela `equipe`) vê tudo.
- Trigger `pedidos_guarda`: cliente não altera preço, pagamento, Pix, reembolso, responsável nem pula etapas.
- Preço cobrado vem sempre do catálogo no servidor; a confirmação de pagamento só acontece após consulta à e.Rede.
- Documentos no bucket privado `documentos/<uid>/<pedido>/…`, abertos por link temporário (5 min).
- Auditoria de mudanças de status e de catálogo na tabela `auditoria`; respostas da Rede na tabela `pagamentos`.

## Pontos a confirmar com a Rede

O módulo `api/_lib/erede.js` segue o manual público da e.Rede (POST `/v1/transactions` com `kind: "Pix"`,
consulta GET `/v1/transactions/{tid}`). Confirme no Portal do Desenvolvedor da Rede:
autenticação da sua credencial (Basic com PV + chave, ou OAuth), nomes dos campos do QR Code
e o cadastro do webhook. Ajustes são feitos por variáveis de ambiente (`EREDE_AUTH`, `EREDE_BASE_URL`, `EREDE_PIX_KIND`)
sem mexer no código; cada resposta da Rede fica gravada na tabela `pagamentos` para conferência.
