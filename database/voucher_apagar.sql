-- Apagar um presente do painel master.
-- Regra de seguranca: so apaga presente que ninguem resgatou ainda.
-- Se alguem ja resgatou, o presente fica (senao a gente perde o registro
-- de quem ganhou acesso) e o admin deve usar PAUSAR no lugar.

CREATE OR REPLACE FUNCTION rpc_admin_apagar_voucher(p_codigo TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_usados INT;
  v_resgates INT;
BEGIN
  IF NOT eh_admin() THEN
    RETURN json_build_object('ok', false, 'erro', 'sem_permissao');
  END IF;

  SELECT usados INTO v_usados FROM vouchers WHERE codigo = lower(p_codigo) FOR UPDATE;
  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'erro', 'Presente não encontrado.');
  END IF;

  SELECT COUNT(*) INTO v_resgates FROM gift_passes WHERE lower(codigo) = lower(p_codigo);

  IF COALESCE(v_usados, 0) > 0 OR v_resgates > 0 THEN
    RETURN json_build_object(
      'ok', false,
      'erro', 'Esse presente já foi resgatado por alguém, então não dá pra apagar sem perder o registro. Use PAUSAR para tirar ele de circulação.'
    );
  END IF;

  DELETE FROM vouchers WHERE codigo = lower(p_codigo);
  RETURN json_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION rpc_admin_apagar_voucher(TEXT) TO authenticated;
