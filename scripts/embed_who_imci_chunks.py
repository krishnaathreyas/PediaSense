#!/usr/bin/env python3
"""
Generate embeddings for WHO IMCI chunks in Supabase.
This script reads content from who_imci_chunks table and populates embeddings using Gemini API.
"""

import os
import sys
import json
from pathlib import Path
import time

import google.generativeai as genai
from supabase import create_client

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
GEMINI_API_KEY = env_vars.get("GEMINI_API_KEY")

if not all([SUPABASE_URL, SUPABASE_SERVICE_KEY, GEMINI_API_KEY]):
    print("❌ Missing required environment variables")
    sys.exit(1)

# Initialize clients
genai.configure(api_key=GEMINI_API_KEY)
supabase = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)

print("=" * 80)
print("WHO IMCI CHUNKS - EMBEDDING GENERATOR")
print("=" * 80)
print()

# Fetch all chunks (including those with placeholder embeddings)
print("📥 Fetching all chunks...")
try:
    response = supabase.table("who_imci_chunks").select("id, content").execute()
    chunks = response.data
    print(f"✓ Found {len(chunks)} chunks to embed")
except Exception as e:
    print(f"❌ Error fetching chunks: {e}")
    sys.exit(1)

if not chunks:
    print("⚠️  No chunks to embed. All chunks already have embeddings.")
    sys.exit(0)

print()
print("=" * 80)
print(f"EMBEDDING {len(chunks)} CHUNKS")
print("=" * 80)
print()

# Embedding model
EMBEDDING_MODEL = "models/gemini-embedding-001"
BATCH_SIZE = 5  # Process in batches to manage API calls

failed_ids = []
success_count = 0

for batch_start in range(0, len(chunks), BATCH_SIZE):
    batch_end = min(batch_start + BATCH_SIZE, len(chunks))
    batch = chunks[batch_start:batch_end]
    
    print(f"Processing batch {batch_start // BATCH_SIZE + 1}/{(len(chunks) + BATCH_SIZE - 1) // BATCH_SIZE}...")
    
    for idx, chunk in enumerate(batch):
        chunk_id = chunk["id"]
        content = chunk["content"]
        
        try:
            # Generate embedding
            response = genai.embed_content(
                model=EMBEDDING_MODEL,
                content=content,
                task_type="RETRIEVAL_DOCUMENT",
                title=f"WHO IMCI Chunk {chunk_id}",
            )
            
            embedding = response["embedding"]
            if not embedding or len(embedding) == 0:
                print(f"  ⚠️  Chunk {chunk_id}: Empty embedding returned")
                failed_ids.append(chunk_id)
                continue
            
            # Update chunk with embedding
            supabase.table("who_imci_chunks").update({
                "embedding": embedding
            }).eq("id", chunk_id).execute()
            
            success_count += 1
            print(f"  ✓ Chunk {chunk_id}: {len(embedding)} dimensions")
            
        except Exception as e:
            print(f"  ❌ Chunk {chunk_id}: {str(e)}")
            failed_ids.append(chunk_id)
        
        # Rate limiting
        time.sleep(0.5)
    
    print()

print("=" * 80)
print("EMBEDDING COMPLETE")
print("=" * 80)
print(f"✓ Successfully embedded: {success_count} chunks")
if failed_ids:
    print(f"❌ Failed: {len(failed_ids)} chunks (IDs: {failed_ids})")
print()

# Verify final state
print("📊 Final Statistics:")
try:
    response = supabase.table("who_imci_chunks").select("id, content, source, chapter, embedding").execute()
    all_chunks = response.data
    
    total = len(all_chunks)
    with_embedding = sum(1 for c in all_chunks if c.get("embedding") is not None)
    without_embedding = total - with_embedding
    
    print(f"  Total chunks: {total}")
    print(f"  With embeddings: {with_embedding}")
    print(f"  Without embeddings: {without_embedding}")
    
    # Group by source
    by_source = {}
    for chunk in all_chunks:
        source = chunk.get("source", "Unknown")
        if source not in by_source:
            by_source[source] = {"total": 0, "embedded": 0}
        by_source[source]["total"] += 1
        if chunk.get("embedding"):
            by_source[source]["embedded"] += 1
    
    print()
    print("📚 By Source:")
    for source in sorted(by_source.keys()):
        stats = by_source[source]
        print(f"  {source}: {stats['embedded']}/{stats['total']}")
    
except Exception as e:
    print(f"❌ Error fetching final statistics: {e}")

print()
print("✅ Done!")
