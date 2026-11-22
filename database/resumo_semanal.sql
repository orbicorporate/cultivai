-- Resumo semanal da Easy (push de segunda-feira)
-- Roda como SECURITY DEFINER porque o cron usa a chave anon e precisa enxergar todos os usuários com push ativo.
-- Rode este arquivo no SQL Editor do Supabase (projeto do CultivAI) uma vez.

CREATE OR REPLACE FUNCTION public.rpc_resumo_semanal_dados()
RETURNS TABLE (
  usuario_id UUID,
  endpoint TEXT,
  p256dh TEXT,
  auth TEXT,
  nome TEXT,
  planos JSON,
  progresso JSON,
  sims JSON,
  gastos_cultura JSON,
  vendas_cultura JSON,
  gastos_7d NUMERIC,
  vendas_7d NUMERIC,
  a_pagar_7d NUMERIC,
  a_receber_7d NUMERIC,
  lembretes_atrasados INTEGER
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ps.usuario_id,
    ps.endpoint,
    ps.p256dh,
    ps.auth,
    u.nome,
    (SELECT json_agg(json_build_object('cultura', p.cultura_nome, 'inicio', p.data_inicio))
       FROM planos_inicio p WHERE p.usuario_id = ps.usuario_id) AS planos,
    (SELECT json_agg(json_build_object('cultura', pp.cultura_nome, 'etapa', pp.etapa_id, 'feito', pp.feito))
       FROM plano_progresso pp WHERE pp.usuario_id = ps.usuario_id) AS progresso,
    (SELECT json_agg(json_build_object('cultura', x.cultura_nome, 'custo', x.custo_total, 'lucro', x.lucro_safra, 'receita', x.receita_total))
       FROM (SELECT DISTINCT ON (si.cultura_nome) si.cultura_nome, si.custo_total, si.lucro_safra, si.receita_total
               FROM simulacoes si WHERE si.usuario_id = ps.usuario_id
              ORDER BY si.cultura_nome, si.criado_em DESC) x) AS sims,
    (SELECT json_agg(json_build_object('cultura', g.cultura_nome, 'total', g.t))
       FROM (SELECT e.cultura_nome, SUM(e.valor) t FROM expenses e WHERE e.usuario_id = ps.usuario_id GROUP BY e.cultura_nome) g) AS gastos_cultura,
    (SELECT json_agg(json_build_object('cultura', v.cultura_nome, 'total', v.t))
       FROM (SELECT s.cultura_nome, SUM(s.valor_total) t FROM sales s WHERE s.usuario_id = ps.usuario_id GROUP BY s.cultura_nome) v) AS vendas_cultura,
    (SELECT COALESCE(SUM(e.valor), 0) FROM expenses e WHERE e.usuario_id = ps.usuario_id AND e.data >= CURRENT_DATE - 7 AND e.data <= CURRENT_DATE) AS gastos_7d,
    (SELECT COALESCE(SUM(s.valor_total), 0) FROM sales s WHERE s.usuario_id = ps.usuario_id AND s.data >= CURRENT_DATE - 7 AND s.data <= CURRENT_DATE) AS vendas_7d,
    (SELECT COALESCE(SUM(e.valor), 0) FROM expenses e WHERE e.usuario_id = ps.usuario_id AND e.status_pagamento = 'pendente' AND e.data <= CURRENT_DATE + 7) AS a_pagar_7d,
    (SELECT COALESCE(SUM(s.valor_total), 0) FROM sales s WHERE s.usuario_id = ps.usuario_id AND s.status_pagamento = 'a_receber' AND s.data <= CURRENT_DATE + 7) AS a_receber_7d,
    (SELECT COUNT(*)::INTEGER FROM lembretes l WHERE l.usuario_id = ps.usuario_id AND l.feito = FALSE AND l.data < CURRENT_DATE) AS lembretes_atrasados
  FROM push_subscriptions ps
  JOIN usuarios u ON u.id = ps.usuario_id;
$$;

REVOKE ALL ON FUNCTION public.rpc_resumo_semanal_dados() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_resumo_semanal_dados() TO anon, authenticated, service_role;
