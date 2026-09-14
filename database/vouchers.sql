-- ============================================================
-- CULTIVAI — VOUCHERS DE PRESENTE (com estoque)
-- Rodar no SQL Editor do Supabase.
-- Usa a tabela gift_passes que ja existe para liberar o acesso.
-- ============================================================

CREATE TABLE IF NOT EXISTS vouchers (
  codigo      TEXT PRIMARY KEY,
  titulo      TEXT NOT NULL,
  dias        INT  NOT NULL CHECK (dias > 0),
  estoque     INT  NOT NULL CHECK (estoque > 0),
  usados      INT  NOT NULL DEFAULT 0,
  ativo       BOOLEAN NOT NULL DEFAULT TRUE,
  criado_por  TEXT,
  criado_em   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE vouchers ENABLE ROW LEVEL SECURITY;  -- so via funcoes abaixo

-- ------------------------------------------------------------
-- RESGATE (chamado pelo app quando a pessoa abre o link)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_resgatar_voucher(p_codigo TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cod TEXT := lower(trim(p_codigo)); r vouchers%ROWTYPE; g gift_passes%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;

  -- trava a linha para dois resgates simultaneos nao furarem o estoque
  SELECT * INTO r FROM vouchers WHERE codigo = v_cod FOR UPDATE;
  IF r.codigo IS NULL THEN RETURN NULL; END IF;                       -- nao e voucher
  IF NOT r.ativo THEN RETURN json_build_object('erro','pausado'); END IF;
  IF r.usados >= r.estoque THEN RETURN json_build_object('erro','esgotado'); END IF;

  -- ja resgatou este voucher antes?
  SELECT * INTO g FROM gift_passes
   WHERE usuario_id = auth.uid() AND lower(codigo) = v_cod LIMIT 1;
  IF g.id IS NOT NULL THEN RETURN row_to_json(g); END IF;

  -- ja tem algum presente valendo? nao empilha
  IF EXISTS (SELECT 1 FROM gift_passes WHERE usuario_id = auth.uid() AND expira_em > NOW()) THEN
    RETURN json_build_object('erro','ja_tem_presente');
  END IF;

  INSERT INTO gift_passes (usuario_id, codigo, expira_em)
  VALUES (auth.uid(), v_cod, NOW() + (r.dias || ' days')::INTERVAL)
  RETURNING * INTO g;

  UPDATE vouchers SET usados = usados + 1 WHERE codigo = v_cod;
  RETURN row_to_json(g);
END $$;
GRANT EXECUTE ON FUNCTION rpc_resgatar_voucher(TEXT) TO authenticated;

-- ------------------------------------------------------------
-- ADMIN
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION rpc_admin_vouchers()
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT eh_admin() THEN RETURN NULL; END IF;
  RETURN (SELECT COALESCE(json_agg(x ORDER BY x.criado_em DESC), '[]'::json) FROM (
    SELECT v.codigo, v.titulo, v.dias, v.estoque, v.usados, v.ativo, v.criado_em,
           (v.estoque - v.usados) AS restam,
           (SELECT COUNT(*) FROM gift_passes g
             WHERE lower(g.codigo) = v.codigo AND g.expira_em > NOW()) AS ativos_agora
    FROM vouchers v) x);
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_vouchers() TO authenticated;

CREATE OR REPLACE FUNCTION rpc_admin_criar_voucher(
  p_titulo TEXT, p_dias INT, p_estoque INT, p_codigo TEXT DEFAULT NULL
) RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cod TEXT;
BEGIN
  IF NOT eh_admin() THEN RETURN json_build_object('ok',false,'erro','sem_permissao'); END IF;
  IF coalesce(trim(p_titulo),'') = '' THEN
    RETURN json_build_object('ok',false,'erro','Dê um nome pro presente, tipo "1 ano grátis - feira agro".'); END IF;
  IF p_dias IS NULL OR p_dias < 1 THEN
    RETURN json_build_object('ok',false,'erro','A duração precisa ser de pelo menos 1 dia.'); END IF;
  IF p_estoque IS NULL OR p_estoque < 1 THEN
    RETURN json_build_object('ok',false,'erro','O estoque precisa ser de pelo menos 1.'); END IF;

  v_cod := lower(trim(coalesce(nullif(trim(p_codigo),''),
           'cv' || substr(replace(gen_random_uuid()::text,'-',''), 1, 8))));
  IF v_cod !~ '^[a-z0-9_-]{4,40}$' THEN
    RETURN json_build_object('ok',false,'erro','Código inválido. Use letras, números, hífen ou underline (4 a 40).'); END IF;
  IF EXISTS (SELECT 1 FROM vouchers WHERE codigo = v_cod) THEN
    RETURN json_build_object('ok',false,'erro','Já existe um presente com esse código.'); END IF;

  INSERT INTO vouchers (codigo, titulo, dias, estoque, criado_por)
  VALUES (v_cod, trim(p_titulo), p_dias, p_estoque, coalesce(auth.jwt()->>'email',''));

  RETURN json_build_object('ok',true,'codigo',v_cod);
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_criar_voucher(TEXT,INT,INT,TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION rpc_admin_voucher_estado(p_codigo TEXT, p_ativo BOOLEAN, p_estoque INT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT eh_admin() THEN RETURN json_build_object('ok',false,'erro','sem_permissao'); END IF;
  UPDATE vouchers SET ativo = COALESCE(p_ativo, ativo),
                      estoque = COALESCE(p_estoque, estoque)
   WHERE codigo = lower(p_codigo);
  IF NOT FOUND THEN RETURN json_build_object('ok',false,'erro','Presente não encontrado.'); END IF;
  RETURN json_build_object('ok',true);
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_voucher_estado(TEXT,BOOLEAN,INT) TO authenticated;

-- Quem resgatou um presente
CREATE OR REPLACE FUNCTION rpc_admin_voucher_resgates(p_codigo TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
BEGIN
  IF NOT eh_admin() THEN RETURN NULL; END IF;
  RETURN (SELECT COALESCE(json_agg(x ORDER BY x.ativado_em DESC), '[]'::json) FROM (
    SELECT COALESCE(nullif(trim(au.raw_user_meta_data->>'nome'),''),'Produtor') AS nome,
           au.email, g.ativado_em, g.expira_em,
           (g.expira_em > NOW()) AS valendo
    FROM gift_passes g JOIN auth.users au ON au.id = g.usuario_id
    WHERE lower(g.codigo) = lower(p_codigo)
    ORDER BY g.ativado_em DESC LIMIT 200) x);
END $$;
GRANT EXECUTE ON FUNCTION rpc_admin_voucher_resgates(TEXT) TO authenticated;
