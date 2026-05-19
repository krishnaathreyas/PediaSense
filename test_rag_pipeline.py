#!/usr/bin/env python3
"""
Systematic RAG Pipeline Diagnostic Script
Tests each stage: embedding → retrieval → context → generation
"""

import os
import sys
import json
import subprocess
import time
from pathlib import Path

# Load environment
env_file = Path("scripts/.env")
if not env_file.exists():
    print("❌ scripts/.env not found")
    sys.exit(1)

env_vars = {}
with open(env_file) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env_vars[key.strip()] = value.strip()

SUPABASE_URL = env_vars.get("SUPABASE_URL")
SUPABASE_SERVICE_KEY = env_vars.get("SUPABASE_SERVICE_KEY")
SUPABASE_ANON_KEY = env_vars.get("SUPABASE_ANON_KEY", "")  # May not exist yet
GEMINI_API_KEY = env_vars.get("GEMINI_API_KEY")

if not SUPABASE_URL:
    print("❌ SUPABASE_URL not found in scripts/.env")
    sys.exit(1)

if not GEMINI_API_KEY:
    print("❌ GEMINI_API_KEY not found in scripts/.env")
    sys.exit(1)

print("=" * 80)
print("RAG PIPELINE DIAGNOSTIC TEST")
print("=" * 80)
print()

# Use anon key if available, else service role
AUTH_KEY = SUPABASE_ANON_KEY if SUPABASE_ANON_KEY else SUPABASE_SERVICE_KEY
print(f"✓ SUPABASE_URL: {SUPABASE_URL}")
print(f"✓ Using auth key: {AUTH_KEY[:20]}...")
print(f"✓ GEMINI_API_KEY: {GEMINI_API_KEY[:20]}...")
print()

# Test query
TEST_QUERY = "fever in infant"
print(f"📝 Test query: '{TEST_QUERY}'")
print()

# ============================================================================
# STAGE 1: Embedding (Gemini Embedding API)
# ============================================================================
print("=" * 80)
print("STAGE 1: QUERY EMBEDDING (Gemini Embedding API)")
print("=" * 80)

embed_url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent?key={GEMINI_API_KEY}"
embed_payload = {
    "model": "models/gemini-embedding-001",
    "content": {"parts": [{"text": TEST_QUERY}]},
    "taskType": "RETRIEVAL_QUERY",
    "outputDimensionality": 768,
}

try:
    embed_response = subprocess.run(
        ["curl", "-s", "-X", "POST", embed_url,
         "-H", "Content-Type: application/json",
         "-d", json.dumps(embed_payload)],
        capture_output=True,
        text=True,
        timeout=30
    )
    embed_result = json.loads(embed_response.stdout)
    
    if "error" in embed_result:
        print(f"❌ Embedding failed: {embed_result['error']}")
        sys.exit(1)
    
    embedding = embed_result.get("embedding", {}).get("values", [])
    if not embedding:
        print(f"❌ No embedding returned")
        print(f"Response: {json.dumps(embed_result, indent=2)}")
        sys.exit(1)
    
    print(f"✅ Query embedded successfully")
    print(f"   - Dimensions: {len(embedding)}")
    print(f"   - First 3 values: {embedding[:3]}")
    print()
    
except Exception as e:
    print(f"❌ Embedding API error: {e}")
    sys.exit(1)

# ============================================================================
# STAGE 2: Vector Retrieval (Supabase RPC match_documents)
# ============================================================================
print("=" * 80)
print("STAGE 2: VECTOR RETRIEVAL (Supabase RPC match_documents)")
print("=" * 80)

# Direct Supabase RPC call
rpc_url = f"{SUPABASE_URL}/rest/v1/rpc/match_documents"
rpc_payload = {
    "query_embedding": embedding,
    "match_count": 5
}

try:
    rpc_response = subprocess.run(
        ["curl", "-s", "-X", "POST", rpc_url,
         "-H", "Content-Type: application/json",
         "-H", f"Authorization: Bearer {AUTH_KEY}",
         "-H", f"apikey: {AUTH_KEY}",
         "-d", json.dumps(rpc_payload)],
        capture_output=True,
        text=True,
        timeout=30
    )
    
    # Try to parse as JSON
    try:
        rpc_result = json.loads(rpc_response.stdout)
    except json.JSONDecodeError:
        print(f"❌ RPC returned non-JSON response:")
        print(f"   {rpc_response.stdout[:500]}")
        sys.exit(1)
    
    # Check if it's an error
    if isinstance(rpc_result, dict) and "code" in rpc_result:
        print(f"❌ RPC error: {rpc_result.get('message', rpc_result)}")
        sys.exit(1)
    
    if isinstance(rpc_result, dict) and "error" in rpc_result:
        print(f"❌ RPC error: {rpc_result['error']}")
        sys.exit(1)
    
    # Should be a list of chunks
    if not isinstance(rpc_result, list):
        print(f"❌ RPC returned unexpected type: {type(rpc_result)}")
        print(f"   Response: {json.dumps(rpc_result, indent=2)[:500]}")
        sys.exit(1)
    
    if len(rpc_result) == 0:
        print(f"⚠️  No chunks retrieved (zero results)")
        print(f"    This could indicate:")
        print(f"    - Knowledge base is empty")
        print(f"    - match_documents function doesn't exist")
        print(f"    - Query has no similar vectors")
        sys.exit(1)
    
    chunks = rpc_result
    print(f"✅ Vector retrieval successful")
    print(f"   - Chunks retrieved: {len(chunks)}")
    
    # Show first chunk
    if chunks:
        first = chunks[0]
        print(f"   - Top result similarity: {first.get('similarity', 'N/A')}")
        print(f"   - Top result source: {first.get('source', 'N/A')}")
        print(f"   - Top result content preview: {first.get('content', '')[:80]}...")
    print()
    
except Exception as e:
    print(f"❌ RPC call error: {e}")
    sys.exit(1)

# ============================================================================
# STAGE 3: Context Building
# ============================================================================
print("=" * 80)
print("STAGE 3: CONTEXT BUILDING")
print("=" * 80)

context_parts = []
for i, chunk in enumerate(chunks):
    label = f"{chunk.get('source', 'Unknown')}"
    if chunk.get('chapter'):
        label += f" - {chunk.get('chapter')}"
    if chunk.get('page'):
        label += f" (p.{chunk.get('page')})"
    
    content = chunk.get('content', '')
    context_parts.append(f"[Chunk {i+1}] {label}\n{content}")

context = "\n\n".join(context_parts)

print(f"✅ Context built successfully")
print(f"   - Total chunks: {len(chunks)}")
print(f"   - Context length: {len(context)} chars")
print(f"   - Context preview (first 200 chars):")
print(f"     {context[:200]}...")
print()

# ============================================================================
# STAGE 4: Edge Function Call (Full Pipeline)
# ============================================================================
print("=" * 80)
print("STAGE 4: EDGE FUNCTION CALL (Full RAG Pipeline)")
print("=" * 80)

edge_url = f"{SUPABASE_URL}/functions/v1/rag-suggest"
edge_payload = {"question": TEST_QUERY}

print(f"Calling: POST {edge_url}")
print(f"Payload: {json.dumps(edge_payload)}")
print()

try:
    edge_response = subprocess.run(
        ["curl", "-s", "-i", "-X", "POST", edge_url,
         "-H", "Content-Type: application/json",
         "-H", f"Authorization: Bearer {AUTH_KEY}",
         "-H", f"apikey: {AUTH_KEY}",
         "-d", json.dumps(edge_payload)],
        capture_output=True,
        text=True,
        timeout=60
    )
    
    # Parse response (headers + body)
    response_parts = edge_response.stdout.split("\n\n", 1)
    headers_section = response_parts[0] if response_parts else ""
    body_section = response_parts[1] if len(response_parts) > 1 else ""
    
    # Extract status
    status_line = headers_section.split("\n")[0] if headers_section else ""
    print(f"Status: {status_line}")
    print()
    
    # Try to parse body
    try:
        body = json.loads(body_section)
    except json.JSONDecodeError:
        print(f"❌ Edge function returned non-JSON body:")
        print(f"   {body_section[:500]}")
        sys.exit(1)
    
    # Check for errors
    if "error" in body:
        print(f"❌ Edge function error:")
        print(f"   {body['error']}")
        print()
        print(f"Full response: {json.dumps(body, indent=2)}")
        sys.exit(1)
    
    # Success case
    if "title" in body:
        print(f"✅ Edge function completed successfully")
        print()
        print(f"📋 Response:")
        print(f"   Title: {body.get('title')}")
        print(f"   Severity: {body.get('severity')}")
        print(f"   Chunks used: {body.get('chunksUsed')}")
        print(f"   IsFromRAG: {body.get('isFromRAG')}")
        print(f"   Actions: {len(body.get('actions', []))} items")
        print(f"   Hospital Criteria: {len(body.get('hospitalCriteria', []))} items")
        print(f"   Sources: {len(body.get('sources', []))} items")
        print()
        print(f"✅✅✅ FULL PIPELINE WORKING!")
    else:
        print(f"⚠️  Edge function returned unexpected structure:")
        print(f"   {json.dumps(body, indent=2)}")
    
except Exception as e:
    print(f"❌ Edge function call error: {e}")
    sys.exit(1)

print()
print("=" * 80)
print("DIAGNOSTIC COMPLETE")
print("=" * 80)
