-- =====================================================================
-- STILLO MEI · Resolva Agora · Banco de dados (Supabase / PostgreSQL)
-- Rodar inteiro no Supabase: SQL Editor > New query > colar > Run.
-- Pode ser executado de novo sem perder dados (idempotente).
-- =====================================================================

-- ---------- Utilitário: mescla profunda de JSON ----------
create or replace function public.jsonb_deep_merge(a jsonb, b jsonb)
returns jsonb language plpgsql immutable as $$
declare k text; resultado jsonb;
begin
  if a is null or jsonb_typeof(a) <> 'object' or b is null or jsonb_typeof(b) <> 'object' then
    return coalesce(b, a);
  end if;
  resultado := a;
  for k in select jsonb_object_keys(b) loop
    if resultado ? k and jsonb_typeof(resultado->k) = 'object' and jsonb_typeof(b->k) = 'object' then
      resultado := jsonb_set(resultado, array[k], public.jsonb_deep_merge(resultado->k, b->k));
    else
      resultado := jsonb_set(resultado, array[k], b->k);
    end if;
  end loop;
  return resultado;
end $$;

-- ---------- Equipe Stillo (quem acessa o painel) ----------
create table if not exists public.equipe (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nome text not null,
  papel text not null default 'operador',
  criado_em timestamptz not null default now()
);

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.equipe where user_id = auth.uid())
$$;

-- ---------- Tabelas ----------
create table if not exists public.config (
  id text primary key,
  dados jsonb not null,
  atualizado_em timestamptz not null default now()
);

create table if not exists public.clientes (
  uid uuid primary key references auth.users(id) on delete cascade,
  perfil jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists public.pedidos (
  id text primary key,
  uid uuid not null references public.clientes(uid) on delete cascade,
  servico text not null,
  status text not null default 'rascunho',
  preco numeric(10,2) not null default 0,
  criado_em timestamptz not null default now(),
  pago_em timestamptz,
  dados jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now()
);
create index if not exists pedidos_uid_idx on public.pedidos(uid);
create index if not exists pedidos_status_idx on public.pedidos(status);
create index if not exists pedidos_pix_tid_idx on public.pedidos((dados->'pix'->>'tid'));

create table if not exists public.interno (
  uid uuid primary key,
  dados jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now()
);

create table if not exists public.pagamentos (
  id bigserial primary key,
  pedido_id text references public.pedidos(id) on delete set null,
  provedor text not null default 'erede',
  operacao text not null,
  tid text,
  valor numeric(10,2),
  status text,
  resposta jsonb,
  criado_em timestamptz not null default now()
);

create table if not exists public.auditoria (
  id bigserial primary key,
  em timestamptz not null default now(),
  user_id uuid,
  acao text not null,
  alvo text,
  detalhe jsonb
);

-- ---------- Segurança por linha (RLS) ----------
alter table public.equipe enable row level security;
alter table public.config enable row level security;
alter table public.clientes enable row level security;
alter table public.pedidos enable row level security;
alter table public.interno enable row level security;
alter table public.pagamentos enable row level security;
alter table public.auditoria enable row level security;

drop policy if exists equipe_ler on public.equipe;
create policy equipe_ler on public.equipe for select to authenticated using (user_id = auth.uid() or public.is_staff());

drop policy if exists config_ler on public.config;
create policy config_ler on public.config for select to anon, authenticated using (true);
drop policy if exists config_escrever on public.config;
create policy config_escrever on public.config for all to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists clientes_ler on public.clientes;
create policy clientes_ler on public.clientes for select to authenticated using (uid = auth.uid() or public.is_staff());
drop policy if exists clientes_criar on public.clientes;
create policy clientes_criar on public.clientes for insert to authenticated with check (uid = auth.uid());
drop policy if exists clientes_alterar on public.clientes;
create policy clientes_alterar on public.clientes for update to authenticated using (uid = auth.uid() or public.is_staff()) with check (uid = auth.uid() or public.is_staff());

drop policy if exists pedidos_ler on public.pedidos;
create policy pedidos_ler on public.pedidos for select to authenticated using (uid = auth.uid() or public.is_staff());
drop policy if exists pedidos_criar on public.pedidos;
create policy pedidos_criar on public.pedidos for insert to authenticated with check (uid = auth.uid());
drop policy if exists pedidos_alterar on public.pedidos;
create policy pedidos_alterar on public.pedidos for update to authenticated using (uid = auth.uid() or public.is_staff()) with check (uid = auth.uid() or public.is_staff());

drop policy if exists interno_equipe on public.interno;
create policy interno_equipe on public.interno for all to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists pagamentos_equipe on public.pagamentos;
create policy pagamentos_equipe on public.pagamentos for select to authenticated using (public.is_staff());

drop policy if exists auditoria_equipe on public.auditoria;
create policy auditoria_equipe on public.auditoria for select to authenticated using (public.is_staff());

-- ---------- Trava de segurança dos pedidos ----------
-- O cliente NÃO consegue: confirmar pagamento, mudar preço, mudar responsável,
-- registrar reembolso nem pular etapas. Só a equipe e o servidor (Pix) fazem isso.
create or replace function public.pedidos_guarda()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  eh_cliente boolean := coalesce(auth.jwt()->>'role', '') = 'authenticated' and not public.is_staff();
  srv jsonb; v_preco numeric; k text;
  protegidos text[] := array['pagamento','pix','reembolso','responsavel','pagoEm','concluidoEm'];
  gratis_ok boolean := false;
begin
  new.atualizado_em := now();
  if not eh_cliente then
    new.dados := jsonb_set(new.dados, '{status}', to_jsonb(new.status));
    return new;
  end if;

  select s into srv from public.config c, jsonb_array_elements(c.dados->'servicos') s
   where c.id = 'catalogo' and s->>'codigo' = (case when tg_op = 'UPDATE' then old.servico else new.servico end) limit 1;
  if srv is null then raise exception 'Serviço não encontrado no catálogo.'; end if;
  v_preco := case when coalesce((srv->>'gratuito')::boolean, false) then 0 else coalesce((srv->>'preco')::numeric, 0) end;

  if tg_op = 'INSERT' then
    if coalesce((srv->>'ativo')::boolean, true) = false then raise exception 'Serviço indisponível.'; end if;
    if new.uid <> auth.uid() then raise exception 'Operação não permitida.'; end if;
    if new.status not in ('rascunho','aguardando_pagamento') then raise exception 'Status inicial inválido.'; end if;
    foreach k in array protegidos loop new.dados := new.dados - k; end loop;
  else
    new.uid := old.uid; new.servico := old.servico; new.criado_em := old.criado_em; new.pago_em := old.pago_em;
    gratis_ok := v_preco = 0 and old.status = 'aguardando_pagamento'
                 and new.status in ('aguardando_documentos','em_analise')
                 and new.dados->'pagamento'->>'metodo' = 'gratuito';
    if old.status in ('rascunho','aguardando_pagamento') then
      if not (new.status in ('rascunho','aguardando_pagamento','cancelado') or gratis_ok) then
        raise exception 'Alteração de status não permitida.';
      end if;
    elsif old.status in ('aguardando_documentos','aguardando_info') then
      if new.status not in (old.status, 'em_analise') then raise exception 'Alteração de status não permitida.'; end if;
    elsif new.status <> old.status then
      raise exception 'Alteração de status não permitida.';
    end if;
    foreach k in array protegidos loop
      if gratis_ok and k in ('pagamento','pagoEm') then continue; end if;
      if old.dados ? k then new.dados := jsonb_set(new.dados, array[k], old.dados->k);
      else new.dados := new.dados - k; end if;
    end loop;
    if gratis_ok then new.pago_em := now(); end if;
  end if;

  if new.status in ('rascunho','aguardando_pagamento') or tg_op = 'INSERT' then
    new.preco := v_preco;
  else
    new.preco := old.preco;
  end if;
  new.dados := jsonb_set(jsonb_set(new.dados, '{preco}', to_jsonb(new.preco)), '{status}', to_jsonb(new.status));
  return new;
end $$;

drop trigger if exists pedidos_guarda on public.pedidos;
create trigger pedidos_guarda before insert or update on public.pedidos
for each row execute function public.pedidos_guarda();

-- ---------- Auditoria (status de pedidos e catálogo) ----------
create or replace function public.auditar()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'config' then
    insert into public.auditoria(user_id, acao, alvo, detalhe) values (auth.uid(), 'config', new.id, null);
  elsif tg_op = 'INSERT' then
    insert into public.auditoria(user_id, acao, alvo, detalhe)
    values (auth.uid(), 'status_pedido', new.id, jsonb_build_object('de', null, 'para', new.status));
  elsif old.status is distinct from new.status then
    insert into public.auditoria(user_id, acao, alvo, detalhe)
    values (auth.uid(), 'status_pedido', new.id, jsonb_build_object('de', old.status, 'para', new.status));
  end if;
  return new;
end $$;
drop trigger if exists pedidos_auditar on public.pedidos;
create trigger pedidos_auditar after insert or update on public.pedidos for each row execute function public.auditar();
drop trigger if exists config_auditar on public.config;
create trigger config_auditar after insert or update on public.config for each row execute function public.auditar();

-- ---------- Funções chamadas pelo app ----------
create or replace function public.merge_pedido(p_id text, p_patch jsonb)
returns void language plpgsql security invoker set search_path = public as $$
declare atual jsonb; novo jsonb;
begin
  select dados into atual from public.pedidos where id = p_id for update;
  if not found then
    insert into public.pedidos(id, uid, servico, status, preco, dados)
    values (p_id, auth.uid(), p_patch->>'servico', coalesce(p_patch->>'status', 'rascunho'), coalesce((p_patch->>'preco')::numeric, 0), p_patch);
  else
    novo := public.jsonb_deep_merge(atual, p_patch);
    update public.pedidos
       set dados = novo,
           status = coalesce(novo->>'status', status),
           preco = coalesce((novo->>'preco')::numeric, preco),
           pago_em = coalesce((novo->>'pagoEm')::timestamptz, pago_em)
     where id = p_id;
  end if;
end $$;

create or replace function public.merge_cliente(p_uid uuid, p_patch jsonb)
returns void language sql security invoker set search_path = public as $$
  update public.clientes set perfil = public.jsonb_deep_merge(perfil, p_patch), atualizado_em = now() where uid = p_uid;
$$;

create or replace function public.merge_interno(p_uid uuid, p_patch jsonb)
returns void language sql security invoker set search_path = public as $$
  insert into public.interno(uid, dados) values (p_uid, p_patch)
  on conflict (uid) do update set dados = public.jsonb_deep_merge(public.interno.dados, excluded.dados), atualizado_em = now();
$$;

grant execute on function public.is_staff() to anon, authenticated;
grant execute on function public.merge_pedido(text, jsonb) to authenticated;
grant execute on function public.merge_cliente(uuid, jsonb) to authenticated;
grant execute on function public.merge_interno(uuid, jsonb) to authenticated;

-- ---------- Tempo real (atualização automática das telas) ----------
do $$
declare t text;
begin
  foreach t in array array['pedidos','clientes','config','interno'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ---------- Armazenamento de documentos (privado) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos', 'documentos', false, 10485760, array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update set public = false, file_size_limit = 10485760, allowed_mime_types = array['application/pdf','image/jpeg','image/png'];

drop policy if exists documentos_ler on storage.objects;
create policy documentos_ler on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff()));
drop policy if exists documentos_enviar on storage.objects;
create policy documentos_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff()));
drop policy if exists documentos_apagar on storage.objects;
create policy documentos_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'documentos' and public.is_staff());

-- ---------- Catálogo inicial (só grava se ainda não existir) ----------
insert into public.config (id, dados) values ('catalogo', $catalogo${"versao": 1, "ambienteTeste": true, "whatsapp": "", "equipe": ["Danielly Carvalho", "Equipe Fiscal", "Atendimento"], "limiteAnual": 81000, "limiteNota": "Limite anual do MEI (LC 123/2006, art. 18-A). Projetos de aumento estão em tramitação: atualize aqui somente após a lei entrar em vigor.", "servicos": [{"codigo": "RA-001", "ativo": true, "categoria": "Regularização", "icone": "lupa", "nome": "Consulta e diagnóstico do CNPJ", "resumo": "Descubra se o seu MEI está em dia e o que precisa ser feito.", "descricao": "Nossa equipe consulta a situação do seu CNPJ nos sistemas oficiais e entrega um relatório simples: se o cadastro está ativo, se há guias DAS em aberto, se as declarações anuais foram entregues e quais são os próximos passos.", "paraQuem": "Para quem não sabe se o MEI está regular, recebeu algum aviso, vai pedir crédito ou precisa comprovar regularidade para um contrato.", "incluso": ["Consulta da situação cadastral do CNPJ", "Verificação das guias DAS em aberto", "Verificação das declarações anuais entregues", "Relatório em PDF com explicação simples", "Lista de próximos passos recomendados"], "documentos": [{"id": "doc_id", "nome": "Documento com foto do titular (RG ou CNH)", "obrigatorio": true}, {"id": "avisos", "nome": "Avisos ou cartas recebidas da Receita ou da Prefeitura", "obrigatorio": false}], "prazoDias": 2, "preco": 49.9, "gratuito": false, "orcamentoPersonalizado": false, "analiseHumanaSempre": false, "regrasHumano": "Encaminhar para análise se houver débito em dívida ativa, CNPJ inapto/baixado ou aviso de exclusão do Simples.", "campos": [{"id": "cnpj", "passo": 1, "tipo": "cnpj", "label": "CNPJ do seu MEI", "obrigatorio": true, "exemplo": "00.000.000/0000-00"}, {"id": "nomeEmpresarial", "passo": 1, "tipo": "text", "label": "Nome da empresa", "obrigatorio": true, "exemplo": "Ex.: M. Silva Doces", "ajuda": "Como aparece no cartão CNPJ."}, {"id": "municipio", "passo": 1, "tipo": "text", "label": "Cidade e estado", "obrigatorio": true, "exemplo": "Ex.: São Bernardo do Campo/SP"}, {"id": "funcionario", "passo": 1, "tipo": "radio", "label": "Você tem funcionário registrado?", "obrigatorio": true, "opcoes": ["Sim", "Não"]}, {"id": "motivos", "passo": 2, "tipo": "checkbox", "label": "Por que você quer o diagnóstico?", "obrigatorio": true, "opcoes": ["Quero saber se estou regular", "Recebi um aviso ou cobrança", "Vou pedir empréstimo ou financiamento", "Preciso comprovar regularidade para um contrato", "Estou pensando em fechar o MEI"]}, {"id": "faturamentoAno", "passo": 2, "tipo": "money", "label": "Quanto você faturou este ano, até agora?", "obrigatorio": false, "ajuda": "Pode ser um valor aproximado.", "exemplo": "R$ 30.000,00"}, {"id": "acesso", "passo": 2, "tipo": "radio", "label": "Como vamos consultar seus dados?", "obrigatorio": true, "ajuda": "Nunca pedimos sua senha gov.br.", "opcoes": ["Vou cadastrar a Stillo como procuradora no e-CAC (vocês me enviam o passo a passo)", "Prefiro falar com a equipe sobre o acesso"]}, {"id": "obs", "passo": 2, "tipo": "textarea", "label": "Quer contar mais alguma coisa?", "obrigatorio": false, "exemplo": "Ex.: recebi uma carta da Receita em março."}]}, {"codigo": "RA-002", "ativo": true, "categoria": "Declarações", "icone": "doc", "nome": "Declaração anual DASN-SIMEI", "resumo": "Entregamos sua declaração anual de faturamento sem complicação.", "descricao": "Todo MEI precisa informar, uma vez por ano, quanto faturou no ano anterior. O prazo é até 31 de maio. Você informa os valores, nós conferimos, transmitimos a declaração e enviamos o recibo de entrega.", "paraQuem": "Para MEIs que ainda não entregaram a declaração do ano anterior ou que têm declarações de anos passados em atraso.", "incluso": ["Conferência dos valores informados", "Aviso se o faturamento passou do limite do MEI", "Transmissão da declaração", "Recibo de entrega em PDF", "Orientação sobre multa, se a entrega estiver em atraso"], "documentos": [{"id": "doc_id", "nome": "Documento com foto do titular (RG ou CNH)", "obrigatorio": true}, {"id": "relatorio", "nome": "Relatório mensal de receitas, extratos ou notas emitidas no ano", "obrigatorio": false}], "prazoDias": 2, "preco": 89.9, "gratuito": false, "orcamentoPersonalizado": false, "analiseHumanaSempre": false, "regrasHumano": "Encaminhar para análise se o faturamento passar do limite (proporcional no ano de abertura) ou se a declaração for retificadora.", "campos": [{"id": "cnpj", "passo": 1, "tipo": "cnpj", "label": "CNPJ do seu MEI", "obrigatorio": true, "exemplo": "00.000.000/0000-00"}, {"id": "anoCalendario", "passo": 1, "tipo": "select", "label": "De qual ano é a declaração?", "obrigatorio": true, "ajuda": "É o ano em que você teve o faturamento. Em 2026, a declaração normal é a de 2025.", "opcoes": ["2025", "2024", "2023", "2022", "2021"]}, {"id": "tipoDeclaracao", "passo": 1, "tipo": "radio", "label": "Essa declaração já foi entregue antes?", "obrigatorio": true, "opcoes": ["Não, é a primeira entrega", "Sim, preciso corrigir"]}, {"id": "abertoNoAno", "passo": 1, "tipo": "radio", "label": "O MEI foi aberto nesse mesmo ano?", "obrigatorio": true, "opcoes": ["Sim", "Não"]}, {"id": "mesAbertura", "passo": 1, "tipo": "select", "label": "Em que mês foi aberto?", "obrigatorio": true, "mostrarSe": {"campo": "abertoNoAno", "valor": "Sim"}, "opcoes": ["Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho", "Julho", "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro"]}, {"id": "receitaTotal", "passo": 2, "tipo": "money", "label": "Quanto você faturou no ano, no total?", "obrigatorio": true, "ajuda": "Tudo o que entrou com vendas e serviços, sem descontar despesas.", "exemplo": "R$ 45.000,00"}, {"id": "receitaComercio", "passo": 2, "tipo": "money", "label": "Quanto desse total veio da venda de produtos?", "obrigatorio": true, "ajuda": "Comércio ou fabricação. Se você só presta serviços, informe 0.", "exemplo": "R$ 0,00"}, {"id": "teveEmpregado", "passo": 2, "tipo": "radio", "label": "Você teve funcionário registrado nesse ano?", "obrigatorio": true, "opcoes": ["Sim", "Não"]}, {"id": "obs", "passo": 2, "tipo": "textarea", "label": "Observações", "obrigatorio": false}]}, {"codigo": "RA-003", "ativo": true, "categoria": "Débitos", "icone": "moeda", "nome": "Consulta e orientação sobre débitos", "resumo": "Saiba quanto você deve e qual a melhor forma de pagar.", "descricao": "Levantamos as guias DAS em aberto do seu MEI, com valores atualizados, e explicamos em linguagem simples as opções: pagar à vista, parcelar ou priorizar algumas guias.", "paraQuem": "Para quem deixou de pagar o DAS em algum mês, recebeu cobrança ou não sabe se tem dívida.", "incluso": ["Levantamento das guias DAS em aberto", "Valores atualizados com multa e juros", "Verificação de débitos enviados para dívida ativa", "Relatório com as opções de pagamento", "Guias para pagamento à vista, se você quiser"], "documentos": [{"id": "doc_id", "nome": "Documento com foto do titular (RG ou CNH)", "obrigatorio": true}, {"id": "avisos", "nome": "Cobranças ou avisos recebidos", "obrigatorio": false}], "prazoDias": 2, "preco": 59.9, "gratuito": false, "orcamentoPersonalizado": false, "analiseHumanaSempre": false, "regrasHumano": "Encaminhar para análise se houver débito em dívida ativa ou cobrança judicial.", "campos": [{"id": "cnpj", "passo": 1, "tipo": "cnpj", "label": "CNPJ do seu MEI", "obrigatorio": true, "exemplo": "00.000.000/0000-00"}, {"id": "desde", "passo": 1, "tipo": "select", "label": "Há quanto tempo você está sem pagar o DAS?", "obrigatorio": true, "opcoes": ["Menos de 6 meses", "De 6 meses a 1 ano", "Mais de 1 ano", "Não sei"]}, {"id": "recebeuCobranca", "passo": 1, "tipo": "radio", "label": "Você recebeu alguma cobrança?", "obrigatorio": true, "opcoes": ["Sim", "Não", "Não sei"]}, {"id": "dividaAtiva", "passo": 2, "tipo": "radio", "label": "Algum débito já foi para a dívida ativa?", "obrigatorio": true, "ajuda": "Dívida ativa é quando a cobrança passa para a Procuradoria da Fazenda Nacional (PGFN). Se não souber, nós verificamos.", "opcoes": ["Sim", "Não", "Não sei"]}, {"id": "acesso", "passo": 2, "tipo": "radio", "label": "Como vamos consultar seus dados?", "obrigatorio": true, "ajuda": "Nunca pedimos sua senha gov.br.", "opcoes": ["Vou cadastrar a Stillo como procuradora no e-CAC (vocês me enviam o passo a passo)", "Prefiro falar com a equipe sobre o acesso"]}, {"id": "obs", "passo": 2, "tipo": "textarea", "label": "Quer contar mais alguma coisa?", "obrigatorio": false}]}, {"codigo": "RA-004", "ativo": true, "categoria": "Débitos", "icone": "parcelas", "nome": "Parcelamento e regularização de DAS", "resumo": "Parcelamos suas guias em atraso para você voltar a ficar em dia.", "descricao": "Fazemos o pedido de parcelamento dos seus DAS em atraso e enviamos a primeira guia. O número de parcelas e o valor mínimo seguem as regras da Receita Federal ou da PGFN. O parcelamento só passa a valer depois que a primeira parcela é paga.", "paraQuem": "Para quem tem DAS atrasados e não consegue pagar tudo de uma vez.", "incluso": ["Conferência dos débitos que podem ser parcelados", "Simulação das parcelas", "Pedido de parcelamento", "Envio da primeira guia", "Orientação para emitir as próximas parcelas"], "documentos": [{"id": "doc_id", "nome": "Documento com foto do titular (RG ou CNH)", "obrigatorio": true}, {"id": "avisos", "nome": "Cobranças ou avisos recebidos", "obrigatorio": false}], "prazoDias": 3, "preco": 129.9, "gratuito": false, "orcamentoPersonalizado": false, "analiseHumanaSempre": false, "regrasHumano": "Encaminhar para análise se já existir parcelamento ativo (reparcelamento) ou débito em dívida ativa.", "campos": [{"id": "cnpj", "passo": 1, "tipo": "cnpj", "label": "CNPJ do seu MEI", "obrigatorio": true, "exemplo": "00.000.000/0000-00"}, {"id": "parcelamentoAtivo", "passo": 1, "tipo": "radio", "label": "Você já tem um parcelamento em andamento?", "obrigatorio": true, "opcoes": ["Sim", "Não", "Não sei"]}, {"id": "dividaAtiva", "passo": 1, "tipo": "radio", "label": "Algum débito já foi para a dívida ativa?", "obrigatorio": true, "ajuda": "Se não souber, nós verificamos.", "opcoes": ["Sim", "Não", "Não sei"]}, {"id": "valorMensal", "passo": 2, "tipo": "money", "label": "Quanto você consegue pagar por mês?", "obrigatorio": true, "ajuda": "Usamos esse valor para sugerir o número de parcelas.", "exemplo": "R$ 150,00"}, {"id": "preferencia", "passo": 2, "tipo": "radio", "label": "O que você prefere?", "obrigatorio": true, "opcoes": ["Parcelar", "Pagar à vista, se der", "Quero a orientação da equipe"]}, {"id": "acesso", "passo": 2, "tipo": "radio", "label": "Como vamos acessar seus dados?", "obrigatorio": true, "ajuda": "Nunca pedimos sua senha gov.br.", "opcoes": ["Vou cadastrar a Stillo como procuradora no e-CAC (vocês me enviam o passo a passo)", "Prefiro falar com a equipe sobre o acesso"]}, {"id": "obs", "passo": 2, "tipo": "textarea", "label": "Observações", "obrigatorio": false}]}, {"codigo": "RA-005", "ativo": true, "categoria": "Alterações", "icone": "seta", "nome": "Desenquadramento e migração de MEI para ME", "resumo": "Seu negócio cresceu? Orientamos e fazemos a passagem de MEI para ME.", "descricao": "Analisamos se você precisa (ou pode) deixar de ser MEI, a partir de quando, e quais impostos passam a valer. Depois, fazemos a comunicação de desenquadramento e orientamos a nova rotina como Microempresa (ME).", "paraQuem": "Para quem passou ou vai passar do limite de faturamento, quer contratar mais de um funcionário, ter sócio, abrir filial ou exercer atividade não permitida para MEI.", "incluso": ["Análise do motivo e da data em que a mudança passa a valer", "Estimativa dos impostos como ME no Simples Nacional", "Comunicação de desenquadramento", "Plano de transição com os próximos passos", "Proposta de contabilidade mensal da ME (opcional)"], "documentos": [{"id": "doc_id", "nome": "Documento com foto do titular (RG ou CNH)", "obrigatorio": true}, {"id": "relatorio", "nome": "Relatório de faturamento do ano ou extratos bancários", "obrigatorio": true}], "prazoDias": 5, "preco": 199.9, "gratuito": false, "orcamentoPersonalizado": true, "analiseHumanaSempre": true, "notaPreco": "O valor cobre a análise e a comunicação de desenquadramento. A contabilidade mensal da ME é orçada à parte.", "regrasHumano": "Sempre passa por análise de um contador antes da execução.", "campos": [{"id": "cnpj", "passo": 1, "tipo": "cnpj", "label": "CNPJ do seu MEI", "obrigatorio": true, "exemplo": "00.000.000/0000-00"}, {"id": "motivo", "passo": 1, "tipo": "radio", "label": "Por que você quer deixar de ser MEI?", "obrigatorio": true, "opcoes": ["Meu faturamento passou do limite do MEI", "Quero contratar mais de um funcionário", "Quero ter sócio ou abrir filial", "Minha atividade não é permitida para MEI", "Quero deixar de ser MEI por opção", "Não sei, quero uma análise"]}, {"id": "atividade", "passo": 1, "tipo": "text", "label": "O que sua empresa faz hoje?", "obrigatorio": true, "exemplo": "Ex.: venda de roupas e conserto de peças"}, {"id": "faturamentoAnoAtual", "passo": 2, "tipo": "money", "label": "Quanto você faturou este ano, até agora?", "obrigatorio": true, "exemplo": "R$ 90.000,00"}, {"id": "faturamentoAnoAnterior", "passo": 2, "tipo": "money", "label": "E no ano passado?", "obrigatorio": false, "exemplo": "R$ 70.000,00"}, {"id": "abertoNoAno", "passo": 2, "tipo": "radio", "label": "O MEI foi aberto este ano?", "obrigatorio": true, "opcoes": ["Sim", "Não"]}, {"id": "mesAbertura", "passo": 2, "tipo": "select", "label": "Em que mês foi aberto?", "obrigatorio": true, "mostrarSe": {"campo": "abertoNoAno", "valor": "Sim"}, "opcoes": ["Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho", "Julho", "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro"]}, {"id": "obs", "passo": 2, "tipo": "textarea", "label": "Quer contar mais alguma coisa?", "obrigatorio": false}]}], "emailAtendimento": "contato@stillogestao.com.br", "formasPagamento": ["pix"]}$catalogo$::jsonb)
on conflict (id) do nothing;

-- =====================================================================
-- DEPOIS do seu primeiro login no app, rode SOMENTE este trecho
-- (troque o e-mail se precisar) para liberar o Painel Stillo:
--
-- insert into public.equipe (user_id, nome, papel)
-- select id, 'Danielly Carvalho', 'admin' from auth.users
-- where lower(email) = 'danielly@stillogestao.com.br'
-- on conflict (user_id) do nothing;
-- =====================================================================
