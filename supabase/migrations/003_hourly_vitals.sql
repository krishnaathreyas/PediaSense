-- ============================================================
-- PediaSense: hourly_vitals table
-- Stores aggregated vital signs per hour for trend analysis.
-- ============================================================

CREATE TABLE IF NOT EXISTS hourly_vitals (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    baby_id     text NOT NULL DEFAULT 'default',
    hour_start  timestamptz NOT NULL,
    avg_hr      float,
    min_hr      float,
    max_hr      float,
    avg_br      float,
    min_br      float,
    max_br      float,
    event_flag  boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Fast lookups by baby + time range
CREATE INDEX IF NOT EXISTS idx_hourly_vitals_baby_id
    ON hourly_vitals (baby_id);

CREATE INDEX IF NOT EXISTS idx_hourly_vitals_hour_start
    ON hourly_vitals (hour_start DESC);

CREATE INDEX IF NOT EXISTS idx_hourly_vitals_baby_hour
    ON hourly_vitals (baby_id, hour_start DESC);

-- Prevent duplicate entries for the same baby + hour
CREATE UNIQUE INDEX IF NOT EXISTS idx_hourly_vitals_unique_hour
    ON hourly_vitals (baby_id, hour_start);

-- RLS policy (permissive for now)
ALTER TABLE hourly_vitals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow all access to hourly_vitals"
    ON hourly_vitals FOR ALL
    USING (true)
    WITH CHECK (true);
