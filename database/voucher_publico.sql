-- Consulta publica de um presente, usada na tela que a pessoa ve ANTES de entrar.
-- Devolve so o necessario pra montar a tela (titulo, duracao e se ainda da pra resgatar).
-- Nao expõe estoque, quem resgatou, nem qualquer dado de usuario.

CREATE OR REPLACE FUNCTION rpc_voucher_publico(p_codigo TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v RECORD;
BEGIN
  SELECT titulo, dias, ativo, estoque, usados INTO v
    FROM vouchers WHERE codigo = lower(p_codigo);

  IF NOT FOUND THEN
    RETURN json_build_object('existe', false, 'motivo', 'nao_encontrado');
  END IF;

  IF NOT v.ativo THEN
    RETURN json_build_object('existe', true, 'disponivel', false, 'motivo', 'pausado',
                             'titulo', v.titulo, 'dias', v.dias);
  END IF;

  IF COALESCE(v.usados, 0) >= COALESCE(v.estoque, 0) THEN
    RETURN json_build_object('existe', true, 'disponivel', false, 'motivo', 'esgotado',
                             'titulo', v.titulo, 'dias', v.dias);
  END IF;

  RETURN json_build_object('existe', true, 'disponivel', true,
                           'titulo', v.titulo, 'dias', v.dias);
END $$;

GRANT EXECUTE ON FUNCTION rpc_voucher_publico(TEXT) TO anon, authenticated;
