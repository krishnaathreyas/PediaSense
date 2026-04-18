-- ============================================================
-- PediaSense: baby_profiles table
-- Stores one baby profile per authenticated caregiver account.
-- ============================================================

CREATE TABLE IF NOT EXISTS baby_profiles (
    user_id             uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    baby_name           text NOT NULL CHECK (char_length(trim(baby_name)) BETWEEN 1 AND 80),
    age_months          integer NOT NULL CHECK (age_months BETWEEN 0 AND 60),
    weight_kg           numeric(5,2) NOT NULL CHECK (weight_kg > 0 AND weight_kg <= 30),
    is_low_birth_weight boolean NOT NULL DEFAULT false,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.set_updated_at_timestamp()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_baby_profiles_set_updated_at ON baby_profiles;
CREATE TRIGGER trg_baby_profiles_set_updated_at
BEFORE UPDATE ON baby_profiles
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at_timestamp();

ALTER TABLE baby_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can read own baby profile" ON baby_profiles;
CREATE POLICY "Users can read own baby profile"
  ON baby_profiles FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own baby profile" ON baby_profiles;
CREATE POLICY "Users can insert own baby profile"
  ON baby_profiles FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own baby profile" ON baby_profiles;
CREATE POLICY "Users can update own baby profile"
  ON baby_profiles FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
