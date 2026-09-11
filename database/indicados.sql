-- ============================================================
-- CULTIVAI — LISTA DE INDICADOS (quem entrou pelo link)
-- Rodar no SQL Editor do Supabase, depois dos scripts anteriores.
-- ============================================================

-- Esconde parte do nome e do e-mail, para o embaixador nao receber
-- dados pessoais completos de clientes que nao autorizaram isso.
CREATE OR REPLACE FUNCTION mascarar_nome(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN coalesce(trim(p),'') = '' THEN 'Produtor'
    WHEN position(' ' in trim(p)) = 0 THEN trim(p)
    ELSE split_part(trim(p),' ',1) || ' ' || upper(left(split_part(trim(p),' ',2),1)) || '.'
  END;
$$;

CREATE OR REPLACE FUNCTION mascarar_email(p TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN coalesce(p,'') = '' THEN ''
    ELSE left(split_part(p,'@',1),2) || '•••@' || split_part(p,'@',2)
  END;
$$;

-- Monta a lista de indicados de um codigo. p_mascarar decide se os
-- dados saem completos (admin) ou parciais (embaixador).
CREATE OR REPLACE FUNCTION _indicados(p_codigo TEXT, p_mascarar BOOLEAN)
RETURNS JSON LANGUAGE sql SECURITY DEFINER SET search_path = public, auth AS $$
  SELECT COALESCE(json_agg(x ORDER BY x.entrou_em DESC), '[]'::json) FROM (
    SELECT
      CASE WHEN p_mascarar THEN mascarar_nome(au.raw_user_meta_data->>'nome')
           ELSE COALESCE(nullif(trim(au.raw_user_meta_data->>'nome'),''), 'Produtor') END AS nome,
      CASE WHEN p_mascarar THEN mascarar_email(au.email) ELSE au.email END AS email,
      COALESCE(u.afiliado_atribuido_em, au.created_at) AS entrou_em,
      (SELECT MIN(c.criado_em) FROM comissoes c
         WHERE c.usuario_id = u.id AND c.status <> 'estornado') AS assinou_em,
      (SELECT COALESCE(SUM(c.valor_comissao),0) FROM comissoes c
         WHERE c.usuario_id = u.id AND c.status <> 'estornado') AS comissao,
      (SELECT COUNT(*) FROM comissoes c
         WHERE c.usuario_id = u.id AND c.status <> 'estornado') AS meses_pagos,
      CASE
        WHEN u.plano_atual = 'pro' THEN 'assinante'
        WHEN EXISTS (SELECT 1 FROM comissoes c WHERE c.usuario_id = u.id AND c.status <> 'estornado') THEN 'cancelou'
        ELSE 'cadastrou'
      END AS status
    FROM usuarios u
    JOIN auth.users au ON au.id = u.id
    WHERE u.afiliado_codigo = lower(p_codigo)
    LIMIT 200
  ) x;
$$;

-- Versao do embaixador: so o proprio codigo, com dados parciais
CREATE OR REPLACE FUNCTION rpc_afiliado_indicados()
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cod TEXT;
BEGIN
  SELECT codigo INTO v_cod FROM afiliados
   WHERE lower(email) = lower(coalesce(auth.jwt()->>'email','')) LIMIT 1;
  IF v_cod IS NULL THEN RETURN NULL; END IF;
  RETURN _indicados(v_cod, TRUE);
END $$;
GRANT EXECUTE ON FUNCTION rpc_afiliado_indicados() TO authenticated;

-- Versao do admin: qualquer codigo. p_como_embaixador=TRUE devolve
-- os dados parciais, para a previa "ver como ele ve" ficar fiel.
CREATE OR REPLACE FUNCTION rpc_admin_indicados(p_codigo TEXT, p_como_embaixador BOOLEAN DEFAULT FALSE)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT eh_admin() THEN RETURN NULL; END IF;
  RETURN _indicados(p_codigo, p_como_embaixador);
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_indicados(TEXT, BOOLEAN) TO authenticated;
