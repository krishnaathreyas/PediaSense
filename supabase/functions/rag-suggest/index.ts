// PediaSense RAG — Supabase Edge Function: rag-suggest
// ============================================================================
// Receives vitals JSON from the Flutter app, embeds the query,
// retrieves top-3 relevant WHO/IAP guideline chunks via pgvector,
// and generates a structured suggestion using Gemini Flash.
//
// Deploy: supabase functions deploy rag-suggest --no-verify-jwt
// ============================================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

// ─── Configuration ──────────────────────────────────────────────────────────

const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const EMBEDDING_MODELS = [
  "text-embedding-004",
  "embedding-001",
  "gemini-embedding-001",
];
const GENERATION_MODEL = "gemini-2.0-flash";
const MATCH_COUNT = 5;
const MATCH_THRESHOLD = 0.3;

function logStage(requestId: string, stage: string, details?: Record<string, unknown>) {
  if (details && Object.keys(details).length > 0) {
    console.log(`[rag-suggest][${requestId}] ${stage}`, details);
  } else {
    console.log(`[rag-suggest][${requestId}] ${stage}`);
  }
}

// ─── Gemini API helpers ─────────────────────────────────────────────────────

async function embedQuery(text: string, requestId: string): Promise<number[]> {
  const startedAt = Date.now();
  logStage(requestId, "embed.start", {
    candidateModels: EMBEDDING_MODELS,
    queryLength: text.length,
  });

  const errors: string[] = [];

  for (const model of EMBEDDING_MODELS) {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:embedContent?key=${GEMINI_API_KEY}`;

    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: `models/${model}`,
        content: { parts: [{ text }] },
        taskType: "RETRIEVAL_QUERY",
        outputDimensionality: 768,
      }),
    });

    if (!res.ok) {
      const errText = await res.text();
      const compactErr = `model=${model} status=${res.status} msg=${errText.slice(0, 200)}`;
      errors.push(compactErr);
      logStage(requestId, "embed.model_failed", {
        model,
        status: res.status,
        durationMs: Date.now() - startedAt,
        errorPreview: errText.slice(0, 500),
      });
      continue;
    }

    const data = await res.json();
    const values = data.embedding?.values as number[] | undefined;
    if (!values || !Array.isArray(values)) {
      const compactErr = `model=${model} status=200 invalid_payload`;
      errors.push(compactErr);
      logStage(requestId, "embed.model_invalid_payload", {
        model,
        durationMs: Date.now() - startedAt,
      });
      continue;
    }

    logStage(requestId, "embed.ok", {
      model,
      durationMs: Date.now() - startedAt,
      dimensions: values.length,
    });
    return values;
  }

  logStage(requestId, "embed.error", {
    durationMs: Date.now() - startedAt,
    reason: "All embedding models failed",
    errors,
  });
  throw new Error(`Embedding stage failed. Tried models: ${errors.join(" | ")}`);
}

interface GenerationResult {
  title: string;
  severity: string;
  actions: string[];
  hospitalCriteria: string[];
}

function buildTemplateSuggestion(
  riskLevel: string,
  chunks: RetrievedChunk[],
  isUserChat: boolean,
  queryString: string
): GenerationResult {
  const severity = riskLevel === "urgent" ? "urgent" : riskLevel === "monitor" ? "monitor" : "normal";

  const queryLower = queryString.toLowerCase();
  const topics: string[] = [];
  if (/(breath|resp|pneum|chest|indrawing|grunting|wheeze)/.test(queryLower)) topics.push("breathing");
  if (/(heart|hr|pulse|cardiac|tachy)/.test(queryLower)) topics.push("heart rate");
  if (/(spo2|oxygen|saturation|cyanosis|blue lips)/.test(queryLower)) topics.push("oxygenation");
  if (/(temp|fever|hypotherm|cold|hot)/.test(queryLower)) topics.push("temperature");
  if (/(feed|hydr|diaper|urine|dehydrat|vomit)/.test(queryLower)) topics.push("hydration/feeding");

  let seed = 0;
  for (let i = 0; i < queryString.length; i += 1) {
    seed = (seed * 31 + queryString.charCodeAt(i)) >>> 0;
  }
  const pick = (arr: string[]) => arr[arr.length > 0 ? seed % arr.length : 0];

  const sourceHints = chunks
    .slice(0, 2)
    .map((c) => `${c.source}${c.chapter ? ` (${c.chapter})` : ""}`);

  const chunkEvidence = chunks
    .slice(0, 2)
    .map((c) => {
      const snippet = c.content.replace(/\s+/g, " ").trim().slice(0, 110);
      return `${snippet}${snippet.length >= 110 ? "..." : ""}`;
    });

  const topicLabel = topics.length > 0 ? topics.join(" + ") : "general infant danger signs";

  const urgentPrimary = [
    "Prioritize immediate escalation to pediatric emergency care while continuing real-time monitoring.",
    "Treat this as high-risk: seek urgent pediatric review and keep serial vitals running.",
    "Escalate now for medical evaluation; do not delay while symptoms and vitals remain concerning.",
  ];
  const monitorPrimary = [
    "Recheck vitals at short intervals and monitor trend direction closely.",
    "Continue observation with frequent repeat readings and symptom tracking.",
    "Maintain close watch and repeat measurements to confirm whether values are stabilizing.",
  ];

  const actions = [
    severity === "urgent"
      ? pick(urgentPrimary)
      : pick(monitorPrimary),
    `Focus assessment on ${topicLabel}; document symptom changes with timestamps for clinician handover.`,
    chunkEvidence.length > 0
      ? `Guideline evidence snapshot: ${chunkEvidence[0]}`
      : "Apply WHO/IAP triage principles while continuing vitals observation.",
    sourceHints.length > 0
      ? `Follow guidance from: ${sourceHints.join("; ")}.`
      : "Use WHO/IAP danger-sign protocols for triage and caregiver action.",
  ];

  const hospitalCriteria = [
    "Breathing difficulty, chest indrawing, grunting, or persistent cyanosis.",
    "Lethargy, poor feeding, repeated vomiting, or convulsion-like activity.",
    "Persistent fever/hypothermia or any rapidly worsening clinical signs.",
  ];

  return {
    title: isUserChat
      ? `Care Guidance (${topicLabel})`
      : `Vitals-Based Guidance (${topicLabel})`,
    severity,
    actions,
    hospitalCriteria,
  };
}

interface RetrievedChunk {
  id?: number;
  content: string;
  source: string;
  source_url?: string;
  chapter?: string;
  page?: number;
  similarity?: number;
}

const STOPWORDS = new Set([
  "the", "and", "for", "with", "that", "this", "from", "your", "what", "when", "where", "how",
  "have", "has", "had", "are", "was", "were", "will", "would", "could", "should", "can", "into",
  "about", "after", "before", "then", "than", "also", "baby", "infant", "month", "months", "rate",
  "temp", "skin", "heart", "spo2", "breathing", "alert", "normal", "monitor", "urgent"
]);

function recursiveCharacterSplit(
  text: string,
  chunkSize = 220,
  overlap = 40
): string[] {
  const cleaned = text.replace(/\s+/g, " ").trim();
  if (!cleaned) return [];

  const chunks: string[] = [];
  let start = 0;

  while (start < cleaned.length) {
    let end = Math.min(start + chunkSize, cleaned.length);

    // Prefer splitting at punctuation/space close to the right edge.
    if (end < cleaned.length) {
      const tail = cleaned.slice(start, end);
      const punct = Math.max(tail.lastIndexOf("."), tail.lastIndexOf(";"), tail.lastIndexOf(","));
      const space = tail.lastIndexOf(" ");
      const splitAt = Math.max(punct, space);
      if (splitAt > chunkSize * 0.6) {
        end = start + splitAt + 1;
      }
    }

    chunks.push(cleaned.slice(start, end).trim());
    if (end >= cleaned.length) break;
    start = Math.max(0, end - overlap);
  }

  return chunks;
}

function tokenizeText(input: string): string[] {
  return input
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .split(/\s+/)
    .map((t) => t.trim())
    .filter((t) => t.length >= 3 && !STOPWORDS.has(t));
}

function termFrequency(tokens: string[]): Map<string, number> {
  const tf = new Map<string, number>();
  for (const token of tokens) {
    tf.set(token, (tf.get(token) ?? 0) + 1);
  }
  return tf;
}

function cosineSimilarity(a: Map<string, number>, b: Map<string, number>): number {
  if (a.size === 0 || b.size === 0) return 0;

  let dot = 0;
  let normA = 0;
  let normB = 0;

  for (const [, value] of a) normA += value * value;
  for (const [, value] of b) normB += value * value;

  const smaller = a.size <= b.size ? a : b;
  const larger = a.size <= b.size ? b : a;

  for (const [key, value] of smaller) {
    const other = larger.get(key);
    if (other) dot += value * other;
  }

  const denom = Math.sqrt(normA) * Math.sqrt(normB);
  return denom > 0 ? dot / denom : 0;
}

async function hybridFallbackRetrieve(
  supabase: ReturnType<typeof createClient>,
  queryString: string,
  requestId: string
): Promise<RetrievedChunk[]> {
  const startedAt = Date.now();
  const querySegments = recursiveCharacterSplit(queryString, 220, 40);
  const queryTokens = tokenizeText(querySegments.join(" "));
  const queryTf = termFrequency(queryTokens);
  const queryTokenSet = new Set(queryTokens);

  logStage(requestId, "hybrid_search.start", {
    querySegmentCount: querySegments.length,
    queryTokenCount: queryTokens.length,
    queryTokensPreview: [...queryTokenSet].slice(0, 15),
  });

  const { data, error } = await supabase
    .from("who_imci_chunks")
    .select("id, content, source, source_url, chapter, page")
    .limit(700);

  if (error) {
    logStage(requestId, "hybrid_search.error", {
      error: error.message,
      code: error.code,
      details: error.details,
    });
    throw new Error(`Hybrid fallback search failed: ${error.message}`);
  }

  const rows = (data ?? []) as RetrievedChunk[];
  const scored = rows
    .map((row) => {
      const searchText = `${row.source ?? ""} ${row.chapter ?? ""} ${row.content ?? ""}`;
      const docTokens = tokenizeText(searchText);
      const docTf = termFrequency(docTokens);

      let overlapHits = 0;
      for (const token of queryTokenSet) {
        if (docTf.has(token)) overlapHits += 1;
      }

      const overlapScore = queryTokenSet.size > 0 ? overlapHits / queryTokenSet.size : 0;
      const cosineScore = cosineSimilarity(queryTf, docTf);

      // Boost when query terms appear in source/chapter metadata.
      const sourceMeta = `${row.source ?? ""} ${row.chapter ?? ""}`.toLowerCase();
      let sourceBoost = 0;
      for (const token of queryTokenSet) {
        if (sourceMeta.includes(token)) {
          sourceBoost = 0.08;
          break;
        }
      }

      const hybrid = Math.min(1, 0.65 * cosineScore + 0.30 * overlapScore + sourceBoost);

      return {
        ...row,
        similarity: Number(hybrid.toFixed(4)),
      };
    })
    .filter((row) => (row.similarity ?? 0) >= 0.03)
    .sort((a, b) => (b.similarity ?? 0) - (a.similarity ?? 0))
    .slice(0, MATCH_COUNT);

  logStage(requestId, "hybrid_search.ok", {
    durationMs: Date.now() - startedAt,
    totalRowsScanned: rows.length,
    matchedRows: scored.length,
    topSimilarity: scored.length > 0 ? scored[0].similarity : null,
  });

  return scored;
}

async function generateSuggestion(
  query: string,
  contextChunks: { content: string; source: string; chapter: string }[],
  requestId: string
): Promise<GenerationResult> {
  const startedAt = Date.now();
  const contextText = contextChunks
    .map(
      (c, i) =>
        `[Source ${i + 1}: ${c.source} — ${c.chapter}]\n${c.content}`
    )
    .join("\n\n---\n\n");

  const systemPrompt = `You are a pediatric health assistant for the PediaSense infant monitoring system.
Your role is to help caregivers understand their baby's vital signs and provide evidence-based guidance.

CRITICAL RULES:
1. Answer ONLY using the WHO IMCI and IAP guideline context provided below. Do NOT use external knowledge.
2. Be clear, actionable, and non-alarming. Parents are not medical professionals.
3. Always recommend consulting a healthcare provider for medical decisions.
4. Return your response as valid JSON matching the exact schema specified.

GUIDELINE CONTEXT:
${contextText}`;

  const userPrompt = `${query}

Return a JSON object with exactly this structure (no markdown, no code fences, just raw JSON):
{
  "title": "Short title summarizing the concern (e.g. 'Elevated Breathing Rate')",
  "severity": "normal" or "monitor" or "urgent",
  "actions": ["Action 1 the caregiver should take", "Action 2", ...],
  "hospitalCriteria": ["Sign 1 that means go to hospital", "Sign 2", ...]
}`;

  const url = `https://generativelanguage.googleapis.com/v1beta/models/${GENERATION_MODEL}:generateContent?key=${GEMINI_API_KEY}`;

  logStage(requestId, "generate.start", {
    model: GENERATION_MODEL,
    queryLength: query.length,
    contextChunks: contextChunks.length,
    contextChars: contextText.length,
  });

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      contents: [
        {
          role: "user",
          parts: [{ text: userPrompt }],
        },
      ],
      systemInstruction: {
        parts: [{ text: systemPrompt }],
      },
      generationConfig: {
        temperature: 0.2,
        topP: 0.8,
        maxOutputTokens: 1024,
        responseMimeType: "application/json",
      },
    }),
  });

  if (!res.ok) {
    const errText = await res.text();
    logStage(requestId, "generate.error", {
      status: res.status,
      durationMs: Date.now() - startedAt,
      errorPreview: errText.slice(0, 500),
    });
    throw new Error(`Generation API error (${res.status}): ${errText}`);
  }

  const data = await res.json();
  const rawText =
    data.candidates?.[0]?.content?.parts?.[0]?.text ?? "{}";

  // Parse the JSON response from Gemini
  try {
    const parsed = JSON.parse(rawText) as GenerationResult;
    logStage(requestId, "generate.ok", {
      durationMs: Date.now() - startedAt,
      title: parsed.title,
      severity: parsed.severity,
      actionsCount: parsed.actions?.length ?? 0,
      criteriaCount: parsed.hospitalCriteria?.length ?? 0,
    });
    return parsed;
  } catch (parseError) {
    logStage(requestId, "generate.parse_error", {
      durationMs: Date.now() - startedAt,
      error: String(parseError),
      rawPreview: rawText.slice(0, 500),
    });
    return {
      title: "Health Alert",
      severity: "monitor",
      actions: [
        "Monitor your baby's vital signs closely.",
        "Consult your pediatrician if you notice any changes.",
      ],
      hospitalCriteria: [
        "If your baby shows difficulty breathing.",
        "If your baby becomes lethargic or unresponsive.",
      ],
    };
  }
}

// ─── Main handler ───────────────────────────────────────────────────────────

serve(async (req: Request) => {
  const requestId = crypto.randomUUID().slice(0, 8);
  const startedAt = Date.now();

  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    logStage(requestId, "cors.preflight");
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers":
          "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  try {
    logStage(requestId, "request.start", {
      method: req.method,
      hasGeminiKey: Boolean(GEMINI_API_KEY),
      hasSupabaseUrl: Boolean(SUPABASE_URL),
      hasServiceRoleKey: Boolean(SUPABASE_SERVICE_ROLE_KEY),
    });

    // 1. Parse request from Flutter
    const body = await req.json();
    const {
      heartRate = 0,
      spo2 = 0,
      breathingRate = 0,
      skinTemp = 0,
      riskLevel = "normal",
      babyAgeMonths = 12,
      isLBW = false,
      userQuery = "",        // free-text question from chat
      chatHistory = [],      // previous messages for context
    } = body;

    const isUserChat = typeof userQuery === "string" && userQuery.trim().length > 0;

    logStage(requestId, "request.parsed", {
      mode: isUserChat ? "chat" : "auto",
      riskLevel,
      heartRate,
      spo2,
      breathingRate,
      skinTemp,
      babyAgeMonths,
      isLBW,
      userQueryLength: typeof userQuery === "string" ? userQuery.length : 0,
      chatHistoryLength: Array.isArray(chatHistory) ? chatHistory.length : 0,
    });

    // 2. Build the query string
    let queryString: string;

    if (isUserChat) {
      // User asked a free-text question — include vitals context
      const vitalsContext = heartRate > 0
        ? ` Current vitals: SpO2 ${spo2}%, HR ${heartRate} bpm, BR ${breathingRate}/min, Temp ${skinTemp}°C. Baby is ${babyAgeMonths} months old.`
        : "";
      queryString = `${userQuery.trim()}${vitalsContext}`;
    } else {
      // Auto-triggered from vitals change
      const riskLabel =
        riskLevel === "urgent"
          ? "RED/URGENT"
          : riskLevel === "monitor"
          ? "AMBER/MONITOR"
          : "NORMAL";

      queryString = `${riskLabel} alert for a ${babyAgeMonths}-month-old infant${
        isLBW ? " (low birth weight)" : ""
      }: SpO2 ${spo2.toFixed(1)}%, heart rate ${heartRate.toFixed(
        0
      )} bpm, breathing rate ${breathingRate.toFixed(
        0
      )} breaths/min, skin temperature ${skinTemp.toFixed(
        1
      )}°C. What should the caregiver do? What are the danger signs to watch for?`;
    }

    logStage(requestId, "query.built", {
      queryLength: queryString.length,
      queryPreview: queryString.slice(0, 140),
    });

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // 3 + 4. Retrieval path: vector search first; local hybrid lexical fallback if embedding/vector fails
    let chunks: RetrievedChunk[] = [];
    let retrievalMode: "vector" | "hybrid" = "vector";

    try {
      const queryEmbedding = await embedQuery(queryString, requestId);

      logStage(requestId, "vector_search.start", {
        matchCount: MATCH_COUNT,
        threshold: MATCH_THRESHOLD,
        embeddingLength: queryEmbedding.length,
      });

      const { data, error: matchError } = await supabase.rpc(
        "match_who_chunks",
        {
          query_embedding: queryEmbedding,
          match_count: MATCH_COUNT,
          match_threshold: MATCH_THRESHOLD,
        }
      );

      if (matchError) {
        logStage(requestId, "vector_search.error", {
          error: matchError.message,
          details: matchError.details,
          hint: matchError.hint,
          code: matchError.code,
        });
        throw new Error(`Vector search failed: ${matchError.message}`);
      }

      chunks = (data ?? []) as RetrievedChunk[];
    } catch (retrievalError) {
      retrievalMode = "hybrid";
      logStage(requestId, "retrieval.fallback_to_hybrid", {
        reason: String(retrievalError),
      });
      chunks = await hybridFallbackRetrieve(supabase, queryString, requestId);
    }

    const chunkCount = chunks.length;
    const topSimilarity = chunkCount > 0 ? chunks?.[0]?.similarity ?? null : null;
    logStage(requestId, "vector_search.ok", {
      chunkCount,
      topSimilarity,
      retrievalMode,
    });

    // 5. Generate suggestion using Gemini Flash + retrieved context
    let suggestion: GenerationResult;
    let generationMode: "gemini" | "template" = "gemini";
    let generationError: string | null = null;

    try {
      suggestion = await generateSuggestion(
        queryString,
        chunks ?? [],
        requestId
      );
    } catch (err) {
      generationMode = "template";
      generationError = String(err);
      logStage(requestId, "generate.fallback_template", {
        reason: generationError,
        chunkCount: chunks.length,
      });
      suggestion = buildTemplateSuggestion(riskLevel, chunks, isUserChat, queryString);
    }

    // 6. Attach verified source references from the database rows
    const sources = (chunks ?? []).map(
      (c: { source: string; chapter: string; source_url: string; page: number; similarity: number }) => ({
        text: `${c.source}${c.chapter ? " — " + c.chapter : ""}${
          c.page ? " (p." + c.page + ")" : ""
        }`,
        url: c.source_url ?? null,
        similarity: c.similarity,
      })
    );

    // 7. Return structured JSON to Flutter
    const response = {
      ...suggestion,
      sources,
      query: queryString,
      chunksUsed: chunks.length,
      retrievalMode,
      generationMode,
      generationError,
      timestamp: new Date().toISOString(),
    };

    logStage(requestId, "response.ok", {
      title: suggestion.title,
      severity: suggestion.severity,
      chunksUsed: response.chunksUsed,
      sourcesCount: sources.length,
      durationMs: Date.now() - startedAt,
    });

    return new Response(JSON.stringify(response), {
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (error) {
    logStage(requestId, "response.fallback", {
      error: String(error),
      durationMs: Date.now() - startedAt,
    });

    // Return a safe fallback so the app never crashes
    const fallback = {
      title: "Health Monitoring Active",
      severity: "monitor",
      actions: [
        "Continue monitoring your baby's vital signs.",
        "Ensure your baby is comfortable and well-hydrated.",
        "Consult your pediatrician if you have any concerns.",
      ],
      hospitalCriteria: [
        "If your baby has difficulty breathing or shows chest indrawing.",
        "If your baby becomes lethargic, unresponsive, or refuses to feed.",
        "If your baby's skin turns blue or grey around the lips.",
      ],
      sources: [],
      query: "",
      chunksUsed: 0,
      timestamp: new Date().toISOString(),
      error: String(error),
      requestId,
    };

    return new Response(JSON.stringify(fallback), {
      status: 200, // Return 200 even on error so Flutter gets usable data
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  }
});
