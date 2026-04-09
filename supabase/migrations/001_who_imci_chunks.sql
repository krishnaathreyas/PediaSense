-- ============================================================================
-- PediaSense RAG — Supabase pgvector setup
-- Run this in your Supabase SQL Editor (Dashboard → SQL Editor → New Query)
-- FIRST run: DROP FUNCTION IF EXISTS match_who_chunks CASCADE;
--            DROP TABLE IF EXISTS who_imci_chunks CASCADE;
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS who_imci_chunks (
    id          bigserial PRIMARY KEY,
    content     text        NOT NULL,
    embedding   vector(768) NOT NULL,
    source      text        NOT NULL,
    source_url  text,
    chapter     text,
    page        integer,
    created_at  timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_who_imci_chunks_embedding
    ON who_imci_chunks
    USING hnsw (embedding vector_cosine_ops);

CREATE OR REPLACE FUNCTION match_who_chunks(
    query_embedding  vector(768),
    match_count      int DEFAULT 5,
    match_threshold  float DEFAULT 0.3
)
RETURNS TABLE (
    id          bigint,
    content     text,
    source      text,
    source_url  text,
    chapter     text,
    page        integer,
    similarity  float
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        wc.id,
        wc.content,
        wc.source,
        wc.source_url,
        wc.chapter,
        wc.page,
        1 - (wc.embedding <=> query_embedding) AS similarity
    FROM who_imci_chunks wc
    WHERE 1 - (wc.embedding <=> query_embedding) > match_threshold
    ORDER BY wc.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

GRANT EXECUTE ON FUNCTION match_who_chunks(vector(768), int, float) TO anon;
GRANT EXECUTE ON FUNCTION match_who_chunks(vector(768), int, float) TO authenticated;
GRANT SELECT ON who_imci_chunks TO anon;
GRANT SELECT ON who_imci_chunks TO authenticated;
