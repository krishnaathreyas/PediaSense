#!/usr/bin/env python3
"""
PediaSense RAG — Phase 1: Chunk & Embed
Run: cd scripts && python3 chunk_and_embed.py
"""
import os, sys, time
from pathlib import Path
from dotenv import load_dotenv
import fitz
import google.generativeai as genai
from langchain_text_splitters import RecursiveCharacterTextSplitter
from supabase import create_client, Client

CHUNK_SIZE = 500
CHUNK_OVERLAP = 50
EMBEDDING_MODEL = "models/gemini-embedding-001"
EMBEDDING_DIM = 768        # reduced from 3072 to fit pgvector index limit
BATCH_SIZE = 5
RATE_DELAY = 4.0

# Known PDFs with curated source URLs. Any OTHER .pdf in source_docs/
# is auto-discovered and assigned a source name from the filename.
KNOWN_SOURCES = {
    "WHO_IMCI_Chart_Booklet.pdf": {
        "source": "WHO_IMCI",
        "source_url": "https://iris.who.int/handle/10665/104772",
    },
    "IAP_Neonatal_Guidelines.pdf": {
        "source": "IAP",
        "source_url": "https://www.iapneochap.org",
    },
}

def discover_pdfs(src_dir: Path):
    """Auto-discover all PDFs in source_docs/. Known files get curated
    metadata; unknown files get a source name derived from the filename."""
    configs = []
    for pdf in sorted(src_dir.glob("*.pdf")):
        if pdf.name in KNOWN_SOURCES:
            cfg = {"filename": pdf.name, **KNOWN_SOURCES[pdf.name]}
        else:
            # Derive source name: "neonatal_care_guide.pdf" → "NEONATAL_CARE_GUIDE"
            stem = pdf.stem.replace(" ", "_").replace("-", "_").upper()
            cfg = {"filename": pdf.name, "source": stem, "source_url": ""}
        configs.append(cfg)
    return configs

load_dotenv()
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_SERVICE_KEY = os.getenv("SUPABASE_SERVICE_KEY")
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
if not all([SUPABASE_URL, SUPABASE_SERVICE_KEY, GEMINI_API_KEY]):
    print("ERROR: Missing env vars. Copy .env.example → .env"); sys.exit(1)

genai.configure(api_key=GEMINI_API_KEY)
supabase: Client = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)
splitter = RecursiveCharacterTextSplitter(
    chunk_size=CHUNK_SIZE * 4, chunk_overlap=CHUNK_OVERLAP * 4,
    separators=["\n\n", "\n", ". ", " ", ""])

def extract_pdf(path):
    doc = fitz.open(str(path))
    pages = []
    for i in range(len(doc)):
        t = doc[i].get_text("text").strip()
        if t: pages.append({"page": i+1, "text": t})
    doc.close()
    return pages

def guess_chapter(text):
    for line in text.strip().split("\n")[:3]:
        line = line.strip()
        if len(line) < 80 and (line.isupper() or line.istitle()):
            return line
    return "General"

def chunk_doc(pdf_path, cfg):
    print(f"\n📄 {pdf_path.name}")
    pages = extract_pdf(pdf_path)
    if not pages: return []
    print(f"  📖 {len(pages)} pages")
    chunks = []
    for p in pages:
        for c in splitter.split_text(p["text"]):
            if len(c.strip()) < 50: continue
            chunks.append({"content": c.strip(), "source": cfg["source"],
                           "source_url": cfg["source_url"],
                           "chapter": guess_chapter(c), "page": p["page"]})
    print(f"  ✂️  {len(chunks)} chunks")
    return chunks

def embed_chunks(chunks):
    print(f"\n🧠 Embedding {len(chunks)} chunks (dim={EMBEDDING_DIM})...")
    embedded = []
    for i in range(0, len(chunks), BATCH_SIZE):
        batch = chunks[i:i+BATCH_SIZE]
        texts = [c["content"] for c in batch]
        for attempt in range(3):
            try:
                result = genai.embed_content(
                    model=EMBEDDING_MODEL, content=texts,
                    task_type="RETRIEVAL_DOCUMENT",
                    output_dimensionality=EMBEDDING_DIM)
                embs = result["embedding"]
                for chunk, emb in zip(batch, embs):
                    chunk["embedding"] = emb
                    embedded.append(chunk)
                print(f"  ✅ {min(i+BATCH_SIZE, len(chunks))}/{len(chunks)}")
                break
            except Exception as e:
                wait = 15 * (attempt + 1)
                print(f"  ⚠️  {e}\n     Retry in {wait}s...")
                time.sleep(wait)
        else:
            print(f"  ❌ Skipping batch {i}")
        time.sleep(RATE_DELAY)
    return embedded

def upload(chunks):
    print(f"\n☁️  Uploading {len(chunks)} rows...")
    ok = 0
    for i in range(0, len(chunks), 50):
        batch = chunks[i:i+50]
        rows = [{"content": c["content"], "embedding": c["embedding"],
                 "source": c["source"], "source_url": c["source_url"],
                 "chapter": c["chapter"], "page": c["page"]} for c in batch]
        try:
            supabase.table("who_imci_chunks").insert(rows).execute()
            ok += len(batch)
            print(f"  ✅ {ok}/{len(chunks)}")
        except Exception as e:
            print(f"  ❌ {e}")
    return ok

def main():
    print("=" * 50)
    print("PediaSense RAG — Chunk & Embed")
    print("=" * 50)
    src = Path(__file__).parent / "source_docs"
    pdf_configs = discover_pdfs(src)
    if not pdf_configs:
        print("❌ No PDFs found. Place PDFs in scripts/source_docs/"); sys.exit(1)
    print(f"📚 Found {len(pdf_configs)} PDF(s)")
    all_chunks = []
    for cfg in pdf_configs:
        p = src / cfg["filename"]
        all_chunks.extend(chunk_doc(p, cfg))
    if not all_chunks:
        print("❌ No chunks. Place PDFs in scripts/source_docs/"); sys.exit(1)
    embedded = embed_chunks(all_chunks)
    if not embedded:
        print("❌ No embeddings succeeded"); sys.exit(1)
    assert len(embedded[0]["embedding"]) == EMBEDDING_DIM
    uploaded = upload(embedded)
    print(f"\n✅ Done: {len(all_chunks)} chunks, {len(embedded)} embedded, {uploaded} uploaded")

if __name__ == "__main__":
    main()
