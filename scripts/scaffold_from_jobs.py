"""Scaffold a Phase 3a-style corpus from a directory of markdown files.

Default source roots assume the layout that produced the original Phase 3a
findings (`docs/quality/findings_phase3a.md`):

    <root>/prose-craft/        writing samples / voice observations
    <root>/career-ops/reports/ one report per item (filename "NNN-name-YYYY-MM-DD.md")

Override with `--root <path>` if your tree lives somewhere else, or with
`--source <name>:<path>` to point at arbitrary subdirectories.

Chunking policy: H2-first, size-cap fallback.
  1. If file has H2 (##) headings, split on those boundaries.
  2. If a resulting section is > MAX_CHARS, sentence-aware soft-split until each
     piece is ≤ MAX_CHARS.
  3. If a file has no H2 and is ≤ MAX_CHARS, keep whole.
  4. If a file has no H2 and is > MAX_CHARS, paragraph-then-sentence split.

Each memory carries:
  id, text, created_at, occurred_at, source, file_path, source_bucket,
  filename, title, note_id, chunk_id, tags, entities

Queries are stratified per Phase 3a spec: people / topics / temporal /
event-place / sentiment / mixed. Auto-graded with entity-overlap +
date-window heuristics.

Output: docs/quality/jobs-prose/{memories.jsonl, queries.template.jsonl,
queries.jsonl, entities.json}.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
DEFAULT_ROOT = os.path.join(HOME, "Developer", "jobs")
DEFAULT_OUT  = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "docs", "quality", "jobs-prose"))

MAX_CHARS = 1800          # soft cap per memory
MIN_CHARS = 120           # don't emit tiny fragments
ONE_PER_FILE = True       # Phase 3a: keep cardinality near file count, ~75
                          # memories. The H2-fan-out (1443 memories) flooded
                          # the auto-grader with hundreds of substring hits per
                          # query and lost real signal. Reset to 1-per-file
                          # with a head-of-file truncation so cell densities
                          # land in the useful 5-30 range.


# ----- File walking ---------------------------------------------------------
def collect_markdown(root: str) -> list[str]:
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        if "node_modules" in dirnames: dirnames.remove("node_modules")
        if ".git"         in dirnames: dirnames.remove(".git")
        for fn in filenames:
            if fn.lower().endswith((".md", ".markdown")):
                out.append(os.path.join(dirpath, fn))
    return sorted(out)


# ----- Chunking -------------------------------------------------------------
H2_RE = re.compile(r"(?m)^##\s+(.+)$")
H1_RE = re.compile(r"(?m)^#\s+(.+)$")
SENT_RE = re.compile(r"(?<=[.!?])\s+")


def split_h2_sections(text: str) -> list[tuple[str | None, str]]:
    """Returns [(heading_or_None, body), ...]. The pre-H2 prefix gets None."""
    matches = list(H2_RE.finditer(text))
    if not matches:
        return [(None, text)]
    sections = []
    if matches[0].start() > 0:
        prefix = text[:matches[0].start()].strip()
        if prefix:
            sections.append((None, prefix))
    for i, m in enumerate(matches):
        heading = m.group(1).strip()
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        body = text[start:end].strip()
        if body:
            sections.append((heading, body))
    return sections


def soft_split_by_size(text: str, max_chars: int = MAX_CHARS) -> list[str]:
    """Sentence-aware soft split. Falls back to paragraph and then char split
    only if sentences are pathologically long."""
    if len(text) <= max_chars:
        return [text]
    out: list[str] = []
    for para in re.split(r"\n\s*\n", text):
        para = para.strip()
        if not para: continue
        if len(para) <= max_chars:
            out.append(para)
            continue
        # Sentence-pack
        sentences = SENT_RE.split(para)
        cur = ""
        for s in sentences:
            if not cur:
                cur = s
            elif len(cur) + 1 + len(s) <= max_chars:
                cur = cur + " " + s
            else:
                out.append(cur)
                cur = s
        if cur:
            out.append(cur)
    # Final safety: any chunk still > max → hard char-split.
    final = []
    for c in out:
        if len(c) <= max_chars:
            final.append(c)
            continue
        for i in range(0, len(c), max_chars):
            final.append(c[i:i + max_chars])
    return final


def chunk_file(text: str) -> list[tuple[str | None, str]]:
    """Returns [(heading_or_None, chunk_text), ...]."""
    if ONE_PER_FILE:
        # Take the H1 (if any) + lead paragraphs up to MAX_CHARS. Keeps each
        # file as one memory with file-level identity.
        h1_match = H1_RE.search(text)
        if h1_match:
            head = text[h1_match.start():]
        else:
            head = text
        head = head.strip()
        if len(head) > MAX_CHARS:
            # Soft-truncate at sentence boundary near MAX_CHARS.
            cut = head[:MAX_CHARS]
            last_period = max(cut.rfind(". "), cut.rfind("!\n"), cut.rfind("?\n"))
            if last_period > MIN_CHARS:
                head = cut[:last_period + 1]
            else:
                head = cut
        if len(head) < MIN_CHARS:
            return []
        return [(None, head)]
    # Original H2-first + size-cap path (kept for reference / Phase 3b).
    out: list[tuple[str | None, str]] = []
    for heading, body in split_h2_sections(text):
        for piece in soft_split_by_size(body):
            if len(piece) >= MIN_CHARS:
                out.append((heading, piece))
    return out


# ----- Metadata extraction --------------------------------------------------
DATE_IN_NAME_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")


def extract_filename_date(name: str) -> str | None:
    m = DATE_IN_NAME_RE.search(name)
    return m.group(1) if m else None


def file_title(text: str, fallback: str) -> str:
    h1 = H1_RE.search(text)
    if h1: return h1.group(1).strip()
    # filename without trailing date and extension
    name = os.path.splitext(fallback)[0]
    name = re.sub(r"-?\d{4}-\d{2}-\d{2}$", "", name)
    name = re.sub(r"^[0-9]+-", "", name)
    return name.replace("-", " ").title()


CAPITALIZED = re.compile(r"\b([A-Z][A-Za-z0-9]+(?:[-._][A-Za-z0-9]+)*)\b")
ACRONYM     = re.compile(r"\b([A-Z]{2,}[0-9]*)\b")
NOISE = {
    # alphabet noise
    "I","II","III","IV","TODO","FIXME","WIP","OK","YES","NO",
    # tech-tag noise
    "HTTP","HTTPS","URL","API","JSON","XML","CSV","PDF","UTF","ASCII","HTML",
    # English caps
    "The","A","An","And","But","If","When","Where","What","Who","How","Why",
    "Also","New","Phase","Stage","LIVE","Default","Note","See","Add","Adds","Added",
    "This","That","These","Those","Some","Any","All","One","Two","Three",
    "Now","Then","Here","There","Yes","Yet",
    # corpus-specific noise (job-application boilerplate)
    "Data","Hunter","Resume","CV","Cover","Letter","Job","Role","Position",
    "Company","Team","Stage","Round","Interview","Apply","Applied",
    "Python","Excel","SQL","Word","Office",  # too generic to query as entities
    "F","E","C","B","D","Step","Phase",
}


def extract_entities(text: str, hints: list[str] | None = None) -> list[str]:
    out = set()
    for m in CAPITALIZED.findall(text):
        if m in NOISE: continue
        if len(m) < 3 and not m.isupper(): continue
        out.add(m)
    for m in ACRONYM.findall(text):
        if m in NOISE: continue
        out.add(m)
    for hint in (hints or []):
        out.add(hint)
    return sorted(out)


# ----- Build memories -------------------------------------------------------
def note_id_for(rel_path: str) -> str:
    h = hashlib.sha1(rel_path.encode("utf-8")).hexdigest()
    return "n" + h[:10]


def synthesize_memories(root: str, sources: dict[str, str]) -> tuple[list[dict], dict]:
    memories: list[dict] = []
    survey = {"sources": {}, "files": 0, "chunks": 0}

    for bucket, source_root in sources.items():
        if not os.path.isdir(source_root):
            survey["sources"][bucket] = {"present": False}
            continue
        files = collect_markdown(source_root)
        per_bucket = {"files": len(files), "chunks": 0}
        survey["sources"][bucket] = per_bucket
        for path in files:
            rel = os.path.relpath(path, root)
            try:
                with open(path, "r", encoding="utf-8") as f:
                    text = f.read()
            except (UnicodeDecodeError, OSError):
                continue
            if len(text.strip()) < MIN_CHARS:
                continue
            filename = os.path.basename(path)
            title = file_title(text, filename)
            file_date = extract_filename_date(filename)
            mtime = datetime.fromtimestamp(os.path.getmtime(path), tz=timezone.utc).isoformat().replace("+00:00", "Z")
            occurred_at = (
                f"{file_date}T12:00:00Z" if file_date else mtime
            )
            nid = note_id_for(rel)

            for chunk_idx, (heading, chunk_text) in enumerate(chunk_file(text)):
                hint_entities = []
                if heading: hint_entities.append(heading)
                if title and title not in hint_entities: hint_entities.append(title)
                ents = extract_entities(chunk_text, hints=hint_entities)
                tags = [bucket, "prose"]
                if file_date: tags.append("dated")

                memories.append({
                    "id": f"{nid}-c{chunk_idx:02d}",
                    "text": chunk_text,
                    "created_at": mtime,
                    "occurred_at": occurred_at,
                    "source": bucket,
                    "source_bucket": bucket,
                    "file_path": rel,
                    "filename": filename,
                    "title": title,
                    "section_heading": heading,
                    "note_id": nid,
                    "chunk_id": chunk_idx,
                    "tags": tags,
                    "entities": ents,
                })
                per_bucket["chunks"] += 1
                survey["chunks"] += 1
            survey["files"] += 1
    return memories, survey


# ----- Stratified query templates ------------------------------------------
def stratified_queries(memories: list[dict]) -> list[dict]:
    ents = Counter()
    for m in memories:
        for e in m["entities"]: ents[e] += 1

    # Filter to entities that look like real names: title-case multi-letter,
    # OR acronyms ≥ 3 chars, OR multi-word things in headings.
    top_ents = []
    for e, c in ents.most_common(80):
        if c < 2: continue
        if len(e) <= 2: continue
        if e.lower() in {"prose", "writing", "voice"}: continue
        top_ents.append(e)
        if len(top_ents) >= 30: break

    days = sorted({m["occurred_at"][:10] for m in memories if m.get("occurred_at")})
    queries: list[dict] = []
    seen = set()

    def add(qid: str, q: str):
        if q in seen: return
        seen.add(q)
        queries.append({"id": qid, "query": q, "grades": {}})

    # Entity queries: pull company names from career-ops/reports filenames
    # (`NNN-company-name-YYYY-MM-DD.md`). These are the real proper-noun
    # entities the corpus discusses; the auto-extracted top-N from text is
    # too noisy on this prose ("Developer", "Strong", "Comp" etc.).
    company_re = re.compile(r"^\d+-([a-z0-9-]+?)-\d{4}-\d{2}-\d{2}$")
    companies: list[str] = []
    for m in memories:
        fn = os.path.splitext(m.get("filename", ""))[0]
        cm = company_re.match(fn)
        if not cm: continue
        slug = cm.group(1)
        # Take first two slug parts as company name (e.g., "pearl-health" → "pearl health";
        # "recursion-molecular-dynamics" → "recursion molecular").
        parts = slug.split("-")
        if len(parts) >= 2 and len(parts[0]) > 2:
            company = " ".join(parts[:2])
        else:
            company = parts[0]
        if len(company) >= 5:
            companies.append(company)
    seen_co = set()
    uniq_companies = [c for c in companies if not (c in seen_co or seen_co.add(c))]
    for i, e in enumerate(uniq_companies[:10]):
        add(f"q-people-{i:02d}", f"what did I write about {e}")
    # Topic / project queries (~8)
    topic_seeds = [
        "research role applications",
        "clinical data analyst opportunities",
        "machine learning roles",
        "voice and writing observations",
        "compensation discussions",
        "small-team or startup applications",
        "career transition planning",
        "feedback or rejections received",
    ]
    for i, q in enumerate(topic_seeds):
        add(f"q-topic-{i:02d}", q)

    # Temporal (~6) — pick distinct days, span across
    if days:
        sample_days = days[::max(1, len(days) // 6)][:6]
        for i, d in enumerate(sample_days):
            add(f"q-time-{i:02d}", f"around {d} what was going on")
    # Event/place queries (~5)
    place_seeds = [
        "remote-only opportunities",
        "applications mentioning Bay Area or San Francisco",
        "applications related to biotech or molecular work",
        "infrastructure or platform engineering roles",
        "research scientist tracks",
    ]
    for i, q in enumerate(place_seeds):
        add(f"q-event-{i:02d}", q)
    # Sentiment / reflection (~5)
    sentiment_seeds = [
        "applications I felt strongly about",
        "rough or frustrating applications",
        "excited about an opportunity",
        "writing voice observations I wanted to remember",
        "lessons from past applications",
    ]
    for i, q in enumerate(sentiment_seeds):
        add(f"q-feel-{i:02d}", q)
    # Mixed (~4)
    mixed_seeds = [
        "early April applications to data roles",
        "later applications that came after voice work",
        "prose-craft observations that match a job report",
        "applications with a research bent",
    ]
    for i, q in enumerate(mixed_seeds):
        add(f"q-mixed-{i:02d}", q)
    return queries


# ----- Auto-grading per Phase 3a heuristics --------------------------------
def grade_query(q: dict, memories: list[dict]) -> dict[str, int]:
    """Per-query rules. Conservative: prefer leaving grades empty over forcing
    bad matches. The user can promote/demote by hand later."""
    qid = q["id"]
    qt = q["query"]
    out: dict[str, int] = {}

    if qid.startswith("q-people-"):
        target = qt.replace("what did I write about ", "").strip()
        target_words = [w for w in target.split() if len(w) >= 3]
        for m in memories:
            t = m["text"].lower()
            fn = m.get("filename", "").lower()
            # Slug-match in filename = grade 2 (canonical "this report is about <company>")
            slug_hit = all(w.lower() in fn for w in target_words)
            text_hit = all(re.search(rf"\b{re.escape(w)}\b", t) for w in target_words)
            if slug_hit: out[m["id"]] = 2
            elif text_hit: out[m["id"]] = 1

    elif qid.startswith("q-topic-"):
        # Look for the core topic words in text
        kws = [w for w in re.findall(r"[a-zA-Z]{4,}", qt) if w.lower() not in {"role", "what", "about", "applications"}]
        if not kws: return out
        for m in memories:
            t = m["text"].lower()
            hits = sum(1 for k in kws if k.lower() in t)
            if hits >= 2: out[m["id"]] = 2
            elif hits == 1: out[m["id"]] = 1

    elif qid.startswith("q-time-"):
        match = re.search(r"\d{4}-\d{2}-\d{2}", qt)
        if not match: return out
        target = match.group(0)
        for m in memories:
            d = (m.get("occurred_at") or "")[:10]
            if not d: continue
            if d == target: out[m["id"]] = 2
            else:
                try:
                    diff = abs((datetime.fromisoformat(d) - datetime.fromisoformat(target)).days)
                    if diff <= 2: out[m["id"]] = 1
                except ValueError:
                    pass

    elif qid.startswith("q-event-"):
        kws = [w.lower() for w in re.findall(r"[a-zA-Z]{4,}", qt)
               if w.lower() not in {"applications", "mentioning", "related"}]
        if not kws: return out
        for m in memories:
            t = m["text"].lower()
            hits = sum(1 for k in kws if k in t)
            if hits >= 2: out[m["id"]] = 2
            elif hits == 1: out[m["id"]] = 1

    elif qid.startswith("q-feel-"):
        sentiment_words = ["frustrating", "rough", "excited", "exciting",
                           "loved", "hated", "disappointed", "great",
                           "strong", "interesting", "voice", "lesson"]
        for m in memories:
            t = m["text"].lower()
            if any(w in t for w in sentiment_words):
                if "voice" in qt.lower() and "voice" in t: out[m["id"]] = 2
                else: out[m["id"]] = 1

    elif qid.startswith("q-mixed-"):
        kws = [w.lower() for w in re.findall(r"[a-zA-Z]{4,}", qt)
               if len(w) >= 5]
        if not kws: return out
        for m in memories:
            t = m["text"].lower()
            hits = sum(1 for k in kws if k in t)
            if hits >= 2: out[m["id"]] = 1
    return out


# ----- Main ----------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=DEFAULT_ROOT,
                    help=f"root directory containing the source subdirs (default: {DEFAULT_ROOT})")
    ap.add_argument("--out", default=DEFAULT_OUT,
                    help=f"output directory (default: {DEFAULT_OUT})")
    ap.add_argument("--source", action="append", default=[],
                    help="name:path pairs to override default sources, e.g. --source notes:/path/to/notes")
    args = ap.parse_args()

    sources = {
        "prose-craft":        os.path.join(args.root, "prose-craft"),
        "career-ops/reports": os.path.join(args.root, "career-ops", "reports"),
    }
    for spec in args.source:
        if ":" not in spec:
            print(f"warning: --source needs name:path form, got {spec!r}", file=sys.stderr); continue
        name, path = spec.split(":", 1)
        sources[name] = os.path.expanduser(path)

    os.makedirs(args.out, exist_ok=True)

    memories, survey = synthesize_memories(args.root, sources)
    queries = stratified_queries(memories)
    for q in queries:
        q["grades"] = grade_query(q, memories)

    mp = os.path.join(args.out, "memories.jsonl")
    qtp = os.path.join(args.out, "queries.template.jsonl")
    qp  = os.path.join(args.out, "queries.jsonl")
    ep  = os.path.join(args.out, "entities.json")

    with open(mp, "w") as f:
        for m in memories: f.write(json.dumps(m) + "\n")
    with open(qtp, "w") as f:
        for q in queries: f.write(json.dumps(q) + "\n")
    with open(qp, "w") as f:
        for q in queries: f.write(json.dumps(q) + "\n")

    ents = Counter()
    for m in memories:
        for e in m["entities"]: ents[e] += 1
    with open(ep, "w") as f:
        json.dump({
            "n_memories": len(memories),
            "n_queries": len(queries),
            "survey": survey,
            "top_entities": ents.most_common(60),
            "date_range": [
                min((m["occurred_at"][:10] for m in memories), default=None),
                max((m["occurred_at"][:10] for m in memories), default=None),
            ]
        }, f, indent=2)

    n_g2 = sum(sum(1 for v in q["grades"].values() if v == 2) for q in queries)
    n_g1 = sum(sum(1 for v in q["grades"].values() if v == 1) for q in queries)
    no_truth = sum(1 for q in queries if not q["grades"])
    print(f"wrote {len(memories)} memories from {survey['files']} files → {mp}")
    print(f"  prose-craft chunks:        {survey['sources'].get('prose-craft', {}).get('chunks', 0)}")
    print(f"  career-ops/reports chunks: {survey['sources'].get('career-ops/reports', {}).get('chunks', 0)}")
    print(f"wrote {len(queries)} queries → {qp}")
    print(f"  total grade-2 cells: {n_g2}")
    print(f"  total grade-1 cells: {n_g1}")
    print(f"  queries with no graded relevant memory (no-truth): {no_truth}")


if __name__ == "__main__":
    sys.exit(main() or 0)
