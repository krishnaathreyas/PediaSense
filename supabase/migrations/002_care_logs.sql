-- ============================================================
-- PediaSense: care_logs table
-- Stores diaper, feeding, and symptom logs per baby.
-- ============================================================

CREATE TABLE IF NOT EXISTS care_logs (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    baby_id    text NOT NULL DEFAULT 'default',
    type       text NOT NULL CHECK (type IN ('diaper', 'feeding', 'symptom')),
    value      jsonb NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Index for fast "today's logs" queries
CREATE INDEX IF NOT EXISTS idx_care_logs_created_at
    ON care_logs (created_at DESC);

-- Index for per-baby filtering
CREATE INDEX IF NOT EXISTS idx_care_logs_baby_id
    ON care_logs (baby_id);

-- Composite index for the most common query: today's logs for a baby, by type
CREATE INDEX IF NOT EXISTS idx_care_logs_baby_type_date
    ON care_logs (baby_id, type, created_at DESC);

-- Allow public access (uses anon key, no RLS for now)
ALTER TABLE care_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow all access to care_logs"
    ON care_logs FOR ALL
    USING (true)
    WITH CHECK (true);
