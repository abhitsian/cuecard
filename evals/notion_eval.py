#!/usr/bin/env python3
"""Does Cuecard's Notion context get fetched well, and does it change the questions Cuecard suggests?

Usage: notion_eval.py <cases-dir> <out-dir> [--only <case-id-substring>] [--jobs 4]

Each case is a JSON file: {id, title, with: [names], mode, goal, lines: [[You|Them, text], ...], expect_none}.
Cases hold real meeting content, so keep them (and the results) out of this repo.

Stage 1, retrieval: runs `Cuecard --notion` for the meeting as Cuecard sees it at the start (title, attendees).
Stage 2, use: runs `Cuecard --simulate` on the transcript slice twice, with the Notion brief as context and
without, and collects the question bank and live ASK cards from each.

Checks (thresholds fixed before the first run):
  R1 abstain      code   made-up meetings come back NONE                           all
  R2 citations    code   brief bullets name a Notion page in parentheses           >= 80%
  R3 relevance    judge  brief bullets relate to this meeting                      >= 70%
  R4 latency      code   Notion lookup time                                        <= 150 s
  U1 anchors      code   questions containing a Notion-only detail, with vs without >= 30% with, <= 5% without
  U2 uptake       judge  questions relying on a Notion fact not in the transcript   >= 30% with
  U3 faithful     judge  of those, the fact is stated as the brief states it        >= 90%
The judge is Claude Sonnet through `claude -p`, the same model family that writes the questions, so U2/U3
measure agreement with the brief, not ground truth. Calibrate it: label judge_sample.csv and compare.

Changes after the first run (2026-09-25), recorded because they came after seeing results:
- Cases carry their start time and the lookup ignores later Notion pages; the first run found each past
  meeting's own recap in Notion, which inflated uptake.
- The U3 judge failed open questions about things the brief doesn't cover; it now fails only a contradiction.
  Thresholds unchanged.
"""
import concurrent.futures as cf, csv, json, random, re, subprocess, sys, tempfile, time
from pathlib import Path

APP = Path.home() / "Applications/Cuecard.app/Contents/MacOS/Cuecard"
CLAUDE = next(p for p in [Path.home() / ".local/bin/claude", Path("/opt/homebrew/bin/claude"), Path("/usr/local/bin/claude")] if p.exists())
THRESHOLDS = {"R2": 0.80, "R3": 0.70, "R4": 150, "U1_with": 0.30, "U1_without": 0.05, "U2": 0.30, "U3": 0.90}
COMMON = set("""The This That These Those What When Where Which Who Why How And But For With From Into Open Last Time
Background Items Notion Task Tracker Meeting Notes Page Pages None Owner Owners Team Teams Monday Tuesday Wednesday
Thursday Friday Saturday Sunday January February March April May June July August September October November December
You Them Your They Their There Here Also Still Next Director Brief Wiki Status High Medium Low""".split())


def run(cmd, timeout, input_text=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=input_text)
        return r.stdout
    except subprocess.TimeoutExpired as e:
        return (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")


# ---------- stage 1: retrieval ----------

def fetch(case):
    cmd = [str(APP), "--notion", case["title"], "--mode", case["mode"]]
    if case["with"]:
        cmd += ["--with", ", ".join(case["with"])]
    if case.get("start"):
        cmd += ["--as-of", case["start"]]  # past meetings: ignore Notion pages written after they happened
    start = time.time()
    out = run(cmd, 300)
    seconds = time.time() - start
    brief = re.sub(r"\n\[seconds=\d+\]\s*$", "", out.strip()).strip()
    none = brief.upper().startswith("NONE") or not brief
    return {"brief": "" if none else brief, "none": none, "seconds": round(seconds)}


def bullets(brief):
    return [l.strip()[2:].strip() for l in brief.splitlines() if l.strip().startswith(("- ", "* "))]


# ---------- stage 2: use ----------

def simulate(case, context):
    script = [f"# title: {case['title']}"]
    if case["with"]:
        script.append("# with: " + ", ".join(case["with"]))
    if case.get("goal"):
        script.append(f"# goal: {case['goal']}")
    script += [f"# context: {l}" for l in context.splitlines() if l.strip()]
    script += [f"{who}: {text}" for who, text in case["lines"]]
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(script))
    out = run([str(APP), "--simulate", f.name, case["mode"]], 600)
    asks = [m[1].strip() for m in re.finditer(r"^\s+[\d.]+s\s+\+ ASK (.*?)\s+‹", out, re.M)]
    bank = []
    tail = out.split("\nbank (", 1)
    if len(tail) == 2:
        bank = [m[1].strip() for m in re.finditer(r"[·✓] \[[^\]]*\] (.+)", tail[1])]
    questions = list(dict.fromkeys(bank + asks))  # the same card can print twice
    return {"asks": asks, "bank": bank, "questions": questions, "raw_tail": out[-3000:]}


STOP = set("""about after again against their there these those which while would could should being other every
between through during before where because under still since without within across first later today really
review meeting notes items update updates needs needed people using based issue issues""".split())


def anchors(brief, case):
    """Words only Notion could have supplied: task IDs, and distinctive words (5+ letters) in the brief that are
    not in the title, attendees or transcript. Questions paraphrase, so this matches on words, not phrases."""
    seen = set(re.findall(r"[a-z][a-z-]+", (case["title"] + " " + " ".join(t for _, t in case["lines"]) + " "
                                             + " ".join(case["with"])).lower()))
    found = set(re.findall(r"\bTT-\d+\b", brief))
    body = re.sub(r"\([^)]*\)", " ", brief)  # page names in citations aren't content
    for word in re.findall(r"[a-z][a-z-]{4,}", body.lower()):
        if word not in seen and word not in STOP and word.lower() not in {c.lower() for c in COMMON}:
            found.add(word)
    return found


def uses_anchor(question, found):
    q = question.lower()
    hits = [a for a in found if re.search(rf"\b{re.escape(a.lower())}\b", q)]
    # A task ID alone is enough; otherwise two Notion-only words, so one shared common word doesn't count.
    return any(a.startswith("TT-") for a in hits) or len(hits) >= 2


# ---------- judges ----------

def judge(prompt):
    out = run([str(CLAUDE), "-p", "--model", "sonnet", "--tools", ""], 300, prompt)
    m = re.search(r"\[.*\]", out, re.S)
    try:
        return json.loads(m[0]) if m else []
    except json.JSONDecodeError:
        return []


def judge_relevance(case, items):
    if not items:
        return []
    listing = "\n".join(f"{i + 1}. {b}" for i, b in enumerate(items))
    return judge(f"""A meeting assistant looked up the user's Notion before this meeting.
Meeting title: {case['title']}
Attendees: {', '.join(case['with']) or '(none listed)'}
What was said early on:
{chr(10).join(f'{w}: {t}' for w, t in case['lines'])}

For each item it found, answer one question: does this item relate to what this meeting is about (its topic,
its attendees, or work discussed in it)? Relate means a participant would plausibly find it useful in this
meeting. Unrelated means it is about other work.

Items:
{listing}

Reply with only JSON: [{{"i": 1, "relevant": true}}, ...]""")


def judge_uptake(case, brief, questions):
    if not questions:
        return []
    listing = "\n".join(f"{i + 1}. {q}" for i, q in enumerate(questions))
    return judge(f"""You are checking whether suggested questions draw on a Notion brief.
Meeting title: {case['title']}
Transcript so far:
{chr(10).join(f'{w}: {t}' for w, t in case['lines'])}

Notion brief:
{brief or '(none)'}

For each question answer two things.
uses_notion: does the question rely on a specific fact (a task, decision, date, owner, number, prior meeting)
that appears in the Notion brief and does NOT appear in the transcript or title? Generic questions that could
be asked without the brief are false.
faithful: only when uses_notion is true. False only if the question states or implies something that
CONTRADICTS the brief (a wrong owner, date, status or number). Asking about something the brief doesn't cover is
faithful. Otherwise null.

Questions:
{listing}

Reply with only JSON: [{{"i": 1, "uses_notion": false, "faithful": null}}, ...]""")


# ---------- running ----------

def ratio(num, den):
    return round(num / den, 3) if den else None


def evaluate(case, out_dir):
    r = {"id": case["id"], "title": case["title"], "expect_none": case["expect_none"]}
    got = fetch(case)
    r.update(got)
    items = bullets(got["brief"])
    r["R1"] = got["none"] if case["expect_none"] else None
    r["R2"] = ratio(sum(1 for b in items if re.search(r"\([^)]+\)\s*\.?$", b)), len(items))
    rel = judge_relevance(case, items)
    r["relevance"] = rel
    r["R3"] = ratio(sum(1 for x in rel if x.get("relevant")), len(rel))
    r["R4"] = got["seconds"]
    with cf.ThreadPoolExecutor(2) as pool:
        with_run, without_run = pool.map(lambda ctx: simulate(case, ctx), [got["brief"], ""])
    r["with"], r["without"] = with_run, without_run
    found = anchors(got["brief"], case)
    r["anchors"] = sorted(found)
    for name, runres in (("with", with_run), ("without", without_run)):
        qs = runres["questions"]
        r[f"U1_{name}"] = ratio(sum(1 for q in qs if uses_anchor(q, found)), len(qs)) if found else (0.0 if qs else None)
        verdicts = judge_uptake(case, got["brief"], qs) if got["brief"] else []
        runres["verdicts"] = verdicts
        used = [v for v in verdicts if v.get("uses_notion")]
        r[f"U2_{name}"] = ratio(len(used), len(verdicts)) if verdicts else (0.0 if qs else None)
        r[f"U3_{name}"] = ratio(sum(1 for v in used if v.get("faithful")), len(used))
    (out_dir / f"{case['id']}.json").write_text(json.dumps(r, indent=1))
    print(f"done {case['id']}: brief={'NONE' if got['none'] else len(items)} bullets, "
          f"questions with={len(with_run['questions'])} without={len(without_run['questions'])}", flush=True)
    return r


def mean(values):
    vs = [v for v in values if v is not None]
    return round(sum(vs) / len(vs), 3) if vs else None


def report(results, out_dir):
    real = [r for r in results if not r["expect_none"]]
    fake = [r for r in results if r["expect_none"]]
    s = {
        "R1 abstain": (f"{sum(1 for r in fake if r['R1'])}/{len(fake)}", all(r["R1"] for r in fake)),
        "R2 citations": (mean(r["R2"] for r in real), (mean(r["R2"] for r in real) or 0) >= THRESHOLDS["R2"]),
        "R3 relevance": (mean(r["R3"] for r in real), (mean(r["R3"] for r in real) or 0) >= THRESHOLDS["R3"]),
        "R4 latency (max s)": (max(r["R4"] for r in results), max(r["R4"] for r in results) <= THRESHOLDS["R4"]),
        "U1 anchors with": (mean(r["U1_with"] for r in real), (mean(r["U1_with"] for r in real) or 0) >= THRESHOLDS["U1_with"]),
        "U1 anchors without": (mean(r["U1_without"] for r in real), (mean(r["U1_without"] for r in real) or 0) <= THRESHOLDS["U1_without"]),
        "U2 uptake with": (mean(r["U2_with"] for r in real), (mean(r["U2_with"] for r in real) or 0) >= THRESHOLDS["U2"]),
        "U2 uptake without (control)": (mean(r["U2_without"] for r in real), None),
        "U3 faithful": (mean(r["U3_with"] for r in real), (mean(r["U3_with"] for r in real) or 0) >= THRESHOLDS["U3"]),
    }
    lines = ["# Cuecard Notion context eval", "", f"{len(real)} real meetings, {len(fake)} made-up (should be NONE).", "",
             "| Check | Result | Pass |", "|---|---|---|"]
    for k, (v, ok) in s.items():
        lines.append(f"| {k} | {v} | {'—' if ok is None else ('pass' if ok else 'FAIL')} |")
    lines += ["", "## Per meeting", "", "| Meeting | Brief | s | R3 | Qs with / without | U1 with | U2 with | U2 without |", "|---|---|---|---|---|---|---|---|"]
    for r in results:
        lines.append(f"| {r['title'][:48]} | {'NONE' if r['none'] else str(len(bullets(r['brief']))) + ' items'} | {r['R4']} | {r['R3']} | "
                     f"{len(r['with']['questions'])} / {len(r['without']['questions'])} | {r['U1_with']} | {r['U2_with']} | {r['U2_without']} |")
    (out_dir / "report.md").write_text("\n".join(lines) + "\n")
    # A sample of judge verdicts for a person to label, to calibrate the judge.
    rows = []
    for r in real:
        for q, v in zip(r["with"]["questions"], r["with"].get("verdicts", [])):
            rows.append([r["id"], q, v.get("uses_notion"), v.get("faithful"), "", ""])
    random.Random(7).shuffle(rows)
    with (out_dir / "judge_sample.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["case", "question", "judge_uses_notion", "judge_faithful", "your_uses_notion", "your_faithful"])
        w.writerows(rows[:30])
    print("\n".join(lines))


def main():
    cases_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    jobs = int(sys.argv[sys.argv.index("--jobs") + 1]) if "--jobs" in sys.argv else 3
    out_dir.mkdir(parents=True, exist_ok=True)
    cases = [json.loads(p.read_text()) for p in sorted(cases_dir.glob("*.json"))]
    if only:
        cases = [c for c in cases if only in c["id"]]
    with cf.ThreadPoolExecutor(jobs) as pool:
        results = list(pool.map(lambda c: evaluate(c, out_dir), cases))
    (out_dir / "results.json").write_text(json.dumps(results, indent=1))
    report(results, out_dir)


if __name__ == "__main__":
    main()
