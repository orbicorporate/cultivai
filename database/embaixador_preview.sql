-- ============================================================
-- CULTIVAI — VER O PAINEL DO EMBAIXADOR COMO ADMIN
-- Rodar no SQL Editor do Supabase, depois dos outros dois scripts.
-- ============================================================

-- Devolve exatamente os mesmos dados que o embaixador ve no painel dele,
-- mas para um codigo escolhido. So funciona para quem esta em app_admins.
CREATE OR REPLACE FUNCTION rpc_admin_painel_como(p_codigo TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE a afiliados%ROWTYPE; r JSON;
BEGIN
  IF NOT eh_admin() THEN RETURN NULL; END IF;

  SELECT * INTO a FROM afiliados WHERE codigo = lower(p_codigo) LIMIT 1;
  IF a.id IS NULL THEN RETURN NULL; END IF;

  SELECT json_build_object(
    'codigo', a.codigo, 'nome', a.nome, 'pct', a.pct_comissao,
    'meses', a.meses_comissao, 'pix', a.pix_chave, 'ativo', a.ativo,
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
GRANT EXECUTE ON FUNCTION rpc_admin_painel_como(TEXT) TO authenticated;
