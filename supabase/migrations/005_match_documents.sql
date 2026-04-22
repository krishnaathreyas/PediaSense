-- RAG vector search function expected by edge function.
-- Uses cosine distance operator (<=>) on who_imci_chunks.embedding.

CREATE OR REPLACE FUNCTION public.match_documents(
  query_embedding vector(768),
  match_count int DEFAULT 5
)
RETURNS TABLE (
  id bigint,
  content text,
  source text,
  source_url text,
  chapter text,
  page integer,
  similarity float
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    wc.id,
    wc.content,
    wc.source,
    wc.source_url,
    wc.chapter,
    wc.page,
    1 - (wc.embedding <=> query_embedding) AS similarity
  FROM public.who_imci_chunks wc
  ORDER BY wc.embedding <=> query_embedding
  LIMIT GREATEST(match_count, 1);
$$;

GRANT EXECUTE ON FUNCTION public.match_documents(vector(768), int) TO anon;
GRANT EXECUTE ON FUNCTION public.match_documents(vector(768), int) TO authenticated;