-- ============================================================
-- CULTIVAI — PAINEL DE ADMINISTRACAO DOS EMBAIXADORES
-- Rodar no SQL Editor do Supabase (projeto do CultivAI)
-- Depende de database/afiliados.sql, que ja foi aplicado.
-- ============================================================

-- 1) Quem pode administrar o programa.
--    ATENCAO: troque o e-mail abaixo se voce entra no app com outro e-mail.
CREATE TABLE IF NOT EXISTS app_admins (
  email     TEXT PRIMARY KEY,
  criado_em TIMESTAMPTZ DEFAULT NOW()
);
INSERT INTO app_admins (email) VALUES ('pedrobruder11@gmail.com')
  ON CONFLICT (email) DO NOTHING;

ALTER TABLE app_admins ENABLE ROW LEVEL SECURITY;  -- sem policy = ninguem le direto

CREATE OR REPLACE FUNCTION eh_admin()
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM app_admins
    WHERE lower(email) = lower(coalesce(auth.jwt()->>'email',''))
  );
$$;
GRANT EXECUTE ON FUNCTION eh_admin() TO authenticated;

-- 2) Painel do admin: lista de embaixadores com os numeros de cada um
CREATE OR REPLACE FUNCTION rpc_admin_painel()
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r JSON;
BEGIN
  IF NOT eh_admin() THEN RETURN NULL; END IF;

  SELECT json_build_object(
    'total_pendente', (SELECT COALESCE(SUM(valor_comissao),0) FROM comissoes WHERE status='pendente'),
    'total_pago',     (SELECT COALESCE(SUM(valor_comissao),0) FROM comissoes WHERE status='pago'),
    'total_liquido',  (SELECT COALESCE(SUM(valor_liquido),0)  FROM comissoes WHERE status<>'estornado'),
    'embaixadores', (SELECT COALESCE(json_agg(e ORDER BY e.pendente DESC, e.nome), '[]'::json) FROM (
        SELECT a.id, a.codigo, a.nome, a.email, a.pix_chave, a.pct_comissao, a.meses_comissao,
               a.ativo, a.criado_em,
               (SELECT COUNT(*) FROM afiliado_cliques c WHERE c.codigo=a.codigo) AS cliques,
               (SELECT COUNT(*) FROM usuarios u WHERE u.afiliado_codigo=a.codigo) AS cadastros,
               (SELECT COUNT(DISTINCT co.usuario_id) FROM comissoes co
                  WHERE co.afiliado_codigo=a.codigo AND co.status<>'estornado') AS assinantes,
               (SELECT COALESCE(SUM(co.valor_comissao),0) FROM comissoes co
                  WHERE co.afiliado_codigo=a.codigo AND co.status='pendente') AS pendente,
               (SELECT COALESCE(SUM(co.valor_comissao),0) FROM comissoes co
                  WHERE co.afiliado_codigo=a.codigo AND co.status='pago') AS pago
        FROM afiliados a) e)
  ) INTO r;
  RETURN r;
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_painel() TO authenticated;

-- 3) Cadastrar embaixador
CREATE OR REPLACE FUNCTION rpc_admin_criar_embaixador(
  p_nome TEXT, p_email TEXT, p_codigo TEXT, p_pix TEXT DEFAULT NULL,
  p_pct NUMERIC DEFAULT 30, p_meses INT DEFAULT 12
) RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cod TEXT;
BEGIN
  IF NOT eh_admin() THEN RETURN json_build_object('ok',false,'erro','sem_permissao'); END IF;
  v_cod := lower(trim(p_codigo));
  IF v_cod !~ '^[a-z0-9_-]{2,40}$' THEN
    RETURN json_build_object('ok',false,'erro','Código inválido. Use apenas letras, números, hífen ou underline (2 a 40 caracteres).');
  END IF;
  IF trim(coalesce(p_nome,'')) = '' THEN
    RETURN json_build_object('ok',false,'erro','Informe o nome do embaixador.');
  END IF;
  IF trim(coalesce(p_email,'')) = '' OR p_email !~ '^[^@]+@[^@]+\.[^@]+$' THEN
    RETURN json_build_object('ok',false,'erro','Informe um e-mail válido — é com ele que o embaixador entra no painel.');
  END IF;
  IF EXISTS (SELECT 1 FROM afiliados WHERE codigo = v_cod) THEN
    RETURN json_build_object('ok',false,'erro','Já existe um embaixador com esse código.');
  END IF;
  IF EXISTS (SELECT 1 FROM afiliados WHERE lower(email) = lower(trim(p_email))) THEN
    RETURN json_build_object('ok',false,'erro','Já existe um embaixador com esse e-mail.');
  END IF;

  INSERT INTO afiliados (codigo, nome, email, pix_chave, pct_comissao, meses_comissao, ativo)
  VALUES (v_cod, trim(p_nome), lower(trim(p_email)), nullif(trim(coalesce(p_pix,'')),''),
          COALESCE(p_pct,30), COALESCE(p_meses,12), TRUE);

  RETURN json_build_object('ok',true,'codigo',v_cod);
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_criar_embaixador(TEXT,TEXT,TEXT,TEXT,NUMERIC,INT) TO authenticated;

-- 4) Editar embaixador (ativar/desativar, mudar pix, %, meses, nome)
CREATE OR REPLACE FUNCTION rpc_admin_editar_embaixador(
  p_codigo TEXT, p_nome TEXT DEFAULT NULL, p_pix TEXT DEFAULT NULL,
  p_pct NUMERIC DEFAULT NULL, p_meses INT DEFAULT NULL, p_ativo BOOLEAN DEFAULT NULL
) RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT eh_admin() THEN RETURN json_build_object('ok',false,'erro','sem_permissao'); END IF;
  UPDATE afiliados SET
    nome           = COALESCE(nullif(trim(coalesce(p_nome,'')),''), nome),
    pix_chave      = COALESCE(nullif(trim(coalesce(p_pix,'')),''), pix_chave),
    pct_comissao   = COALESCE(p_pct, pct_comissao),
    meses_comissao = COALESCE(p_meses, meses_comissao),
    ativo          = COALESCE(p_ativo, ativo)
  WHERE codigo = lower(p_codigo);
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'erro','Embaixador não encontrado.'); END IF;
  RETURN json_build_object('ok',true);
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_editar_embaixador(TEXT,TEXT,TEXT,NUMERIC,INT,BOOLEAN) TO authenticated;

-- 5) Detalhe de um embaixador: meses e extrato
CREATE OR REPLACE FUNCTION rpc_admin_detalhe_embaixador(p_codigo TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r JSON; v_cod TEXT := lower(p_codigo);
BEGIN
  IF NOT eh_admin() THEN RETURN NULL; END IF;
  SELECT json_build_object(
    'codigo', v_cod,
    'meses', (SELECT COALESCE(json_agg(m ORDER BY m.mes DESC), '[]'::json) FROM (
        SELECT to_char(date_trunc('month', criado_em),'YYYY-MM') AS mes,
               SUM(CASE WHEN status='pendente' THEN valor_comissao ELSE 0 END) AS pendente,
               SUM(CASE WHEN status='pago'     THEN valor_comissao ELSE 0 END) AS pago,
               COUNT(*) FILTER (WHERE status<>'estornado') AS faturas
        FROM comissoes WHERE afiliado_codigo=v_cod
        GROUP BY 1 ORDER BY 1 DESC LIMIT 18) m),
    'extrato', (SELECT COALESCE(json_agg(u), '[]'::json) FROM (
        SELECT criado_em, valor_bruto, taxa_stripe, valor_liquido, valor_comissao, status,
               right(stripe_invoice_id, 8) AS ref
        FROM comissoes WHERE afiliado_codigo=v_cod
        ORDER BY criado_em DESC LIMIT 50) u)
  ) INTO r;
  RETURN r;
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_detalhe_embaixador(TEXT) TO authenticated;

-- 6) Marcar as comissoes de um mes como pagas
CREATE OR REPLACE FUNCTION rpc_admin_marcar_pago(p_codigo TEXT, p_mes TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  IF NOT eh_admin() THEN RETURN json_build_object('ok',false,'erro','sem_permissao'); END IF;
  UPDATE comissoes SET status='pago', pago_em=NOW()
  WHERE afiliado_codigo = lower(p_codigo)
    AND to_char(date_trunc('month', criado_em),'YYYY-MM') = p_mes
    AND status = 'pendente';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN json_build_object('ok',true,'atualizadas',n);
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_marcar_pago(TEXT,TEXT) TO authenticated;
