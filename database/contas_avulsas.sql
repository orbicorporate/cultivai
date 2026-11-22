-- ============================================================
-- CONTAS AVULSAS (pague por cultura) — rodar no SQL Editor do Supabase
-- Regra: a primeira cultura calculada é grátis (não guarda, não abre plano).
-- Cada conta avulsa libera UMA cultura pra sempre (resultado, guardar, plano, guia).
-- Pro (plano_atual = 'pro') não gasta conta.
-- ============================================================

ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS contas_creditos INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS culturas_liberadas (
  usuario_id    UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  cultura_nome  TEXT NOT NULL,
  origem        TEXT NOT NULL CHECK (origem IN ('gratis','credito')),
  criado_em     TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (usuario_id, cultura_nome)
);
ALTER TABLE culturas_liberadas ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS culturas_liberadas_select ON culturas_liberadas;
CREATE POLICY culturas_liberadas_select ON culturas_liberadas FOR SELECT USING (auth.uid() = usuario_id);

-- Compras de pacote (idempotência do webhook do Stripe)
CREATE TABLE IF NOT EXISTS contas_compras (
  referencia    TEXT PRIMARY KEY,          -- id da checkout session
  usuario_id    UUID NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
  qtd           INTEGER NOT NULL,
  valor         NUMERIC(10,2),
  criado_em     TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE contas_compras ENABLE ROW LEVEL SECURITY;

-- Situação do usuário logado
CREATE OR REPLACE FUNCTION rpc_minhas_contas()
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid UUID := auth.uid();
  saldo INTEGER;
  lib JSON;
BEGIN
  IF uid IS NULL THEN RETURN json_build_object('saldo', 0, 'usadas', 0, 'liberadas', '[]'::json); END IF;
  SELECT contas_creditos INTO saldo FROM usuarios WHERE id = uid;
  SELECT COALESCE(json_agg(json_build_object('cultura_nome', cultura_nome, 'origem', origem) ORDER BY criado_em), '[]'::json)
    INTO lib FROM culturas_liberadas WHERE usuario_id = uid;
  RETURN json_build_object(
    'saldo', COALESCE(saldo, 0),
    'usadas', (SELECT COUNT(*) FROM culturas_liberadas WHERE usuario_id = uid),
    'liberadas', lib
  );
END $$;

-- Libera uma cultura pro usuário logado.
-- p_usar_credito = true também serve pra "subir" a cultura grátis pra paga (gasta 1 conta).
CREATE OR REPLACE FUNCTION rpc_liberar_cultura(p_cultura TEXT, p_usar_credito BOOLEAN DEFAULT FALSE)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid UUID := auth.uid();
  u RECORD;
  atual RECORD;
  n_usadas INTEGER;
BEGIN
  IF uid IS NULL THEN RETURN json_build_object('ok', false, 'motivo', 'login'); END IF;
  SELECT plano_atual, contas_creditos INTO u FROM usuarios WHERE id = uid;
  IF u IS NULL THEN RETURN json_build_object('ok', false, 'motivo', 'sem_usuario'); END IF;

  IF u.plano_atual = 'pro' THEN
    RETURN json_build_object('ok', true, 'origem', 'pro', 'saldo', u.contas_creditos);
  END IF;

  SELECT * INTO atual FROM culturas_liberadas WHERE usuario_id = uid AND cultura_nome = p_cultura;

  -- já liberada
  IF atual IS NOT NULL THEN
    IF atual.origem = 'gratis' AND p_usar_credito AND u.contas_creditos > 0 THEN
      UPDATE usuarios SET contas_creditos = contas_creditos - 1 WHERE id = uid;
      UPDATE culturas_liberadas SET origem = 'credito' WHERE usuario_id = uid AND cultura_nome = p_cultura;
      RETURN json_build_object('ok', true, 'origem', 'credito', 'saldo', u.contas_creditos - 1);
    END IF;
    RETURN json_build_object('ok', true, 'origem', atual.origem, 'saldo', u.contas_creditos);
  END IF;

  SELECT COUNT(*) INTO n_usadas FROM culturas_liberadas WHERE usuario_id = uid;

  -- primeira cultura: grátis
  IF n_usadas = 0 AND NOT p_usar_credito THEN
    INSERT INTO culturas_liberadas (usuario_id, cultura_nome, origem) VALUES (uid, p_cultura, 'gratis');
    RETURN json_build_object('ok', true, 'origem', 'gratis', 'saldo', u.contas_creditos);
  END IF;

  -- tem conta avulsa
  IF u.contas_creditos > 0 THEN
    UPDATE usuarios SET contas_creditos = contas_creditos - 1 WHERE id = uid;
    INSERT INTO culturas_liberadas (usuario_id, cultura_nome, origem) VALUES (uid, p_cultura, 'credito');
    RETURN json_build_object('ok', true, 'origem', 'credito', 'saldo', u.contas_creditos - 1);
  END IF;

  RETURN json_build_object('ok', false, 'motivo', 'sem_credito', 'usadas', n_usadas, 'saldo', 0);
END $$;

-- Chamada pelo webhook do Stripe (protegida pelo mesmo segredo dos afiliados)
CREATE OR REPLACE FUNCTION rpc_creditar_contas(p_segredo TEXT, p_usuario_id UUID, p_qtd INTEGER, p_referencia TEXT, p_valor NUMERIC DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_segredo IS DISTINCT FROM (SELECT valor FROM privado.config WHERE chave = 'webhook_segredo') THEN
    RETURN json_build_object('ok', false, 'motivo', 'segredo_invalido');
  END IF;
  IF EXISTS (SELECT 1 FROM contas_compras WHERE referencia = p_referencia) THEN
    RETURN json_build_object('ok', true, 'repetida', true);
  END IF;
  INSERT INTO contas_compras (referencia, usuario_id, qtd, valor) VALUES (p_referencia, p_usuario_id, p_qtd, p_valor);
  UPDATE usuarios SET contas_creditos = contas_creditos + p_qtd WHERE id = p_usuario_id;
  RETURN json_build_object('ok', true, 'saldo', (SELECT contas_creditos FROM usuarios WHERE id = p_usuario_id));
END $$;

GRANT EXECUTE ON FUNCTION rpc_minhas_contas() TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_liberar_cultura(TEXT, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_creditar_contas(TEXT, UUID, INTEGER, TEXT, NUMERIC) TO anon, authenticated;
