-- ============================================================
--  NEXUS IMOB — SCHEMA POSTGRESQL MULTI-TENANT
--  Versão: 1.0 | Março 2026
--  Estratégia: Schema separado por tenant (imobiliária)
-- ============================================================


-- ============================================================
-- 0. SCHEMA PÚBLICO — CONTROLE DO SAAS
--    Tabelas globais: tenants, planos, billing
-- ============================================================

CREATE SCHEMA IF NOT EXISTS public;

-- ------------------------------------------------------------
-- PLANOS DE ASSINATURA
-- ------------------------------------------------------------
CREATE TABLE public.plans (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          VARCHAR(50)    NOT NULL,                     -- 'starter' | 'profissional' | 'enterprise'
  display_name  VARCHAR(100)   NOT NULL,
  price_monthly NUMERIC(10,2)  NOT NULL,
  max_corretores INT           NOT NULL DEFAULT 5,
  max_imoveis   INT            NOT NULL DEFAULT 100,
  max_whatsapp  INT            NOT NULL DEFAULT 1,           -- instâncias Evolution API
  max_n8n_flows INT            NOT NULL DEFAULT 3,
  features      JSONB          NOT NULL DEFAULT '{}',
  active        BOOLEAN        NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

INSERT INTO public.plans (name, display_name, price_monthly, max_corretores, max_imoveis, max_whatsapp, max_n8n_flows, features) VALUES
  ('starter',       'Starter',       297.00,  5,  200,  1,  3, '{"crm":true,"agenda":true,"catalogo":true,"ia":false,"match_ia":false,"relatorios_basicos":true}'),
  ('profissional',  'Profissional',  597.00,  15, 1000, 2,  8, '{"crm":true,"agenda":true,"catalogo":true,"ia":true,"match_ia":true,"relatorios_avancados":true,"white_label":false}'),
  ('enterprise',    'Enterprise',    997.00,  -1, -1,   5, -1, '{"crm":true,"agenda":true,"catalogo":true,"ia":true,"match_ia":true,"relatorios_avancados":true,"white_label":true,"api_dedicada":true}');


-- ------------------------------------------------------------
-- TENANTS (IMOBILIÁRIAS)
-- ------------------------------------------------------------
CREATE TABLE public.tenants (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug            VARCHAR(100)  NOT NULL UNIQUE,             -- 'imoveis-premium-sp'
  name            VARCHAR(200)  NOT NULL,                    -- 'Imóveis Premium SP'
  creci           VARCHAR(50),
  email           VARCHAR(200)  NOT NULL UNIQUE,
  phone           VARCHAR(20),
  city            VARCHAR(100),
  state           CHAR(2),
  plan_id         UUID          REFERENCES public.plans(id),
  schema_name     VARCHAR(100)  NOT NULL UNIQUE,             -- 'tenant_abc123'
  status          VARCHAR(20)   NOT NULL DEFAULT 'trial',    -- 'trial' | 'active' | 'suspended' | 'cancelled'
  trial_ends_at   TIMESTAMPTZ,
  logo_url        TEXT,
  primary_color   VARCHAR(7)    DEFAULT '#ffd700',
  whatsapp_number VARCHAR(20),
  n8n_webhook_url TEXT,                                      -- URL do N8N desta imobiliária
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_tenants_slug   ON public.tenants(slug);
CREATE INDEX idx_tenants_status ON public.tenants(status);


-- ------------------------------------------------------------
-- BILLING / ASSINATURAS
-- ------------------------------------------------------------
CREATE TABLE public.subscriptions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       UUID          NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
  plan_id         UUID          NOT NULL REFERENCES public.plans(id),
  status          VARCHAR(20)   NOT NULL DEFAULT 'active',   -- 'active' | 'past_due' | 'cancelled'
  stripe_sub_id   VARCHAR(100),
  current_period_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  current_period_end   TIMESTAMPTZ NOT NULL,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- ============================================================
-- FUNÇÃO: Cria schema isolado para novo tenant
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_tenant_schema(p_schema_name TEXT)
RETURNS VOID AS $$
BEGIN
  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', p_schema_name);
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- 1. SCHEMA TENANT — Template replicado para cada imobiliária
--    Substitua "tenant_template" pelo slug do tenant real
-- ============================================================

CREATE SCHEMA IF NOT EXISTS tenant_template;

-- Define o search_path para trabalhar dentro do schema do tenant
-- SET search_path TO tenant_template;


-- ------------------------------------------------------------
-- USUÁRIOS / CORRETORES
-- ------------------------------------------------------------
CREATE TABLE tenant_template.users (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name            VARCHAR(200)  NOT NULL,
  email           VARCHAR(200)  NOT NULL UNIQUE,
  phone           VARCHAR(20),
  password_hash   TEXT          NOT NULL,
  role            VARCHAR(20)   NOT NULL DEFAULT 'corretor',  -- 'admin' | 'gerente' | 'corretor'
  creci           VARCHAR(50),
  avatar_url      TEXT,
  status          VARCHAR(20)   NOT NULL DEFAULT 'ativo',     -- 'ativo' | 'ferias' | 'inativo'
  ferias_inicio   DATE,
  ferias_fim      DATE,
  especialidades  TEXT[]        DEFAULT '{}',                 -- ['Alto Padrão', 'Apartamentos']
  regioes         TEXT[]        DEFAULT '{}',                 -- ['Moema', 'Itaim']
  meta_fechamentos_mes INT      DEFAULT 4,
  meta_vgv_mes    NUMERIC(15,2) DEFAULT 0,
  meta_visitas_mes INT          DEFAULT 15,
  rr_ativo        BOOLEAN       NOT NULL DEFAULT TRUE,        -- participa do round-robin
  rr_posicao      INT,                                        -- posição na fila
  nps_score       NUMERIC(5,2)  DEFAULT 0,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_email   ON tenant_template.users(email);
CREATE INDEX idx_users_status  ON tenant_template.users(status);
CREATE INDEX idx_users_rr      ON tenant_template.users(rr_ativo, rr_posicao);


-- ------------------------------------------------------------
-- IMÓVEIS
-- ------------------------------------------------------------
CREATE TABLE tenant_template.imoveis (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo          VARCHAR(20)   NOT NULL UNIQUE,              -- 'IMO-0001'
  titulo          VARCHAR(300)  NOT NULL,
  tipo            VARCHAR(50)   NOT NULL,                     -- 'apartamento' | 'casa' | 'cobertura' | 'comercial' | 'terreno'
  finalidade      VARCHAR(20)   NOT NULL,                     -- 'venda' | 'aluguel' | 'ambos'
  status          VARCHAR(30)   NOT NULL DEFAULT 'disponivel', -- 'disponivel' | 'visita_agendada' | 'proposta' | 'vendido' | 'alugado' | 'inativo'

  -- LOCALIZAÇÃO
  cep             VARCHAR(9),
  logradouro      VARCHAR(300),
  numero          VARCHAR(20),
  complemento     VARCHAR(100),
  bairro          VARCHAR(100),
  cidade          VARCHAR(100),
  estado          CHAR(2),
  latitude        NUMERIC(10,7),
  longitude       NUMERIC(10,7),

  -- VALORES
  preco_venda     NUMERIC(15,2),
  preco_aluguel   NUMERIC(10,2),
  condominio      NUMERIC(10,2),
  iptu            NUMERIC(10,2),

  -- CARACTERÍSTICAS
  area_total      NUMERIC(10,2),
  area_util       NUMERIC(10,2),
  quartos         SMALLINT      DEFAULT 0,
  suites          SMALLINT      DEFAULT 0,
  banheiros       SMALLINT      DEFAULT 0,
  vagas           SMALLINT      DEFAULT 0,
  andar           SMALLINT,
  total_andares   SMALLINT,
  mobiliado       BOOLEAN       DEFAULT FALSE,
  aceita_pets     BOOLEAN       DEFAULT FALSE,

  -- DIFERENCIAIS
  diferenciais    TEXT[]        DEFAULT '{}',                 -- ['piscina', 'churrasqueira', 'academia']

  -- MÍDIA
  fotos           JSONB         DEFAULT '[]',                 -- [{url, caption, ordem}]
  video_url       TEXT,
  tour_virtual    TEXT,

  -- INTEGRAÇÃO PORTAIS
  zap_id          VARCHAR(100),                               -- ID no ZAP Imóveis
  vivareal_id     VARCHAR(100),
  olx_id          VARCHAR(100),
  imovelweb_id    VARCHAR(100),
  publicado_zap       BOOLEAN   DEFAULT FALSE,
  publicado_vivareal  BOOLEAN   DEFAULT FALSE,
  publicado_olx       BOOLEAN   DEFAULT FALSE,

  -- EMBEDDINGS PARA MATCH IA
  embedding       vector(1536),                               -- pgvector para match semântico

  -- RESPONSÁVEL
  corretor_id     UUID          REFERENCES tenant_template.users(id) ON DELETE SET NULL,
  visualizacoes   INT           NOT NULL DEFAULT 0,
  destaque        BOOLEAN       NOT NULL DEFAULT FALSE,

  descricao       TEXT,
  observacoes_internas TEXT,

  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_imoveis_status     ON tenant_template.imoveis(status);
CREATE INDEX idx_imoveis_tipo       ON tenant_template.imoveis(tipo);
CREATE INDEX idx_imoveis_finalidade ON tenant_template.imoveis(finalidade);
CREATE INDEX idx_imoveis_bairro     ON tenant_template.imoveis(bairro);
CREATE INDEX idx_imoveis_preco_v    ON tenant_template.imoveis(preco_venda);
CREATE INDEX idx_imoveis_preco_a    ON tenant_template.imoveis(preco_aluguel);
CREATE INDEX idx_imoveis_corretor   ON tenant_template.imoveis(corretor_id);


-- ------------------------------------------------------------
-- LEADS
-- ------------------------------------------------------------
CREATE TABLE tenant_template.leads (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo          VARCHAR(20)   NOT NULL UNIQUE,              -- 'LEAD-0001'

  -- DADOS PESSOAIS
  nome            VARCHAR(200)  NOT NULL,
  email           VARCHAR(200),
  telefone        VARCHAR(20),
  whatsapp        VARCHAR(20),
  cpf             VARCHAR(14),

  -- ORIGEM
  fonte           VARCHAR(50)   NOT NULL,                     -- 'zap_imoveis' | 'vivareal' | 'olx' | 'meta_ads' | 'google_ads' | 'whatsapp_direto' | 'site' | 'indicacao'
  utm_source      VARCHAR(100),
  utm_medium      VARCHAR(100),
  utm_campaign    VARCHAR(100),
  imovel_origem_id UUID         REFERENCES tenant_template.imoveis(id) ON DELETE SET NULL,

  -- PIPELINE
  estagio         VARCHAR(30)   NOT NULL DEFAULT 'novo',      -- 'novo' | 'qualificado' | 'visita_agendada' | 'proposta' | 'documentacao' | 'fechado' | 'perdido'
  motivo_perda    TEXT,

  -- PREFERÊNCIAS (capturadas pelo bot IA)
  interesse       VARCHAR(20)   DEFAULT 'compra',             -- 'compra' | 'aluguel'
  tipo_imovel     TEXT[]        DEFAULT '{}',
  bairros_interesse TEXT[]      DEFAULT '{}',
  preco_min       NUMERIC(15,2),
  preco_max       NUMERIC(15,2),
  quartos_min     SMALLINT,
  area_min        NUMERIC(10,2),
  observacoes     TEXT,

  -- IA
  ai_score        SMALLINT      DEFAULT 0,                    -- 0-100
  ai_perfil       VARCHAR(50),                                -- 'premium' | 'standard' | 'economia'
  ai_qualificado  BOOLEAN       DEFAULT FALSE,
  ai_resumo       TEXT,                                       -- resumo gerado pelo Claude
  embedding       vector(1536),                               -- pgvector para match com imóveis

  -- ATRIBUIÇÃO
  corretor_id     UUID          REFERENCES tenant_template.users(id) ON DELETE SET NULL,
  atribuido_em    TIMESTAMPTZ,

  -- STATUS WHATSAPP
  wpp_ativo       BOOLEAN       DEFAULT TRUE,
  wpp_ultima_msg  TIMESTAMPTZ,
  wpp_opt_out     BOOLEAN       DEFAULT FALSE,

  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_leads_estagio    ON tenant_template.leads(estagio);
CREATE INDEX idx_leads_fonte      ON tenant_template.leads(fonte);
CREATE INDEX idx_leads_corretor   ON tenant_template.leads(corretor_id);
CREATE INDEX idx_leads_ai_score   ON tenant_template.leads(ai_score DESC);
CREATE INDEX idx_leads_telefone   ON tenant_template.leads(telefone);
CREATE INDEX idx_leads_created    ON tenant_template.leads(created_at DESC);


-- ------------------------------------------------------------
-- TIMELINE DE INTERAÇÕES (histórico completo do lead)
-- ------------------------------------------------------------
CREATE TABLE tenant_template.interacoes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id         UUID          NOT NULL REFERENCES tenant_template.leads(id) ON DELETE CASCADE,

  tipo            VARCHAR(30)   NOT NULL,                     -- 'whatsapp_in' | 'whatsapp_out' | 'nota' | 'visita' | 'proposta' | 'sistema' | 'ai' | 'email' | 'ligacao'
  canal           VARCHAR(20)   DEFAULT 'interno',            -- 'whatsapp' | 'email' | 'telefone' | 'presencial' | 'interno'

  titulo          VARCHAR(300),
  conteudo        TEXT          NOT NULL,
  metadata        JSONB         DEFAULT '{}',                 -- dados extras: score_delta, imovel_id, etc.

  autor_id        UUID          REFERENCES tenant_template.users(id) ON DELETE SET NULL,
  autor_tipo      VARCHAR(20)   DEFAULT 'corretor',           -- 'corretor' | 'sistema' | 'ia' | 'cliente'

  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_interacoes_lead    ON tenant_template.interacoes(lead_id, created_at DESC);
CREATE INDEX idx_interacoes_tipo    ON tenant_template.interacoes(tipo);


-- ------------------------------------------------------------
-- MATCHES LEAD ↔ IMÓVEL (gerados pela IA)
-- ------------------------------------------------------------
CREATE TABLE tenant_template.matches (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id         UUID          NOT NULL REFERENCES tenant_template.leads(id) ON DELETE CASCADE,
  imovel_id       UUID          NOT NULL REFERENCES tenant_template.imoveis(id) ON DELETE CASCADE,
  score           NUMERIC(5,2)  NOT NULL,                     -- 0-100
  motivos         TEXT[]        DEFAULT '{}',                 -- ['localização', 'preço', 'dormitórios']
  enviado_lead    BOOLEAN       DEFAULT FALSE,
  enviado_em      TIMESTAMPTZ,
  interesse_lead  VARCHAR(20),                                -- 'positivo' | 'negativo' | 'neutro'
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UNIQUE(lead_id, imovel_id)
);

CREATE INDEX idx_matches_lead   ON tenant_template.matches(lead_id, score DESC);
CREATE INDEX idx_matches_imovel ON tenant_template.matches(imovel_id);


-- ------------------------------------------------------------
-- VISITAS
-- ------------------------------------------------------------
CREATE TABLE tenant_template.visitas (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo          VARCHAR(20)   NOT NULL UNIQUE,              -- 'VIS-0001'
  lead_id         UUID          NOT NULL REFERENCES tenant_template.leads(id) ON DELETE CASCADE,
  imovel_id       UUID          NOT NULL REFERENCES tenant_template.imoveis(id) ON DELETE CASCADE,
  corretor_id     UUID          REFERENCES tenant_template.users(id) ON DELETE SET NULL,

  data_hora       TIMESTAMPTZ   NOT NULL,
  duracao_min     INT           DEFAULT 60,
  status          VARCHAR(20)   NOT NULL DEFAULT 'agendada',  -- 'agendada' | 'confirmada' | 'realizada' | 'cancelada' | 'no_show'

  google_event_id VARCHAR(200),                               -- ID no Google Calendar
  confirmacao_enviada  BOOLEAN  DEFAULT FALSE,
  lembrete_24h_enviado BOOLEAN  DEFAULT FALSE,
  lembrete_1h_enviado  BOOLEAN  DEFAULT FALSE,
  followup_enviado     BOOLEAN  DEFAULT FALSE,
  nps_enviado          BOOLEAN  DEFAULT FALSE,
  nps_score            SMALLINT,                              -- 1-10
  nps_comentario       TEXT,

  observacoes     TEXT,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_visitas_data      ON tenant_template.visitas(data_hora);
CREATE INDEX idx_visitas_status    ON tenant_template.visitas(status);
CREATE INDEX idx_visitas_corretor  ON tenant_template.visitas(corretor_id);
CREATE INDEX idx_visitas_lead      ON tenant_template.visitas(lead_id);


-- ------------------------------------------------------------
-- PROPOSTAS
-- ------------------------------------------------------------
CREATE TABLE tenant_template.propostas (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo          VARCHAR(20)   NOT NULL UNIQUE,              -- 'PROP-0001'
  lead_id         UUID          NOT NULL REFERENCES tenant_template.leads(id) ON DELETE CASCADE,
  imovel_id       UUID          NOT NULL REFERENCES tenant_template.imoveis(id) ON DELETE CASCADE,
  corretor_id     UUID          REFERENCES tenant_template.users(id) ON DELETE SET NULL,

  tipo            VARCHAR(20)   NOT NULL DEFAULT 'compra',    -- 'compra' | 'aluguel'
  valor           NUMERIC(15,2) NOT NULL,
  valor_entrada   NUMERIC(15,2),
  forma_pagamento VARCHAR(50),                                -- 'a_vista' | 'financiamento' | 'fgts' | 'consorcio'
  prazo_validade  DATE,
  status          VARCHAR(30)   NOT NULL DEFAULT 'enviada',   -- 'rascunho' | 'enviada' | 'em_analise' | 'aceita' | 'recusada' | 'expirada'

  -- DOCUMENTAÇÃO
  docs_checklist  JSONB         DEFAULT '[]',                 -- [{nome, obrigatorio, entregue, url}]
  assinatura_url  TEXT,                                       -- ZapSign / DocuSign

  observacoes     TEXT,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_propostas_status  ON tenant_template.propostas(status);
CREATE INDEX idx_propostas_lead    ON tenant_template.propostas(lead_id);


-- ------------------------------------------------------------
-- PORTAIS — INTEGRAÇÕES
-- ------------------------------------------------------------
CREATE TABLE tenant_template.portais_config (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  portal          VARCHAR(50)   NOT NULL UNIQUE,              -- 'zap_imoveis' | 'vivareal' | 'olx' | 'imovelweb' | 'chaves_na_mao'
  ativo           BOOLEAN       NOT NULL DEFAULT FALSE,
  api_key         TEXT,
  api_secret      TEXT,
  webhook_url     TEXT,                                       -- URL que o portal chama ao receber lead
  webhook_secret  TEXT,
  ultimo_sync     TIMESTAMPTZ,
  config          JSONB         DEFAULT '{}',
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Insere portais padrão desativados
INSERT INTO tenant_template.portais_config (portal) VALUES
  ('zap_imoveis'), ('vivareal'), ('olx'), ('imovelweb'), ('chaves_na_mao');


-- ------------------------------------------------------------
-- AUTOMAÇÕES N8N (registro dos fluxos por tenant)
-- ------------------------------------------------------------
CREATE TABLE tenant_template.automacoes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nome            VARCHAR(200)  NOT NULL,
  descricao       TEXT,
  tipo            VARCHAR(50)   NOT NULL,                     -- 'recepcao_lead' | 'atendimento_ia' | 'lembrete_visita' | 'match_ia' | 'relatorio' | 'reengajamento' | 'nps' | 'docs'
  n8n_workflow_id VARCHAR(100),                               -- ID do workflow no N8N
  ativo           BOOLEAN       NOT NULL DEFAULT TRUE,
  config          JSONB         DEFAULT '{}',
  total_execucoes INT           NOT NULL DEFAULT 0,
  total_sucesso   INT           NOT NULL DEFAULT 0,
  total_erros     INT           NOT NULL DEFAULT 0,
  ultima_execucao TIMESTAMPTZ,
  ultimo_status   VARCHAR(20),                                -- 'ok' | 'erro' | 'executando'
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);


-- ------------------------------------------------------------
-- LOG DE EXECUÇÕES DAS AUTOMAÇÕES
-- ------------------------------------------------------------
CREATE TABLE tenant_template.automacoes_log (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  automacao_id    UUID          NOT NULL REFERENCES tenant_template.automacoes(id) ON DELETE CASCADE,
  status          VARCHAR(20)   NOT NULL,                     -- 'ok' | 'erro' | 'skip'
  payload_in      JSONB,
  payload_out     JSONB,
  erro_mensagem   TEXT,
  duracao_ms      INT,
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_log_automacao ON tenant_template.automacoes_log(automacao_id, created_at DESC);
CREATE INDEX idx_log_status    ON tenant_template.automacoes_log(status, created_at DESC);


-- ------------------------------------------------------------
-- CONFIGURAÇÕES DO TENANT
-- ------------------------------------------------------------
CREATE TABLE tenant_template.configuracoes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  chave           VARCHAR(100)  NOT NULL UNIQUE,
  valor           JSONB         NOT NULL DEFAULT '{}',
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

INSERT INTO tenant_template.configuracoes (chave, valor) VALUES
  ('whatsapp',     '{"numero":"","instancia":"","ativo":false}'),
  ('ia',           '{"modelo":"claude-sonnet-4-20250514","temperatura":0.7,"prompt_qualificacao":""}'),
  ('round_robin',  '{"ativo":true,"modo":"sequencial","ignorar_ferias":true}'),
  ('notificacoes', '{"email_relatorio":true,"wpp_novo_lead":true,"wpp_visita":true}'),
  ('portais',      '{"sync_automatico":false,"intervalo_horas":6}'),
  ('empresa',      '{"horario_atendimento":{"inicio":"08:00","fim":"18:00"},"dias_uteis":[1,2,3,4,5]}');


-- ============================================================
-- VIEWS ÚTEIS
-- ============================================================

-- Pipeline Kanban (contagem por estágio)
CREATE VIEW tenant_template.v_pipeline AS
SELECT
  estagio,
  COUNT(*)              AS total,
  SUM(preco_max)        AS vgv_potencial,
  AVG(ai_score)         AS score_medio
FROM tenant_template.leads
WHERE estagio NOT IN ('perdido')
GROUP BY estagio;


-- Performance de corretores (mês atual)
CREATE VIEW tenant_template.v_performance_corretores AS
SELECT
  u.id,
  u.name,
  u.creci,
  u.status,
  COUNT(DISTINCT l.id)   FILTER (WHERE l.corretor_id = u.id)                  AS leads_total,
  COUNT(DISTINCT v.id)   FILTER (WHERE v.corretor_id = u.id)                  AS visitas_mes,
  COUNT(DISTINCT p.id)   FILTER (WHERE p.corretor_id = u.id AND p.status = 'aceita') AS fechamentos_mes,
  COALESCE(SUM(p.valor)  FILTER (WHERE p.corretor_id = u.id AND p.status = 'aceita'), 0) AS vgv_mes,
  ROUND(
    CASE WHEN COUNT(DISTINCT l.id) FILTER (WHERE l.corretor_id = u.id) > 0
    THEN COUNT(DISTINCT p.id) FILTER (WHERE p.corretor_id = u.id AND p.status = 'aceita') * 100.0
       / COUNT(DISTINCT l.id) FILTER (WHERE l.corretor_id = u.id)
    ELSE 0 END, 2
  ) AS taxa_conversao
FROM tenant_template.users u
LEFT JOIN tenant_template.leads    l ON l.corretor_id = u.id AND DATE_TRUNC('month', l.created_at) = DATE_TRUNC('month', NOW())
LEFT JOIN tenant_template.visitas  v ON v.corretor_id = u.id AND DATE_TRUNC('month', v.data_hora)  = DATE_TRUNC('month', NOW())
LEFT JOIN tenant_template.propostas p ON p.corretor_id = u.id AND DATE_TRUNC('month', p.created_at) = DATE_TRUNC('month', NOW())
WHERE u.role IN ('corretor', 'gerente')
GROUP BY u.id, u.name, u.creci, u.status
ORDER BY vgv_mes DESC;


-- Funil de conversão (mês atual)
CREATE VIEW tenant_template.v_funil_mes AS
SELECT
  estagio,
  COUNT(*) AS total,
  ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 1) AS pct
FROM tenant_template.leads
WHERE DATE_TRUNC('month', created_at) = DATE_TRUNC('month', NOW())
GROUP BY estagio;


-- ============================================================
-- TRIGGERS — auto updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Aplica em todas as tabelas com updated_at
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'tenant_template.users',
    'tenant_template.imoveis',
    'tenant_template.leads',
    'tenant_template.visitas',
    'tenant_template.propostas',
    'tenant_template.automacoes',
    'tenant_template.portais_config',
    'tenant_template.configuracoes'
  ]
  LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_updated_at BEFORE UPDATE ON %s
       FOR EACH ROW EXECUTE FUNCTION public.update_updated_at()', t
    );
  END LOOP;
END $$;


-- ============================================================
-- ÍNDICES ADICIONAIS — performance
-- ============================================================
CREATE INDEX idx_leads_wpp_ultima  ON tenant_template.leads(wpp_ultima_msg DESC NULLS LAST);
CREATE INDEX idx_imoveis_updated   ON tenant_template.imoveis(updated_at DESC);
CREATE INDEX idx_propostas_updated ON tenant_template.propostas(updated_at DESC);


-- ============================================================
-- ROW LEVEL SECURITY (RLS) — isolamento por tenant
-- ============================================================
ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;

-- Apenas o próprio tenant pode ver seus dados
-- (implementar via JWT claims: current_setting('app.tenant_id'))
CREATE POLICY tenant_isolation ON public.tenants
  USING (id::TEXT = current_setting('app.tenant_id', TRUE));


-- ============================================================
-- EXTENSÕES NECESSÁRIAS
-- ============================================================
-- Executar antes de criar o schema:
-- CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
-- CREATE EXTENSION IF NOT EXISTS "vector";        -- pgvector para match IA
-- CREATE EXTENSION IF NOT EXISTS "pg_trgm";       -- busca por similaridade de texto
-- CREATE EXTENSION IF NOT EXISTS "unaccent";      -- busca sem acentos


-- ============================================================
-- FIM DO SCHEMA — NEXUS IMOB v1.0
-- ============================================================
