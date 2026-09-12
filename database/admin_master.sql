-- ============================================================
-- CULTIVAI — ADMIN MASTER PERMANENTE
-- Rodar no SQL Editor do Supabase.
-- ============================================================

-- O e-mail master fica escrito na propria funcao. Assim o acesso nao
-- depende de uma linha na tabela: mesmo que app_admins seja apagada
-- por engano, este e-mail continua administrador.
CREATE OR REPLACE FUNCTION eh_master()
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT lower(coalesce(auth.jwt()->>'email','')) = 'pedrobruder11@gmail.com';
$$;
GRANT EXECUTE ON FUNCTION eh_master() TO authenticated;

-- Admin = master OU quem estiver na tabela app_admins
CREATE OR REPLACE FUNCTION eh_admin()
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT eh_master() OR EXISTS (
    SELECT 1 FROM app_admins
    WHERE lower(email) = lower(coalesce(auth.jwt()->>'email',''))
  );
$$;
GRANT EXECUTE ON FUNCTION eh_admin() TO authenticated;

-- Garante a linha na tabela tambem, por consistencia
INSERT INTO app_admins (email) VALUES ('pedrobruder11@gmail.com')
  ON CONFLICT (email) DO NOTHING;

-- Protege o master: ninguem consegue remover essa linha por acidente
CREATE OR REPLACE FUNCTION _protege_master()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF lower(OLD.email) = 'pedrobruder11@gmail.com' THEN
    RAISE EXCEPTION 'Este e-mail é o admin master e não pode ser removido.';
  END IF;
  RETURN OLD;
END $$;

DROP TRIGGER IF EXISTS trg_protege_master ON app_admins;
CREATE TRIGGER trg_protege_master BEFORE DELETE ON app_admins
  FOR EACH ROW EXECUTE FUNCTION _protege_master();
