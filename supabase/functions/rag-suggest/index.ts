// @ts-nocheck
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const EMBEDDING_MODEL = "models/gemini-embedding-001";
const GENERATION_MODEL = "models/gemini-2.5-flash";
const MATCH_COUNT = 5;

type Severity = "normal" | "monitor" | "urgent";

interface RetrievedChunk {
  id: number;
  content: string;
  source: string;
  source_url: string | null;
  chapter: string | null;
  page: number | null;
  similarity: number;
}

interface GeneratedAnswer {
  title: string;
  severity: Severity;
  actions: string[];
  hospitalCriteria: string[];
}

interface RagResponse {
  title: string;
  severity: Severity;
  actions: string[];
  hospitalCriteria: string[];
  sources: Array<{ text: string; url: string | null }>;
  chunksUsed: number;
  isFromRAG: true;
}

function logStage(requestId: string, stage: string, details?: Record<string, unknown>) {
  if (details && Object.keys(details).length > 0) {
    console.log(`[rag-suggest][${requestId}] ${stage}`, details);
    return;
  }
  console.log(`[rag-suggest][${requestId}] ${stage}`);
}

function getEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new Error(`Missing environment variable: ${name}`);
  }
  return value;
}

function sanitizeSeverity(value: unknown): Severity {
  if (value === "urgent" || value === "monitor" || value === "normal") {
    return value;
  }
  return "monitor";
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((v) => String(v).trim())
    .filter((v) => v.length > 0);
}

function buildQueryFromBody(body: Record<string, unknown>): string {
  const question = typeof body.question === "string" ? body.question.trim() : "";
  if (question.length > 0) {
    return question;
  }

  const userQuery = typeof body.userQuery === "string" ? body.userQuery.trim() : "";
  if (userQuery.length > 0) {
    return userQuery;
  }

  const heartRate = Number(body.heartRate ?? 0);
  const spo2 = Number(body.spo2 ?? 0);
  const breathingRate = Number(body.breathingRate ?? 0);
  const skinTemp = Number(body.skinTemp ?? 0);
  const riskLevel = String(body.riskLevel ?? "normal");
  const babyAgeMonths = Number(body.babyAgeMonths ?? 12);
  const isLBW = Boolean(body.isLBW ?? false);

  if (heartRate <= 0 && spo2 <= 0 && breathingRate <= 0 && skinTemp <= 0) {
    return "";
  }

  return `${riskLevel.toUpperCase()} infant triage query for ${babyAgeMonths}-month-old${isLBW ? " (low birth weight)" : ""}: SpO2 ${spo2}%, heart rate ${heartRate} bpm, breathing rate ${breathingRate} breaths/min, skin temperature ${skinTemp}C. Provide caregiver guidance and hospital danger signs based only on WHO IMCI and IAP guidelines.`;
}

async function embedQuery(question: string, geminiApiKey: string, requestId: string): Promise<number[]> {
  logStage(requestId, "embed.start", {
    model: EMBEDDING_MODEL,
    taskType: "RETRIEVAL_QUERY",
    questionLength: question.length,
  });

  const response = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/${EMBEDDING_MODEL}:embedContent?key=${geminiApiKey}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: EMBEDDING_MODEL,
        content: { parts: [{ text: question }] },
        taskType: "RETRIEVAL_QUERY",
        outputDimensionality: 768,
      }),
    }
  );

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Gemini embedding error (${response.status}): ${errText}`);
  }

  const payload = await response.json();
  const values = payload?.embedding?.values;
  if (!Array.isArray(values)) {
    throw new Error("Gemini embedding response missing embedding.values array");
  }

  if (values.length !== 768) {
    throw new Error(`Unexpected embedding dimension: ${values.length} (expected 768)`);
  }

  logStage(requestId, "embed.success", {
    dimensions: values.length,
  });

  return values as number[];
}

async function retrieveChunks(
  supabase: ReturnType<typeof createClient>,
  queryEmbedding: number[],
  requestId: string
): Promise<RetrievedChunk[]> {
  const { data, error } = await supabase.rpc("match_documents", {
    query_embedding: queryEmbedding,
    match_count: MATCH_COUNT,
  });

  if (error) {
    throw new Error(`match_documents RPC failed: ${error.message}`);
  }

  const chunks = (data ?? []) as RetrievedChunk[];
  logStage(requestId, "retrieve.success", {
    matches: chunks.length,
    topSimilarity: chunks[0]?.similarity ?? null,
  });

  return chunks;
}

function buildContext(chunks: RetrievedChunk[]): string {
  return chunks
    .map((chunk, index) => {
      const label = [chunk.source, chunk.chapter].filter(Boolean).join(" - ");
      return `[Chunk ${index + 1}] ${label}\n${chunk.content}`;
    })
    .join("\n\n");
}

function stripMarkdownFences(text: string): string {
  return text
    .trim()
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/\s*```$/i, "")
    .trim();
}

function removeTrailingCommas(text: string): string {
  return text.replace(/,\s*([}\]])/g, "$1");
}

function extractFirstBalancedJsonObject(text: string): string | null {
  const start = text.indexOf("{");
  if (start === -1) return null;

  let depth = 0;
  let inString = false;
  let isEscaped = false;

  for (let i = start; i < text.length; i++) {
    const ch = text[i];

    if (inString) {
      if (isEscaped) {
        isEscaped = false;
      } else if (ch === "\\") {
        isEscaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }

    if (ch === "{") depth++;
    if (ch === "}") depth--;

    if (depth === 0) {
      return text.slice(start, i + 1);
    }
  }

  return null;
}

function tryParseModelJson(rawText: string): Record<string, unknown> | null {
  const cleaned = stripMarkdownFences(rawText);
  if (!cleaned) return null;

  const candidates: string[] = [];
  candidates.push(cleaned);

  const extracted = extractFirstBalancedJsonObject(cleaned);
  if (extracted) {
    candidates.push(extracted);
  }

  for (const candidate of candidates) {
    try {
      return JSON.parse(candidate) as Record<string, unknown>;
    } catch {
      // Try common cleanup if the model leaves trailing commas.
    }

    try {
      return JSON.parse(removeTrailingCommas(candidate)) as Record<string, unknown>;
    } catch {
      // Try next candidate.
    }
  }

  return null;
}

async function generateGroundedAnswer(
  question: string,
  chunks: RetrievedChunk[],
  geminiApiKey: string,
  requestId: string
): Promise<GeneratedAnswer> {
  const context = buildContext(chunks);

  const basePrompt = `You are a pediatric clinical guidance assistant for infant caregivers.
Use only the provided WHO IMCI / IAP context. If any detail is not in context, do not invent it.

Safety requirements:
1) Keep advice medically cautious and caregiver-safe.
2) Use clear, actionable language.
3) Include escalation criteria when risk signs are present.
4) Never claim diagnosis certainty.

Return strict JSON only with this exact schema:
{
  "title": "string",
  "severity": "normal" | "monitor" | "urgent",
  "actions": ["string"],
  "hospitalCriteria": ["string"]
}

Question:
${question}

Context:
${context}`;

  let parsed: Record<string, unknown> | null = null;
  let parseFailureDetails = "";

  for (let attempt = 1; attempt <= 3; attempt++) {
    const retryNote =
      attempt === 1
        ? ""
        : "\n\nYour previous response was invalid JSON. Return only valid minified JSON for the exact schema, with no markdown fences and no extra text.";

    const prompt = `${basePrompt}${retryNote}`;

    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/${GENERATION_MODEL}:generateContent?key=${geminiApiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [{ role: "user", parts: [{ text: prompt }] }],
          generationConfig: {
            temperature: 0.2,
            topP: 0.8,
            maxOutputTokens: 1200,
            responseMimeType: "application/json",
            responseSchema: {
              type: "OBJECT",
              properties: {
                title: { type: "STRING" },
                severity: { type: "STRING", enum: ["normal", "monitor", "urgent"] },
                actions: { type: "ARRAY", items: { type: "STRING" } },
                hospitalCriteria: { type: "ARRAY", items: { type: "STRING" } },
              },
              required: ["title", "severity", "actions", "hospitalCriteria"],
            },
          },
        }),
      }
    );

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`Gemini generation error (${response.status}): ${errText}`);
    }

    const payload = await response.json();
    const finishReason = payload?.candidates?.[0]?.finishReason ?? "UNKNOWN";
    const rawText = payload?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (typeof rawText !== "string" || rawText.trim().length === 0) {
      parseFailureDetails = `Gemini generation returned empty content (finishReason=${finishReason})`;
      continue;
    }

    console.log("========== GEMINI RAW OUTPUT START ==========");
    console.log(rawText);
    console.log("========== GEMINI RAW OUTPUT END ==========");

    logStage(requestId, "generate.raw_output", {
      attempt,
      model: GENERATION_MODEL,
      finishReason,
      chars: rawText.length,
      preview: rawText.slice(0, 400),
    });

    console.log("Attempting JSON parse...");
    try {
      parsed = JSON.parse(rawText) as Record<string, unknown>;
    } catch (err) {
      console.error("JSON PARSE FAILED");
      console.error("Raw text was:");
      console.error(rawText);
      parsed = tryParseModelJson(rawText);
    }

    if (parsed) {
      break;
    }

    parseFailureDetails = `Invalid JSON returned (attempt ${attempt})`;
    logStage(requestId, "generate.parse_failed", {
      attempt,
      preview: rawText.slice(0, 240),
    });
  }

  if (!parsed) {
    throw new Error(`Failed to parse generation JSON: ${parseFailureDetails || "unknown parse failure"}`);
  }

  const answer: GeneratedAnswer = {
    title: String(parsed.title ?? "Care Guidance"),
    severity: sanitizeSeverity(parsed.severity),
    actions: asStringArray(parsed.actions),
    hospitalCriteria: asStringArray(parsed.hospitalCriteria),
  };

  logStage(requestId, "generate.success", {
    title: answer.title,
    severity: answer.severity,
    actionsCount: answer.actions.length,
    hospitalCriteriaCount: answer.hospitalCriteria.length,
  });

  return answer;
}

serve(async (req: Request) => {
  const requestId = crypto.randomUUID().slice(0, 8);

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed", requestId }),
      { status: 405, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
    );
  }

  try {
    const geminiApiKey = getEnv("GEMINI_API_KEY");
    const supabaseUrl = getEnv("SUPABASE_URL");
    const supabaseServiceRoleKey = getEnv("SUPABASE_SERVICE_ROLE_KEY");

    const body = (await req.json()) as Record<string, unknown>;
    const question = buildQueryFromBody(body);

    logStage(requestId, "request.received", {
      question,
      hasExplicitQuestion: typeof body.question === "string" || typeof body.userQuery === "string",
    });

    if (!question) {
      return new Response(
        JSON.stringify({ error: "Missing question in body. Provide { question: string }.", requestId }),
        { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } }
      );
    }

    const queryEmbedding = await embedQuery(question, geminiApiKey, requestId);

    const supabase = createClient(supabaseUrl, supabaseServiceRoleKey);
    const chunks = await retrieveChunks(supabase, queryEmbedding, requestId);

    if (chunks.length === 0) {
      throw new Error("No WHO/IAP guideline chunks retrieved from vector search");
    }

    const generated = await generateGroundedAnswer(question, chunks, geminiApiKey, requestId);

    const sources = chunks.map((chunk) => ({
      text: [chunk.source, chunk.chapter, chunk.page ? `(p.${chunk.page})` : ""]
        .filter((v) => v && String(v).trim().length > 0)
        .join(" "),
      url: chunk.source_url,
    }));

    const response: RagResponse = {
      title: generated.title,
      severity: generated.severity,
      actions: generated.actions,
      hospitalCriteria: generated.hospitalCriteria,
      sources,
      chunksUsed: chunks.length,
      isFromRAG: true,
    };

    return new Response(JSON.stringify(response), {
      status: 200,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (error) {
    logStage(requestId, "request.error", { error: String(error) });

    return new Response(
      JSON.stringify({ error: String(error), requestId }),
      {
        status: 500,
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      }
    );
  }
});