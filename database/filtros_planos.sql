-- ============================================================
-- CULTIVAI — PLANO (mensal/anual) E FILTRO DE DATA NOS PAINEIS
-- Rodar no SQL Editor do Supabase, depois dos scripts anteriores.
-- ============================================================

-- 1) Guarda o periodo da assinatura em cada comissao
ALTER TABLE comissoes ADD COLUMN IF NOT EXISTS periodo TEXT;

-- Para as comissoes que ja existem, deduz pelo valor: anual custa
-- bem mais que mensal, entao o corte em R$ 100 separa os dois com folga.
UPDATE comissoes SET periodo = CASE WHEN valor_bruto >= 100 THEN 'anual' ELSE 'mensal' END
 WHERE periodo IS NULL;

-- 2) Registrar comissao agora aceita o periodo vindo do Stripe
CREATE OR REPLACE FUNCTION rpc_registrar_comissao(
  p_segredo TEXT, p_usuario_id UUID, p_customer_id TEXT, p_invoice_id TEXT,
  p_valor_bruto NUMERIC, p_taxa_stripe NUMERIC, p_pago_em TIMESTAMPTZ,
  p_periodo TEXT DEFAULT NULL
) RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE
  v_codigo TEXT; v_pct NUMERIC; v_meses INT; v_ativo BOOLEAN;
  v_primeira TIMESTAMPTZ; v_liquido NUMERIC; v_comissao NUMERIC; v_per TEXT;
BEGIN
  IF p_segredo IS DISTINCT FROM (SELECT valor FROM privado.config WHERE chave = 'webhook_segredo') THEN
    RETURN json_build_object('ok', false, 'motivo', 'segredo_invalido');
  END IF;

  SELECT afiliado_codigo INTO v_codigo FROM usuarios WHERE id = p_usuario_id;
  IF v_codigo IS NULL THEN RETURN json_build_object('ok', false, 'motivo', 'sem_afiliado'); END IF;

  SELECT pct_comissao, meses_comissao, ativo INTO v_pct, v_meses, v_ativo FROM afiliados WHERE codigo = v_codigo;
  IF v_pct IS NULL THEN RETURN json_build_object('ok', false, 'motivo', 'afiliado_inexistente'); END IF;

  SELECT MIN(criado_em) INTO v_primeira FROM comissoes WHERE usuario_id = p_usuario_id;
  IF v_primeira IS NOT NULL AND p_pago_em > v_primeira + (v_meses || ' months')::INTERVAL THEN
    RETURN json_build_object('ok', false, 'motivo', 'fora_da_janela');
  END IF;

  v_liquido  := GREATEST(p_valor_bruto - COALESCE(p_taxa_stripe, 0), 0);
  v_comissao := ROUND(v_liquido * v_pct / 100, 2);
  v_per := COALESCE(nullif(p_periodo,''), CASE WHEN p_valor_bruto >= 100 THEN 'anual' ELSE 'mensal' END);

  INSERT INTO comissoes (afiliado_codigo, usuario_id, stripe_invoice_id, stripe_customer_id,
                         valor_bruto, taxa_stripe, valor_liquido, pct, valor_comissao, criado_em, periodo)
  VALUES (v_codigo, p_usuario_id, p_invoice_id, p_customer_id,
          p_valor_bruto, COALESCE(p_taxa_stripe,0), v_liquido, v_pct, v_comissao,
          COALESCE(p_pago_em, NOW()), v_per)
  ON CONFLICT (stripe_invoice_id) DO NOTHING;

  RETURN json_build_object('ok', true, 'comissao', v_comissao, 'afiliado', v_codigo);
END $$;
GRANT EXECUTE ON FUNCTION rpc_registrar_comissao(TEXT, UUID, TEXT, TEXT, NUMERIC, NUMERIC, TIMESTAMPTZ, TEXT) TO anon;

-- 3) Numeros de um embaixador, com recorte de data opcional (p_dias NULL = tudo)
CREATE OR REPLACE FUNCTION _numeros_afiliado(p_codigo TEXT, p_dias INT)
RETURNS JSON LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT json_build_object(
    'cliques', (SELECT COUNT(*) FROM afiliado_cliques c
        WHERE c.codigo = p_codigo
          AND (p_dias IS NULL OR c.criado_em > NOW() - (p_dias || ' days')::INTERVAL)),
    'cadastros', (SELECT COUNT(*) FROM usuarios u
        WHERE u.afiliado_codigo = p_codigo
          AND (p_dias IS NULL OR COALESCE(u.afiliado_atribuido_em, NOW()) > NOW() - (p_dias || ' days')::INTERVAL)),
    'assinantes', (SELECT COUNT(DISTINCT co.usuario_id) FROM comissoes co
        WHERE co.afiliado_codigo = p_codigo AND co.status <> 'estornado'
          AND (p_dias IS NULL OR co.criado_em > NOW() - (p_dias || ' days')::INTERVAL)),
    'assinantes_mensal', (SELECT COUNT(DISTINCT co.usuario_id) FROM comissoes co
        WHERE co.afiliado_codigo = p_codigo AND co.status <> 'estornado' AND COALESCE(co.periodo,'mensal') = 'mensal'
          AND (p_dias IS NULL OR co.criado_em > NOW() - (p_dias || ' days')::INTERVAL)),
    'assinantes_anual', (SELECT COUNT(DISTINCT co.usuario_id) FROM comissoes co
        WHERE co.afiliado_codigo = p_codigo AND co.status <> 'estornado' AND co.periodo = 'anual'
          AND (p_dias IS NULL OR co.criado_em > NOW() - (p_dias || ' days')::INTERVAL)),
    'pendente', (SELECT COALESCE(SUM(valor_comissao),0) FROM comissoes
        WHERE afiliado_codigo = p_codigo AND status = 'pendente'
          AND (p_dias IS NULL OR criado_em > NOW() - (p_dias || ' days')::INTERVAL)),
    'pago', (SELECT COALESCE(SUM(valor_comissao),0) FROM comissoes
        WHERE afiliado_codigo = p_codigo AND status = 'pago'
          AND (p_dias IS NULL OR criado_em > NOW() - (p_dias || ' days')::INTERVAL)),
    'total', (SELECT COALESCE(SUM(valor_comissao),0) FROM comissoes
        WHERE afiliado_codigo = p_codigo AND status <> 'estornado'
          AND (p_dias IS NULL OR criado_em > NOW() - (p_dias || ' days')::INTERVAL))
  );
$$;

-- 4) Painel do embaixador com filtro
CREATE OR REPLACE FUNCTION rpc_afiliado_painel(p_dias INT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_email TEXT := lower(coalesce(auth.jwt()->>'email','')); a afiliados%ROWTYPE; n JSON;
BEGIN
  SELECT * INTO a FROM afiliados WHERE lower(email) = v_email LIMIT 1;
  IF a.id IS NULL THEN RETURN NULL; END IF;
  n := _numeros_afiliado(a.codigo, p_dias);

  RETURN json_build_object(
    'codigo', a.codigo, 'nome', a.nome, 'pct', a.pct_comissao, 'meses', a.meses_comissao,
    'pix', a.pix_chave, 'ativo', a.ativo,
    'cliques', n->'cliques', 'cadastros', n->'cadastros',
    'assinantes', n->'assinantes',
    'assinantes_mensal', n->'assinantes_mensal', 'assinantes_anual', n->'assinantes_anual',
    'pendente', n->'pendente', 'pago', n->'pago', 'total', n->'total',
    'ativos', (SELECT COUNT(*) FROM usuarios WHERE afiliado_codigo = a.codigo AND plano_atual = 'pro'),
    'meses_lista', (SELECT COALESCE(json_agg(m ORDER BY m.mes DESC), '[]'::json) FROM (
        SELECT to_char(date_trunc('month', criado_em), 'YYYY-MM') AS mes,
               SUM(CASE WHEN status <> 'estornado' THEN valor_comissao ELSE 0 END) AS comissao,
               SUM(CASE WHEN status <> 'estornado' THEN valor_liquido ELSE 0 END) AS liquido,
               COUNT(*) FILTER (WHERE status <> 'estornado') AS faturas
        FROM comissoes WHERE afiliado_codigo = a.codigo
          AND (p_dias IS NULL OR criado_em > NOW() - (p_dias || ' days')::INTERVAL)
        GROUP BY 1 ORDER BY 1 DESC LIMIT 12) m),
    'ultimas', (SELECT COALESCE(json_agg(u), '[]'::json) FROM (
        SELECT criado_em, valor_bruto, taxa_stripe, valor_liquido, valor_comissao, status, periodo,
               right(stripe_invoice_id, 8) AS ref
        FROM comissoes WHERE afiliado_codigo = a.codigo
          AND (p_dias IS NULL OR criado_em > NOW() - (p_dias || ' days')::INTERVAL)
        ORDER BY criado_em DESC LIMIT 30) u)
  );
END $$;
GRANT EXECUTE ON FUNCTION rpc_afiliado_painel(INT) TO authenticated;

-- 5) Previa do admin, com o mesmo filtro
CREATE OR REPLACE FUNCTION rpc_admin_painel_como(p_codigo TEXT, p_dias INT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a afiliados%ROWTYPE; n JSON;
BEGIN
  IF NOT eh_admin() THEN RETURN NULL; END IF;
  SELECT * INTO a FROM afiliados WHERE codigo = lower(p_codigo) LIMIT 1;
  IF a.id IS NULL THEN RETURN NULL; END IF;
  n := _numeros_afiliado(a.codigo, p_dias);

  RETURN json_build_object(
    'codigo', a.codigo, 'nome', a.nome, 'pct', a.pct_comissao, 'meses', a.meses_comissao,
    'pix', a.pix_chave, 'ativo', a.ativo,
    'cliques', n->'cliques', 'cadastros', n->'cadastros',
    'assinantes', n->'assinantes',
    'assinantes_mensal', n->'assinantes_mensal', 'assinantes_anual', n->'assinantes_anual',
    'pendente', n->'pendente', 'pago', n->'pago', 'total', n->'total',
    'ativos', (SELECT COUNT(*) FROM usuarios WHERE afiliado_codigo = a.codigo AND plano_atual = 'pro'),
    'meses_lista', (SELECT COALESCE(json_agg(m ORDER BY m.mes DESC), '[]'::json) FROM (
        SELECT to_char(date_trunc('month', criado_em), 'YYYY-MM') AS mes,
               SUM(CASE WHEN status <> 'estornado' THEN valor_comissao ELSE 0 END) AS comissao,
               SUM(CASE WHEN status <> 'estornado' THEN valor_liquido ELSE 0 END) AS liquido,
               COUNT(*) FILTER (WHERE status <> 'estornado') AS faturas
        FROM comissoes WHERE afiliado_codigo = a.codigo
          AND (p_dias IS NULL OR criado_em > NOW() - (p_dias || ' days')::INTERVAL)
        GROUP BY 1 ORDER BY 1 DESC LIMIT 12) m),
    'ultimas', (SELECT COALESCE(json_agg(u), '[]'::json) FROM (
        SELECT criado_em, valor_bruto, taxa_stripe, valor_liquido, valor_comissao, status, periodo,
               right(stripe_invoice_id, 8) AS ref
        FROM comissoes WHERE afiliado_codigo = a.codigo
          AND (p_dias IS NULL OR criado_em > NOW() - (p_dias || ' days')::INTERVAL)
        ORDER BY criado_em DESC LIMIT 30) u)
  );
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_painel_como(TEXT, INT) TO authenticated;

-- 6) Painel do admin com filtro e separacao mensal/anual
CREATE OR REPLACE FUNCTION rpc_admin_painel(p_dias INT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r JSON;
BEGIN
  IF NOT eh_admin() THEN RETURN NULL; END IF;

  SELECT json_build_object(
    'total_pendente', (SELECT COALESCE(SUM(valor_comissao),0) FROM comissoes
        WHERE status='pendente' AND (p_dias IS NULL OR criado_em > NOW() - (p_dias || ' days')::INTERVAL)),
    'total_pago', (SELECT COALESCE(SUM(valor_comissao),0) FROM comissoes
        WHERE status='pago' AND (p_dias IS NULL OR criado_em > NOW() - (p_dias || ' days')::INTERVAL)),
    'total_liquido', (SELECT COALESCE(SUM(valor_liquido),0) FROM comissoes
        WHERE status<>'estornado' AND (p_dias IS NULL OR criado_em > NOW() - (p_dias || ' days')::INTERVAL)),
    'embaixadores', (SELECT COALESCE(json_agg(e ORDER BY e.pendente DESC, e.nome), '[]'::json) FROM (
        SELECT a.id, a.codigo, a.nome, a.email, a.pix_chave, a.pct_comissao, a.meses_comissao,
               a.ativo, a.criado_em,
               (n->>'cliques')::BIGINT AS cliques,
               (n->>'cadastros')::BIGINT AS cadastros,
               (n->>'assinantes')::BIGINT AS assinantes,
               (n->>'assinantes_mensal')::BIGINT AS assinantes_mensal,
               (n->>'assinantes_anual')::BIGINT AS assinantes_anual,
               (n->>'pendente')::NUMERIC AS pendente,
               (n->>'pago')::NUMERIC AS pago
        FROM afiliados a
        CROSS JOIN LATERAL _numeros_afiliado(a.codigo, p_dias) AS n) e)
  ) INTO r;
  RETURN r;
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_painel(INT) TO authenticated;
