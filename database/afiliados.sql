-- ============================================================
-- CULTIVAI — PROGRAMA DE AFILIADOS
-- Rodar no SQL Editor do Supabase (projeto arztmxqslyfcuzlnlatb)
-- ============================================================

-- 1) Afiliados (você cadastra na aba Table Editor)
CREATE TABLE IF NOT EXISTS afiliados (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo          TEXT NOT NULL UNIQUE,            -- ex: 'joao' -> cultivai.app/?ref=joao
  nome            TEXT NOT NULL,
  email           TEXT NOT NULL,                   -- e-mail que ele usa pra logar no app e ver o painel
  pix_chave       TEXT,
  pct_comissao    NUMERIC(5,2) NOT NULL DEFAULT 30,
  meses_comissao  INT NOT NULL DEFAULT 12,
  ativo           BOOLEAN NOT NULL DEFAULT TRUE,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_afiliados_email ON afiliados (lower(email));

-- 2) Cliques no link
CREATE TABLE IF NOT EXISTS afiliado_cliques (
  id              BIGSERIAL PRIMARY KEY,
  codigo          TEXT NOT NULL,
  criado_em       TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_cliques_codigo ON afiliado_cliques (codigo, criado_em DESC);

-- 3) Comissões (alimentada só pelo webhook do Stripe)
CREATE TABLE IF NOT EXISTS comissoes (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  afiliado_codigo     TEXT NOT NULL,
  usuario_id          UUID NOT NULL,
  stripe_invoice_id   TEXT NOT NULL UNIQUE,
  stripe_customer_id  TEXT,
  valor_bruto         NUMERIC(12,2) NOT NULL,
  taxa_stripe         NUMERIC(12,2) NOT NULL DEFAULT 0,
  valor_liquido       NUMERIC(12,2) NOT NULL,
  pct                 NUMERIC(5,2) NOT NULL,
  valor_comissao      NUMERIC(12,2) NOT NULL,
  status              TEXT NOT NULL DEFAULT 'pendente' CHECK (status IN ('pendente','pago','estornado')),
  pago_em             TIMESTAMPTZ,
  criado_em           TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_comissoes_afiliado ON comissoes (afiliado_codigo, criado_em DESC);
CREATE INDEX IF NOT EXISTS idx_comissoes_usuario ON comissoes (usuario_id, criado_em);

-- 4) Atribuição no usuário
ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS afiliado_codigo TEXT;
ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS afiliado_atribuido_em TIMESTAMPTZ;

-- 5) Segredo do webhook (schema privado, fora da API)
CREATE SCHEMA IF NOT EXISTS privado;
CREATE TABLE IF NOT EXISTS privado.config (chave TEXT PRIMARY KEY, valor TEXT NOT NULL);
INSERT INTO privado.config (chave, valor) VALUES ('webhook_segredo', 'cv_wh_9f3e2a71c4d84b0e8a6f5d2c1b7e9a03')
  ON CONFLICT (chave) DO NOTHING;

-- 6) RLS
ALTER TABLE afiliados       ENABLE ROW LEVEL SECURITY;
ALTER TABLE afiliado_cliques ENABLE ROW LEVEL SECURITY;
ALTER TABLE comissoes       ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS afiliados_self ON afiliados;
CREATE POLICY afiliados_self ON afiliados FOR SELECT TO authenticated
  USING (lower(email) = lower(coalesce(auth.jwt()->>'email','')));

DROP POLICY IF EXISTS comissoes_do_afiliado ON comissoes;
CREATE POLICY comissoes_do_afiliado ON comissoes FOR SELECT TO authenticated
  USING (afiliado_codigo IN (SELECT codigo FROM afiliados WHERE lower(email) = lower(coalesce(auth.jwt()->>'email',''))));

-- 7) Registrar clique (público, sem login)
CREATE OR REPLACE FUNCTION rpc_afiliado_clique(p_codigo TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM afiliados WHERE codigo = lower(p_codigo) AND ativo) THEN
    INSERT INTO afiliado_cliques (codigo) VALUES (lower(p_codigo));
  END IF;
END $$;
GRANT EXECUTE ON FUNCTION rpc_afiliado_clique(TEXT) TO anon, authenticated;

-- 8) Vincular afiliado ao usuário logado (só uma vez; código precisa existir e estar ativo)
CREATE OR REPLACE FUNCTION rpc_vincular_afiliado(p_codigo TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN FALSE; END IF;
  IF NOT EXISTS (SELECT 1 FROM afiliados WHERE codigo = lower(p_codigo) AND ativo) THEN RETURN FALSE; END IF;
  -- afiliado não pode se auto-indicar
  IF EXISTS (SELECT 1 FROM afiliados WHERE codigo = lower(p_codigo) AND lower(email) = lower(coalesce(auth.jwt()->>'email',''))) THEN RETURN FALSE; END IF;
  UPDATE usuarios SET afiliado_codigo = lower(p_codigo), afiliado_atribuido_em = NOW()
    WHERE id = v_uid AND afiliado_codigo IS NULL;
  RETURN FOUND;
END $$;
GRANT EXECUTE ON FUNCTION rpc_vincular_afiliado(TEXT) TO authenticated;

-- 9) Registrar comissão (chamada pelo webhook do Stripe, protegida por segredo)
CREATE OR REPLACE FUNCTION rpc_registrar_comissao(
  p_segredo TEXT, p_usuario_id UUID, p_customer_id TEXT, p_invoice_id TEXT,
  p_valor_bruto NUMERIC, p_taxa_stripe NUMERIC, p_pago_em TIMESTAMPTZ
) RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE
  v_codigo TEXT; v_pct NUMERIC; v_meses INT; v_ativo BOOLEAN;
  v_primeira TIMESTAMPTZ; v_liquido NUMERIC; v_comissao NUMERIC;
BEGIN
  IF p_segredo IS DISTINCT FROM (SELECT valor FROM privado.config WHERE chave = 'webhook_segredo') THEN
    RETURN json_build_object('ok', false, 'motivo', 'segredo_invalido');
  END IF;

  SELECT afiliado_codigo INTO v_codigo FROM usuarios WHERE id = p_usuario_id;
  IF v_codigo IS NULL THEN RETURN json_build_object('ok', false, 'motivo', 'sem_afiliado'); END IF;

  SELECT pct_comissao, meses_comissao, ativo INTO v_pct, v_meses, v_ativo FROM afiliados WHERE codigo = v_codigo;
  IF v_pct IS NULL THEN RETURN json_build_object('ok', false, 'motivo', 'afiliado_inexistente'); END IF;

  -- janela de N meses contada a partir da primeira fatura paga desse usuário
  SELECT MIN(criado_em) INTO v_primeira FROM comissoes WHERE usuario_id = p_usuario_id;
  IF v_primeira IS NOT NULL AND p_pago_em > v_primeira + (v_meses || ' months')::INTERVAL THEN
    RETURN json_build_object('ok', false, 'motivo', 'fora_da_janela');
  END IF;

  v_liquido  := GREATEST(p_valor_bruto - COALESCE(p_taxa_stripe, 0), 0);
  v_comissao := ROUND(v_liquido * v_pct / 100, 2);

  INSERT INTO comissoes (afiliado_codigo, usuario_id, stripe_invoice_id, stripe_customer_id,
                         valor_bruto, taxa_stripe, valor_liquido, pct, valor_comissao, criado_em)
  VALUES (v_codigo, p_usuario_id, p_invoice_id, p_customer_id,
          p_valor_bruto, COALESCE(p_taxa_stripe,0), v_liquido, v_pct, v_comissao, COALESCE(p_pago_em, NOW()))
  ON CONFLICT (stripe_invoice_id) DO NOTHING;

  RETURN json_build_object('ok', true, 'comissao', v_comissao, 'afiliado', v_codigo);
END $$;
GRANT EXECUTE ON FUNCTION rpc_registrar_comissao(TEXT, UUID, TEXT, TEXT, NUMERIC, NUMERIC, TIMESTAMPTZ) TO anon;

-- 10) Estornar comissão (reembolso / chargeback)
CREATE OR REPLACE FUNCTION rpc_estornar_comissao(p_segredo TEXT, p_invoice_id TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
BEGIN
  IF p_segredo IS DISTINCT FROM (SELECT valor FROM privado.config WHERE chave = 'webhook_segredo') THEN RETURN FALSE; END IF;
  UPDATE comissoes SET status = 'estornado' WHERE stripe_invoice_id = p_invoice_id AND status <> 'estornado';
  RETURN FOUND;
END $$;
GRANT EXECUTE ON FUNCTION rpc_estornar_comissao(TEXT, TEXT) TO anon;

-- 11) Painel do afiliado logado
CREATE OR REPLACE FUNCTION rpc_afiliado_painel()
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_email TEXT := lower(coalesce(auth.jwt()->>'email','')); a afiliados%ROWTYPE; r JSON;
BEGIN
  SELECT * INTO a FROM afiliados WHERE lower(email) = v_email LIMIT 1;
  IF a.id IS NULL THEN RETURN NULL; END IF;

  SELECT json_build_object(
    'codigo', a.codigo, 'nome', a.nome, 'pct', a.pct_comissao, 'meses', a.meses_comissao, 'pix', a.pix_chave, 'ativo', a.ativo,
    'cliques', (SELECT COUNT(*) FROM afiliado_cliques WHERE codigo = a.codigo),
    'cliques_30d', (SELECT COUNT(*) FROM afiliado_cliques WHERE codigo = a.codigo AND criado_em > NOW() - INTERVAL '30 days'),
    'cadastros', (SELECT COUNT(*) FROM usuarios WHERE afiliado_codigo = a.codigo),
    'assinantes', (SELECT COUNT(DISTINCT usuario_id) FROM comissoes WHERE afiliado_codigo = a.codigo AND status <> 'estornado'),
    'ativos', (SELECT COUNT(*) FROM usuarios WHERE afiliado_codigo = a.codigo AND plano_atual = 'pro'),
    'pendente', (SELECT COALESCE(SUM(valor_comissao),0) FROM comissoes WHERE afiliado_codigo = a.codigo AND status = 'pendente'),
    'pago', (SELECT COALESCE(SUM(valor_comissao),0) FROM comissoes WHERE afiliado_codigo = a.codigo AND status = 'pago'),
    'total', (SELECT COALESCE(SUM(valor_comissao),0) FROM comissoes WHERE afiliado_codigo = a.codigo AND status <> 'estornado'),
    'meses_lista', (SELECT COALESCE(json_agg(m ORDER BY m.mes DESC), '[]'::json) FROM (
        SELECT to_char(date_trunc('month', criado_em), 'YYYY-MM') AS mes,
               SUM(CASE WHEN status <> 'estornado' THEN valor_comissao ELSE 0 END) AS comissao,
               SUM(CASE WHEN status <> 'estornado' THEN valor_liquido ELSE 0 END) AS liquido,
               COUNT(*) FILTER (WHERE status <> 'estornado') AS faturas
        FROM comissoes WHERE afiliado_codigo = a.codigo GROUP BY 1 ORDER BY 1 DESC LIMIT 12) m),
    'ultimas', (SELECT COALESCE(json_agg(u), '[]'::json) FROM (
        SELECT criado_em, valor_bruto, taxa_stripe, valor_liquido, valor_comissao, status,
               right(stripe_invoice_id, 8) AS ref
        FROM comissoes WHERE afiliado_codigo = a.codigo ORDER BY criado_em DESC LIMIT 30) u)
  ) INTO r;
  RETURN r;
END $$;
GRANT EXECUTE ON FUNCTION rpc_afiliado_painel() TO authenticated;
