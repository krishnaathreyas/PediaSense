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

const EMBEDDING_MODEL = "gemini-embedding-001";
const GENERATION_MODEL = "gemini-2.0-flash";
const MATCH_COUNT = 5;
const MATCH_THRESHOLD = 0.3;

// ─── Gemini API helpers ─────────────────────────────────────────────────────

async function embedQuery(text: string): Promise<number[]> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${EMBEDDING_MODEL}:embedContent?key=${GEMINI_API_KEY}`;

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      model: `models/${EMBEDDING_MODEL}`,
      content: { parts: [{ text }] },
      taskType: "RETRIEVAL_QUERY",
      outputDimensionality: 768,
    }),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Embedding API error (${res.status}): ${errText}`);
  }

  const data = await res.json();
  return data.embedding.values;
}

interface GenerationResult {
  title: string;
  severity: string;
  actions: string[];
  hospitalCriteria: string[];
}

async function generateSuggestion(
  query: string,
  contextChunks: { content: string; source: string; chapter: string }[]
): Promise<GenerationResult> {
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
    throw new Error(`Generation API error (${res.status}): ${errText}`);
  }

  const data = await res.json();
  const rawText =
    data.candidates?.[0]?.content?.parts?.[0]?.text ?? "{}";

  // Parse the JSON response from Gemini
  try {
    return JSON.parse(rawText) as GenerationResult;
  } catch {
    console.error("Failed to parse Gemini response:", rawText);
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
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
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

    console.log(
      `[rag-suggest] ${isUserChat ? "Chat" : "Auto"}: risk=${riskLevel} HR=${heartRate} SpO2=${spo2} BR=${breathingRate} Temp=${skinTemp}${isUserChat ? ` Q="${userQuery}"` : ""}`
    );

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

    // 3. Embed the query (same model as Phase 1)
    const queryEmbedding = await embedQuery(queryString);

    // 4. Retrieve top-K relevant chunks from Supabase
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: chunks, error: matchError } = await supabase.rpc(
      "match_who_chunks",
      {
        query_embedding: queryEmbedding,
        match_count: MATCH_COUNT,
        match_threshold: MATCH_THRESHOLD,
      }
    );

    if (matchError) {
      console.error("[rag-suggest] match_who_chunks error:", matchError);
      throw new Error(`Vector search failed: ${matchError.message}`);
    }

    console.log(
      `[rag-suggest] Retrieved ${chunks?.length ?? 0} chunks (threshold=${MATCH_THRESHOLD})`
    );

    // 5. Generate suggestion using Gemini Flash + retrieved context
    const suggestion = await generateSuggestion(
      queryString,
      chunks ?? []
    );

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
      chunksUsed: chunks?.length ?? 0,
      timestamp: new Date().toISOString(),
    };

    console.log(`[rag-suggest] Returning: "${suggestion.title}" (${suggestion.severity})`);

    return new Response(JSON.stringify(response), {
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (error) {
    console.error("[rag-suggest] Error:", error);

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
