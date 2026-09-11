-- ============================================================
-- CULTIVAI — BONUS DE INDICACAO (10% + 3 meses extras no anual)
-- Rodar no SQL Editor do Supabase, depois dos scripts anteriores.
-- ============================================================

-- Diz se o usuario logado entrou por um link de embaixador ativo e,
-- portanto, tem direito ao bonus. Usada pelo app (para avisar na tela)
-- e pelo checkout (para aplicar de verdade no Stripe).
CREATE OR REPLACE FUNCTION rpc_meu_bonus_indicacao()
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_cod TEXT; v_nome TEXT; v_ja_assinou BOOLEAN;
BEGIN
  IF auth.uid() IS NULL THEN RETURN json_build_object('tem', false); END IF;

  SELECT afiliado_codigo INTO v_cod FROM usuarios WHERE id = auth.uid();
  IF v_cod IS NULL THEN RETURN json_build_object('tem', false); END IF;

  SELECT nome INTO v_nome FROM afiliados WHERE codigo = v_cod AND ativo;
  IF v_nome IS NULL THEN RETURN json_build_object('tem', false); END IF;

  -- O bonus é de boas-vindas: vale para quem ainda não teve nenhuma
  -- fatura paga. Quem já assinou antes não pega de novo.
  SELECT EXISTS (SELECT 1 FROM comissoes WHERE usuario_id = auth.uid()) INTO v_ja_assinou;
  IF v_ja_assinou THEN RETURN json_build_object('tem', false); END IF;

  RETURN json_build_object(
    'tem', true,
    'codigo', v_cod,
    'indicado_por', v_nome,
    'pct_desconto', 10,
    'meses_extras', 3
  );
END $$;
GRANT EXECUTE ON FUNCTION rpc_meu_bonus_indicacao() TO authenticated;
