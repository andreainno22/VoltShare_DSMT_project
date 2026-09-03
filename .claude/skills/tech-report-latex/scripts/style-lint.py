#!/usr/bin/env python3
"""Lint stilistico per prosa tecnica in inglese (.tex o .md).

Non corregge e non giudica: conta i pattern che i rilevatori di testo generato usano come
indicatori, e stampa dove stanno. Le decisioni restano a chi scrive.

    python style-lint.py doc/sections/*.tex
    python style-lint.py --quiet doc/main.tex      # solo il riepilogo
    python style-lint.py --max-hits 3 doc/         # una directory: prende .tex e .md

Codice di uscita: 1 se almeno una metrica è in FAIL, 0 altrimenti.
"""

import argparse
import bisect
import glob
import math
import os
import re
import sys

# ---------------------------------------------------------------- soglie
# Per mille parole, salvo dove indicato. Tarate su prosa tecnica, non su narrativa.
THRESHOLDS = {
    "em_dash":        (0.0, 0.0),    # (warn, fail) - regola: zero
    "blacklist":      (0.5, 1.5),
    "hedging":        (0.3, 1.0),
    "connectives":    (1.0, 2.5),
    "neg_parallel":   (0.3, 0.8),
    "neg_appositive": (0.4, 1.0),
    "rather_than":    (2.5, 5.0),
    "dangling_ing":   (3.0, 6.0),
    "inflated_verbs": (1.5, 3.5),
    "ensure":         (1.0, 2.5),
}
SENT_SD_MIN = (9.0, 7.0)      # (warn sotto, fail sotto)
BULLET_RATIO_MAX = (0.35, 0.5)

# ---------------------------------------------------------------- pattern
BLACKLIST = [
    "delve", "intricate", "pivotal", "crucial", "vital", "testament", "tapestry",
    "realm", "landscape", "robust", "seamless", "cutting-edge", "state-of-the-art",
    "game-changing", "comprehensive", "holistic", "myriad", "plethora", "leverage",
    "leverages", "leveraging", "utilize", "utilizes", "utilizing", "utilise",
    "showcase", "showcases", "foster", "fosters", "underscore", "underscores",
    "streamline", "streamlines", "elevate", "unlock", "harness", "paramount",
    "ever-evolving", "meticulous", "nuanced", "multifaceted",
]

HEDGING = [
    r"it is important to note", r"it is worth noting", r"it is worth mentioning",
    r"it should be noted", r"generally speaking", r"broadly speaking",
    r"in many cases", r"as we can see", r"needless to say",
]

CONNECTIVES = [r"moreover", r"furthermore", r"additionally", r"in conclusion",
               r"overall", r"in summary", r"to summarize", r"to summarise",
               r"last but not least"]

NEG_PARALLEL = [r"not just\b", r"not only\b", r"instead of merely",
                r"is not (?:a|an|about) .{0,50}?(?:, it is|; it is| but rather)"]

# La forma appositiva: "X, not Y" / "X and not Y" / "X and never Y" / "not X but Y",
# piu' la coppia di frasi "... is not a Z. It is ...". E' la stessa figura del
# parallelismo negativo e la piu' riconoscibile di tutte, ed e' quella in cui si
# cade "correggendo" un rather than.
NEG_APPOSITIVE = [
    r",\s+(?:and\s+)?not\s+(?!only\b|just\b)[a-z\\\{]",
    # "X and never Y" con Y nominale e' la figura; "and never arrives" e' descrittivo
    r"\band\s+never\s+(?:the|a|an|its|his|her|their)\b",
    r"\bnot\s+\w+\s+but\s+\w+",
    r"\bis\s+not\s+(?:a|an|the)\b[^.]{0,70}\.\s+It\s+is\b",
]

# "rather than" è spesso una comparazione legittima: soglia separata e più larga
RATHER_THAN = [r"\brather than\b", r"\binstead of\b"]

INFLATED_VERBS = [r"serves? as\b", r"acts? as\b", r"plays? a (?:key|crucial|vital) role",
                  r"is designed to\b", r"are designed to\b", r"represents? a\b",
                  r"constitutes?\b", r"facilitates?\b", r"boasts?\b",
                  r"provides? the ability to\b"]

# "guarantee" come sostantivo e' legittimo; qui interessa solo il verbo
ENSURE = [r"\bensur(?:e|es|ing|ed)\b", r"\bguarantees\s+that\b"]

# ", ensuring ..." / ", allowing ..." a fine proposizione
DANGLING_ING = [r",\s+(?:ensuring|allowing|enabling|providing|highlighting|making|"
                r"resulting|thereby|thus|reflecting|demonstrating|showcasing|"
                r"offering|creating|improving|reducing|increasing|leading)\b"]

# "A, B and C" / "A, B, and C" con tre elementi brevi e di lunghezza simile.
# Il prefisso consuma copule e preposizioni, altrimenti il primo elemento si
# mangerebbe mezza proposizione ("the architecture is robust" invece di "robust").
_ELEM = r"[A-Za-z][\w\-]*(?:\s+[A-Za-z][\w\-]*){0,2}"
TRICOLON = re.compile(
    r"(?:^|[.;:,]\s+|\b(?:is|are|was|were|be|been|being|as|of|with|to|into|between|"
    r"provides?|offers?|has|have|remains?|becomes?)\s+)"
    r"(" + _ELEM + r"),\s+(" + _ELEM + r"),?\s+and\s+(" + _ELEM + r")\b(?=[\s,.;:])",
    re.IGNORECASE)

EM_DASH = re.compile(r"---|\u2014|(?<![0-9\\])--(?![0-9-])")

# ---------------------------------------------------------------- pulizia sorgente
TEX_ENVS_TO_DROP = ["lstlisting", "verbatim", "tabular", "tabularx", "table",
                    "figure", "equation", "align", "tikzpicture", "thebibliography"]


def strip_source(text, is_tex):
    """Toglie ciò che non è prosa, tenendo il numero di riga allineato."""
    lines = text.splitlines()
    out = []
    in_fence = False
    drop_until = None

    for line in lines:
        keep = line

        if is_tex:
            keep = re.sub(r"(?<!\\)%.*$", "", keep)          # commenti LaTeX
            if drop_until:
                if re.search(r"\\end\{" + drop_until + r"\}", keep):
                    drop_until = None
                out.append("")
                continue
            m = re.search(r"\\begin\{(" + "|".join(TEX_ENVS_TO_DROP) + r")\*?\}", keep)
            if m:
                drop_until = re.escape(m.group(1))
                out.append("")
                continue
            keep = re.sub(r"\\(?:label|ref|cref|Cref|cite|input|include|usepackage|"
                          r"documentclass|lstinline|url|href)\s*\{[^}]*\}", " ", keep)
            keep = re.sub(r"\\(?:section|subsection|subsubsection|paragraph|caption)"
                          r"\*?\{([^}]*)\}", r"\1.", keep)
            keep = re.sub(r"\\(?:textbf|textit|emph|texttt|textsc)\{([^}]*)\}", r"\1", keep)
            keep = re.sub(r"\$[^$]*\$", " MATH ", keep)
            keep = re.sub(r"\\[a-zA-Z@]+\*?", " ", keep)
            keep = keep.replace("{", " ").replace("}", " ")
        else:
            if line.strip().startswith("```"):
                in_fence = not in_fence
                out.append("")
                continue
            stripped = line.strip()
            if (in_fence
                    or stripped.startswith("|")             # tabelle
                    or re.fullmatch(r"[-*_]{3,}", stripped)):  # righe orizzontali
                out.append("")
                continue
            keep = re.sub(r"`[^`]*`", " CODE ", keep)
            keep = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", keep)
            keep = re.sub(r"^\s{0,3}#{1,6}\s*", "", keep)
            keep = re.sub(r"\*\*([^*]*)\*\*", r"\1", keep)

        out.append(keep)

    return out


def is_bullet(line, is_tex):
    s = line.strip()
    if is_tex:
        return s.startswith(r"\item")
    return bool(re.match(r"^([-*+]|\d+\.)\s+", s))


def sentences(text):
    text = re.sub(r"\b(?:e\.g|i\.e|cf|etc|vs|Fig|Sec|Eq|Dr|Mr|Ms)\.", "ABBR", text)
    parts = re.split(r"(?<=[.!?])\s+(?=[A-Z(\"'])", text)
    return [p.strip() for p in parts if len(p.split()) >= 3]


def join_lines(lines):
    """Testo unito piu' la tabella offset->riga.

    I pattern vanno cercati sul testo unito: in un .tex il sorgente va a capo ogni
    ottanta colonne, e una terzina o un 'It is important to note' spezzato in due
    righe sfuggirebbe a una ricerca riga per riga.
    """
    text, starts = "", []
    for i, line in enumerate(lines, 1):
        starts.append(len(text))
        text += line + "\n"
    return text, starts


def line_of(offset, starts):
    return bisect.bisect_right(starts, offset)


def find_all(patterns, text, starts, lines, flags=re.IGNORECASE | re.MULTILINE,
             word=False):
    hits = []
    for pat in patterns:
        rx = re.compile(r"\b" + re.escape(pat) + r"\b" if word else pat, flags)
        for m in rx.finditer(text):
            n = line_of(m.start(), starts)
            frag = " ".join(m.group(0).split())
            hits.append((n, frag, lines[n - 1].strip() if n <= len(lines) else ""))
    return sorted(hits)


def tricolon_hits(text, starts, lines):
    """Terzine sospette: tre elementi brevi e di lunghezza confrontabile.

    Indicatore debole. Enumerare tre componenti di un sistema e' legittimo; il
    segnale e' la ripetizione del pattern, non la singola occorrenza.
    """
    hits = []
    stop = {"which", "that", "this", "these", "those", "it", "they", "who",
            "when", "where", "never", "always", "not", "and", "or", "but",
            "there", "here", "he", "she", "we", "you"}
    for m in TRICOLON.finditer(text):
        elems = [" ".join(p.split()) for p in m.groups()]
        if any(len(e.split()) > 3 for e in elems):
            continue
        # Un elemento che comincia con una parola funzionale non e' una voce di
        # enumerazione: e' una proposizione tagliata a meta' dal pattern.
        if any(e.split()[0].lower() in stop for e in elems):
            continue
        lengths = [len(e) for e in elems]
        if max(lengths) <= 2.5 * min(lengths) and max(lengths) <= 30:
            n = line_of(m.start(), starts)
            hits.append((n, " ".join(m.group(0).split()),
                         lines[n - 1].strip() if n <= len(lines) else ""))
    return hits


def per_mille(n, words):
    return 0.0 if words == 0 else 1000.0 * n / words


def verdict(value, warn, fail, lower_is_better=True):
    if lower_is_better:
        if value > fail:
            return "FAIL"
        return "WARN" if value > warn else "ok"
    if value < fail:
        return "FAIL"
    return "WARN" if value < warn else "ok"


def analyse(path, args):
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
    is_tex = path.lower().endswith(".tex")
    lines = strip_source(raw, is_tex)
    prose = "\n".join(lines)
    words = len(re.findall(r"[A-Za-z][A-Za-z'\-]+", prose))
    if words < 40:
        return None

    sents = sentences(re.sub(r"\s+", " ", prose))
    lens = [len(s.split()) for s in sents]
    mean = sum(lens) / len(lens) if lens else 0.0
    sd = math.sqrt(sum((x - mean) ** 2 for x in lens) / len(lens)) if len(lens) > 1 else 0.0

    # Sul sorgente grezzo: strip_source ha gia' cancellato i marcatori di lista.
    body = [l for l in raw.splitlines() if l.strip()]
    bullets = sum(1 for l in body if is_bullet(l, is_tex))
    bullet_ratio = bullets / len(body) if body else 0.0

    text, starts = join_lines(lines)
    checks = {
        "em_dash":        find_all([EM_DASH.pattern], text, starts, lines),
        "blacklist":      find_all(BLACKLIST, text, starts, lines, word=True),
        "hedging":        find_all(HEDGING, text, starts, lines),
        "connectives":    find_all([r"(?:^|(?<=[.;:])\s+)" + c for c in CONNECTIVES],
                                   text, starts, lines),
        "neg_parallel":   find_all(NEG_PARALLEL, text, starts, lines),
        "neg_appositive": find_all(NEG_APPOSITIVE, text, starts, lines),
        "rather_than":    find_all(RATHER_THAN, text, starts, lines),
        "dangling_ing":   find_all(DANGLING_ING, text, starts, lines),
        "inflated_verbs": find_all(INFLATED_VERBS, text, starts, lines),
        "ensure":         find_all(ENSURE, text, starts, lines),
    }
    tricolons = tricolon_hits(text, starts, lines)

    print(f"\n=== {path}")
    print(f"    {words} parole, {len(sents)} frasi, "
          f"media {mean:.1f}, SD {sd:.1f}, elenchi {bullet_ratio:.0%}")

    worst = "ok"
    rank = {"ok": 0, "WARN": 1, "FAIL": 2}

    for key, hits in checks.items():
        warn, fail = THRESHOLDS[key]
        rate = per_mille(len(hits), words)
        v = verdict(rate, warn, fail)
        worst = v if rank[v] > rank[worst] else worst
        if hits or v != "ok":
            print(f"    [{v:4}] {key:15} {len(hits):3} occorrenze ({rate:.1f}/1000)")
            if not args.quiet:
                for i, m, line in hits[:args.max_hits]:
                    snippet = line if len(line) <= 96 else line[:93] + "..."
                    print(f"           L{i:<5} {m!r}  |  {snippet}")
                if len(hits) > args.max_hits:
                    print(f"           ... e altre {len(hits) - args.max_hits}")

    if tricolons:
        rate = per_mille(len(tricolons), words)
        v = "ok" if rate <= 1.0 else ("WARN" if rate <= 2.5 else "FAIL")
        worst = v if rank[v] > rank[worst] else worst
        print(f"    [{v:4}] {'tricolon':15} {len(tricolons):3} terzine simmetriche")
        if not args.quiet:
            for i, m, _ in tricolons[:args.max_hits]:
                print(f"           L{i:<5} {m!r}")

    v = verdict(sd, SENT_SD_MIN[0], SENT_SD_MIN[1], lower_is_better=False)
    worst = v if rank[v] > rank[worst] else worst
    print(f"    [{v:4}] {'burstiness':15} SD {sd:.1f} (obiettivo >= {SENT_SD_MIN[0]})")

    v = verdict(bullet_ratio, *BULLET_RATIO_MAX)
    worst = v if rank[v] > rank[worst] else worst
    print(f"    [{v:4}] {'bullet_ratio':15} {bullet_ratio:.0%} "
          f"(obiettivo <= {BULLET_RATIO_MAX[0]:.0%})")

    return worst


def collect(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for ext in ("tex", "md"):
                files += glob.glob(os.path.join(p, "**", f"*.{ext}"), recursive=True)
        elif any(ch in p for ch in "*?["):
            files += glob.glob(p, recursive=True)
        else:
            files.append(p)
    return sorted(set(files))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="file .tex/.md, glob o directory")
    ap.add_argument("--quiet", action="store_true", help="solo i conteggi")
    ap.add_argument("--max-hits", type=int, default=5,
                    help="occorrenze mostrate per pattern (default 5)")
    args = ap.parse_args()

    files = collect(args.paths)
    if not files:
        print("nessun file trovato", file=sys.stderr)
        return 2

    results = [r for r in (analyse(f, args) for f in files) if r]
    failed = results.count("FAIL")
    warned = results.count("WARN")
    print(f"\n{len(results)} file analizzati: {failed} FAIL, {warned} WARN, "
          f"{results.count('ok')} ok")
    print("Le soglie sono indicatori, non verdetti: guarda le occorrenze, non il punteggio.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
