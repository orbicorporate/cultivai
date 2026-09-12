-- ============================================================
-- CULTIVAI — SEGUNDA CONTA MASTER
-- Rodar no SQL Editor do Supabase.
-- ============================================================

-- Agora sao dois e-mails master. Ambos ficam escritos na propria funcao,
-- entao o acesso nao depende de nenhuma linha em tabela.
CREATE OR REPLACE FUNCTION eh_master()
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT lower(coalesce(auth.jwt()->>'email','')) IN (
    'pedrobruder11@gmail.com',
    'orbicorporate@gmail.com'
  );
$$;
GRANT EXECUTE ON FUNCTION eh_master() TO authenticated;

INSERT INTO app_admins (email) VALUES ('orbicorporate@gmail.com')
  ON CONFLICT (email) DO NOTHING;

-- A protecao contra remocao passa a valer para os dois
CREATE OR REPLACE FUNCTION _protege_master()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF lower(OLD.email) IN ('pedrobruder11@gmail.com','orbicorporate@gmail.com') THEN
    RAISE EXCEPTION 'Este e-mail é admin master e não pode ser removido.';
  END IF;
  RETURN OLD;
END $$;
