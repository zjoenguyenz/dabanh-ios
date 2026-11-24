#!/usr/bin/env python3
"""
highlight_collector.py — Đá Banh highlight index collector (Part C, 1.34).

Unattended, stdlib-only. Run from the repo root:

    python3 tools/highlight_collector.py [--no-push] [--days 7]

What it does:
  1. Finds FT matches for 5 competitions over the last N days via the ESPN
     scoreboard API (per-day queries).
  2. For each match, looks for highlight sources:
       (a) ESPN summary endpoint videos -> direct MP4 (kind "espn-mp4",
           official=True, label "ESPN"). NOTE: ESPN's attach is editorial —
           reporter pieces, pressers and studio talk ride along with the
           reels, so every video passes the DB-23 classifier
           (is_espn_highlight) before it may become a source.
       (b) YouTube: a small seed map of previously verified videos (from the
           demo build, DEMO-HIGHLIGHT-REPORT.md) re-verified live, plus a
           generic search function (youtube_search) that parses the YouTube
           search-results page. EVERY YouTube id is verified through the
           oEmbed endpoint (HTTP 200) before inclusion; unverified = excluded.
           FULL-HIGHLIGHT STANDARD (owner, 2026-11-22 17:28 CST: "Chỉ lấy
           clip full highlight / Ko có thì thôi"): a YouTube video becomes
           a source ONLY if its oEmbed title passes
           is_youtube_full_highlight — a full-match highlight signal
           ("highlight" / "resumen") with no talking or single-moment
           signal, naming both teams, and consistent with the match's
           date/score when the title carries them. Partials, interviews
           and wrong-match uploads are excluded; a match with no full
           highlight yet simply has no YouTube source.
  3. Merges progressively into ./highlights.json: matches keyed by
     competition + espnEventId; sources deduped by (kind, ref) and never
     removed just because a newer one arrived; matches older than N days
     (by matchDate) are pruned at write time.
  4. Unless --no-push, pushes ONLY highlights.json to zjoenguyenz/dabanh-ios
     main via /opt/hatch/bin/github push-files, then fetches the raw URL
     back and verifies byte count + md5 against the local file.

No API keys, no secrets anywhere in this design.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_PATH = os.path.join(REPO_ROOT, "highlights.json")
RAW_URL = "https://raw.githubusercontent.com/zjoenguyenz/dabanh-ios/main/highlights.json"
GITHUB_CLI = "/opt/hatch/bin/github"
MANIFEST_PATH = os.path.expanduser("~/push-hl.manifest")

COMPETITIONS = {
    "eng.1": "premier-league",
    "esp.1": "la-liga",
    "uefa.champions": "champions-league",
    "uefa.europa": "europa-league",
    "uefa.europa.conf": "conference-league",
}

# Broadcaster / league channels treated as "official" for the official flag.
OFFICIAL_CHANNEL_HINTS = [
    "laliga", "nbc sports", "sky sports", "cbs sports", "espn", "uefa",
    "premier league", "tnt sports", "bein sports",
]

# Seed map from the demo build (DEMO-HIGHLIGHT-REPORT.md, verified 2026-11-22).
# Keyed by (competition, home, away). Every id is RE-VERIFIED via oEmbed at
# run time; ids that now fail are dropped and logged.
# durationSec is carried only where the demo actually measured it (193/194);
# the two Liverpool videos' durations were not retrievable -> None.
SEED_VIDEOS = {
    ("premier-league", "Liverpool", "Manchester United"): [
        {"ref": "WyJJGWj09To", "label": "NBC Sports", "official": True, "durationSec": None},
        {"ref": "eJShdUmAqMc", "label": "Dollar VFX", "official": False, "durationSec": None},
    ],
    ("premier-league", "Newcastle United", "Arsenal"): [
        {"ref": "I7ooFa4RCvQ", "label": "Sky Sports Premier League", "official": True, "durationSec": 193},
    ],
    ("la-liga", "Barcelona", "Villarreal"): [
        {"ref": "Ngrd58fZSVA", "label": "LALIGA EA SPORTS", "official": True, "durationSec": 194},
    ],
}

UA = {"User-Agent": "Mozilla/5.0 (dabanh-highlight-collector/1.0)"}
# Generic YouTube search is best-effort and slow from some networks; cap the
# number of generic searches per run so an unattended run stays bounded.
MAX_GENERIC_SEARCHES = 6
GENERIC_CANDIDATES_PER_MATCH = 2


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_canon(raw):
    """Normalize any ISO8601 date string to YYYY-MM-DDTHH:MM:SSZ.

    FL-405: ESPN emits kickoff dates WITHOUT seconds
    ("2026-11-22T20:00Z"); the app's ISO8601 reader requires the
    seconds field, so an un-normalized date made every match in
    the file unreadable. Every date this collector writes goes
    through here — seconds always present.
    """
    dt = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def http_get(url, timeout=30):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def http_json(url, timeout=30):
    status, body = http_get(url, timeout=timeout)
    return json.loads(body.decode("utf-8", "replace"))


def log(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------- ESPN ----

def fetch_ft_matches(days):
    """Per-day ESPN scoreboard queries; returns list of match dicts (no sources)."""
    matches = []
    today = datetime.now(timezone.utc).date()
    for slug, comp_name in COMPETITIONS.items():
        for back in range(days):
            day = today - timedelta(days=back)
            url = ("https://site.api.espn.com/apis/site/v2/sports/soccer/"
                   f"{slug}/scoreboard?dates={day.strftime('%Y%m%d')}")
            try:
                data = http_json(url)
            except Exception as exc:  # noqa: BLE001 — log and continue per-day
                log(f"  ! scoreboard {slug} {day} failed: {exc}")
                continue
            for ev in data.get("events", []):
                try:
                    comp = ev["competitions"][0]
                    st = comp["status"]["type"]
                    if st.get("name") != "STATUS_FULL_TIME" and not st.get("completed"):
                        continue
                    home = away = None
                    sh = sa = None
                    for c in comp["competitors"]:
                        name = c["team"]["displayName"]
                        score = c.get("score")
                        if c.get("homeAway") == "home":
                            home, sh = name, score
                        else:
                            away, sa = name, score
                    if home is None or away is None or sh is None or sa is None:
                        continue
                    matches.append({
                        "competition": comp_name,
                        "slug": slug,
                        "home": home,
                        "away": away,
                        "scoreHome": int(sh),
                        "scoreAway": int(sa),
                        "matchDate": iso_canon(ev["date"]),
                        "espnEventId": str(ev["id"]),
                        "sources": [],
                    })
                except Exception as exc:  # noqa: BLE001
                    log(f"  ! event parse failed ({slug} {day}): {exc}")
    return matches


# DB-23: the ESPN summary endpoint attaches EVERY editorial video to a
# match — reporter stand-ups, manager pressers, studio talk — not just
# highlights (owner caught a James Olley reporter piece playing as the
# "ESPN highlight" of Newcastle 2-2 Arsenal, 2026-11-22). Classification
# rule built from sampled payloads of all 13 ESPN-carrying matches in
# the 2026-11-22 index (see theme-mu/FIX-COLLECTOR-DB23-REPORT.md):
#   KEEP  — headline or description carries the highlight signal: the
#           word "highlight". In every sampled payload that is exactly
#           ESPN's reel format: headline "<Home> vs. <Away> - Game
#           Highlights", description "Watch the Game Highlights from
#           <Home> vs. <Away>, <date>".
#   DROP  — no highlight signal. This covers BOTH the talking pieces
#           (reporter/pundit/presser) and the single-moment clips
#           (one goal / one save), whose headlines never carry it.
#   GUARD — even WITH a highlight signal, a video whose headline or
#           description carries a talking verb observed in the sampled
#           non-highlights (discuss/react/explain/talk about/disagree/
#           question) is dropped: the fault class wins ties.
ESPN_TALKING_SIGNALS = ("discuss", "react", "explain", "talk about",
                        "disagree", "question")


def is_espn_highlight(video):
    """True only for a genuine ESPN highlight reel (DB-23 rule above)."""
    text = ((video.get("headline") or "") + " "
            + (video.get("description") or "")).lower()
    if "highlight" not in text:
        return False
    return not any(sig in text for sig in ESPN_TALKING_SIGNALS)


def espn_summary_sources(slug, event_id):
    """Classified highlight reels from the ESPN summary endpoint (DB-23:
    only videos passing is_espn_highlight become sources)."""
    url = (f"https://site.api.espn.com/apis/site/v2/sports/soccer/"
           f"{slug}/summary?event={event_id}")
    out = []
    try:
        data = http_json(url)
    except Exception as exc:  # noqa: BLE001
        log(f"    ! summary {event_id} failed: {exc}")
        return out
    for v in data.get("videos", []) or []:
        href = (((v.get("links") or {}).get("source") or {}).get("href")) or ""
        if not href.endswith(".mp4"):
            continue
        if not is_espn_highlight(v):
            log(f"    - espn non-highlight dropped: {v.get('headline')!r}")
            continue
        dur = v.get("duration")
        out.append({
            "kind": "espn-mp4",
            "ref": href,
            "label": "ESPN",
            "official": True,
            "durationSec": int(dur) if isinstance(dur, (int, float)) else None,
            "addedAt": now_iso(),
        })
    return out


# -------------------------------------------------------------- YouTube ----

_oembed_cache = {}


def youtube_verify(video_id):
    """Verify via oEmbed. Returns oEmbed JSON dict on HTTP 200, else None."""
    if video_id in _oembed_cache:
        return _oembed_cache[video_id]
    url = ("https://www.youtube.com/oembed?url="
           + urllib.parse.quote(f"https://www.youtube.com/watch?v={video_id}", safe="")
           + "&format=json")
    result = None
    try:
        status, body = http_get(url, timeout=25)
        if status == 200:
            result = json.loads(body.decode("utf-8", "replace"))
    except Exception as exc:  # noqa: BLE001
        log(f"    ! oEmbed {video_id} failed: {exc}")
    _oembed_cache[video_id] = result
    return result


def is_official_channel(author_name):
    a = (author_name or "").lower()
    return any(h in a for h in OFFICIAL_CHANNEL_HINTS)


# FULL-HIGHLIGHT STANDARD for YouTube (owner, 2026-11-22 17:28 CST:
# "Chỉ lấy clip full highlight / Ko có thì thôi" — full match-highlight
# reels ONLY; no partial clips, no interviews, no filler; a match with
# no full highlight yet shows nothing). Rule built from the real titles
# of all 16 YouTube sources audited 2026-11-22 (see theme-mu/
# FIX-COLLECTOR-FULLHL-REPORT.md). A video becomes a source ONLY if its
# title passes EVERY check in is_youtube_full_highlight:
#   KEEP signal — "highlight" (NBC "PREMIER LEAGUE HIGHLIGHTS", Sky
#     "Premier League Highlights", club "HIGHLIGHTS - Extended") or
#     "resumen" (LALIGA EA SPORTS official per-match format "RESUMEN
#     LALIGA EA SPORTS"). No signal -> not a certified full reel -> out.
#     This alone convicts scorer-headline report packages with no
#     highlight claim (AFC Bournemouth's "Evanilson and Kluivert
#     strike as winning run continues | AFC Bournemouth 2-0 ...").
#   TALKING guard — a talking signal (the DB-23 ESPN list plus
#     interview / press conference / podcast / reaction) drops the
#     video even WITH a keep signal: the fault class wins ties.
#   MOMENT guard — single-moment headline patterns ("goal by",
#     "scores", "red card", "sent off", "save", "penalty miss"...)
#     drop the video even WITH a keep signal.
#   FIXTURE guard — the title must name BOTH teams (any significant
#     token of each, accent-folded), and when it carries an M/D/YYYY
#     date or an N-N score, they must equal the match's. This convicts
#     the wrong-match class found in the audit: NBC's Sunderland v.
#     Aston Villa highlights of 9/21/2025 (last season's reverse
#     fixture) had ridden the old first-word relevance gate into the
#     2026-11-21 Aston Villa 0-0 Sunderland entry.
YT_TALKING_SIGNALS = ESPN_TALKING_SIGNALS + (
    "interview", "press conference", "presser", "podcast", "reaction",
    "preview", "prediction",
)
YT_MOMENT_PATTERNS = (
    r"\bgoal by\b", r"\bscores\b", r"\bscored\b", r"\bred card\b",
    r"\bsent off\b", r"\bsave\b", r"\bsaves\b", r"\bpenalty miss",
    r"\bmisses penalty\b", r"\bmissed penalty\b", r"\bown goal\b",
)
_TEAM_TOKEN_STOP = {"football", "club", "afc", "cf", "fc", "sc", "the"}


def _fold(text):
    """Lowercase + strip accents for title/team matching."""
    nfkd = unicodedata.normalize("NFKD", text or "")
    return "".join(c for c in nfkd if not unicodedata.combining(c)).lower()


def _team_tokens(name):
    toks = re.findall(r"[a-z0-9]+", _fold(name))
    return {t for t in toks if len(t) >= 4 and t not in _TEAM_TOKEN_STOP}


def is_youtube_full_highlight(title, match):
    """(keep, reason) — the full-highlight standard above, applied to an
    oEmbed title for `match` (dict with home/away/scoreHome/scoreAway/
    matchDate)."""
    t = _fold(title)
    if not t.strip():
        return False, "empty title"
    for sig in YT_TALKING_SIGNALS:
        if sig in t:
            return False, f"talking signal {sig!r}"
    if "highlight" not in t and "resumen" not in t:
        return False, "no full-highlight signal (highlight/resumen)"
    for pat in YT_MOMENT_PATTERNS:
        if re.search(pat, t):
            return False, f"single-moment pattern {pat!r}"
    for side in ("home", "away"):
        toks = _team_tokens(match[side])
        if toks and not any(tok in t for tok in toks):
            return False, f"{side} team not named in title"
    md = re.search(r"\b(\d{1,2})/(\d{1,2})/(\d{2,4})\b", t)
    if md:
        month, day, year = int(md.group(1)), int(md.group(2)), int(md.group(3))
        if year < 100:
            year += 2000
        want = (match["matchDate"] or "")[:10]  # YYYY-MM-DD (UTC kickoff)
        if f"{year:04d}-{month:02d}-{day:02d}" != want:
            return False, (f"title date {month}/{day}/{year} != match date {want} "
                           "(wrong match?)")
    scores = re.findall(r"\b(\d{1,2})\s*[-–]\s*(\d{1,2})\b", t)
    if scores and (str(match["scoreHome"]), str(match["scoreAway"])) not in scores:
        return False, (f"title score(s) {scores} != match score "
                       f"{match['scoreHome']}-{match['scoreAway']} (wrong match?)")
    return True, "full-highlight title"


def youtube_title_gate(meta, match, origin):
    """Apply the full-highlight standard to an oEmbed result. Returns the
    title when the video may become a source, else None (drop logged)."""
    title = (meta or {}).get("title") or ""
    keep, reason = is_youtube_full_highlight(title, match)
    if not keep:
        log(f"    - {origin} youtube dropped: {title!r} ({reason})")
        return None
    return title


def youtube_search(query, limit=6):
    """Replaceable YouTube search (no API key): parse the search-results page
    for videoIds. Returns [] on any failure — callers must treat an empty
    result as 'search unavailable', not 'no videos exist'."""
    url = ("https://www.youtube.com/results?search_query="
           + urllib.parse.quote_plus(query))
    try:
        status, body = http_get(url, timeout=25)
    except Exception as exc:  # noqa: BLE001
        log(f"    ! youtube search failed ({query!r}): {exc}")
        return []
    if status != 200:
        log(f"    ! youtube search HTTP {status} ({query!r})")
        return []
    html = body.decode("utf-8", "replace")
    ids = []
    for vid in re.findall(r'"videoId":"([A-Za-z0-9_-]{11})"', html):
        if vid not in ids:
            ids.append(vid)
        if len(ids) >= limit:
            break
    return ids


def seed_sources_for(match):
    out = []
    key = (match["competition"], match["home"], match["away"])
    for seed in SEED_VIDEOS.get(key, []):
        meta = youtube_verify(seed["ref"])
        if meta is None:
            log(f"    - seed {seed['ref']} for {match['home']} v {match['away']}: "
                "oEmbed FAILED at run time — dropped")
            continue
        if youtube_title_gate(meta, match, "seed") is None:
            continue
        author = meta.get("author_name") or seed["label"]
        out.append({
            "kind": "youtube",
            "ref": seed["ref"],
            "label": author,
            "official": bool(seed["official"] or is_official_channel(author)),
            "durationSec": seed["durationSec"],
            "addedAt": now_iso(),
        })
        log(f"    + seed {seed['ref']} ({author}) verified via oEmbed")
    return out


def generic_youtube_sources(match):
    """Best-effort generic search for a match with no YouTube source yet.
    Every candidate must pass oEmbed AND the full-highlight title
    standard (is_youtube_full_highlight — both teams named, highlight
    signal, no talking/moment signals, date/score consistent). The old
    first-word relevance gate let a year-old reverse-fixture video in
    (see the classifier note); candidates are now scanned until
    GENERIC_CANDIDATES_PER_MATCH have PASSED, not just been seen."""
    query = f"{match['home']} vs {match['away']} highlights"
    ids = youtube_search(query)
    out = []
    for vid in ids:
        if len(out) >= GENERIC_CANDIDATES_PER_MATCH:
            break
        meta = youtube_verify(vid)
        if meta is None:
            continue
        if youtube_title_gate(meta, match, "search") is None:
            continue
        author = meta.get("author_name") or "YouTube"
        out.append({
            "kind": "youtube",
            "ref": vid,
            "label": author,
            "official": is_official_channel(author),
            "durationSec": None,
            "addedAt": now_iso(),
        })
        log(f"    + search {vid} ({author}) verified via oEmbed")
    return out


# ---------------------------------------------------------------- merge ----

def match_key(m):
    return (m["competition"], m.get("espnEventId") or f"{m['home']}|{m['away']}|{m['matchDate']}")


def load_existing():
    if not os.path.exists(OUT_PATH):
        return {}
    try:
        data = json.loads(open(OUT_PATH, encoding="utf-8").read())
        return {match_key(m): m for m in data.get("matches", [])}
    except Exception as exc:  # noqa: BLE001
        log(f"! existing highlights.json unreadable ({exc}); starting fresh")
        return {}


def merge(existing, fresh_matches, days):
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    merged = dict(existing)
    for m in fresh_matches:
        k = match_key(m)
        if k in merged:
            old = merged[k]
            have = {(s["kind"], s["ref"]) for s in old.get("sources", [])}
            for s in m["sources"]:
                if (s["kind"], s["ref"]) not in have:
                    old["sources"].append(s)
                    have.add((s["kind"], s["ref"]))
            old.update({f: m[f] for f in
                        ("home", "away", "scoreHome", "scoreAway", "matchDate")})
        else:
            merged[k] = m
    kept, pruned = [], 0
    for m in merged.values():
        try:
            md = datetime.fromisoformat(m["matchDate"].replace("Z", "+00:00"))
        except Exception:  # noqa: BLE001
            md = None
        if md is not None and md < cutoff:
            pruned += 1
            continue
        # Heal legacy entries written before iso_canon existed.
        try:
            m["matchDate"] = iso_canon(m["matchDate"])
        except Exception:  # noqa: BLE001
            pass
        m.pop("slug", None)
        kept.append(m)
    kept.sort(key=lambda x: x["matchDate"], reverse=True)
    return kept, pruned


# ----------------------------------------------------------------- push ----

def push_and_verify():
    with open(MANIFEST_PATH, "wb") as fh:
        fh.write(b"highlights.json\x00")
    cmd = [GITHUB_CLI, "push-files", "--owner", "zjoenguyenz", "--repo", "dabanh-ios",
           "--branch", "main", "--message", "highlights: collector seed/update",
           "--source-dir", REPO_ROOT, "--paths-file", MANIFEST_PATH]
    log("$ " + " ".join(cmd))
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        # FL-405 follow-up (observed twice, 2026-11-22 + 2026-11-23):
        # in unattended runs the push-files call can stall past the
        # timeout on its approval round-trip while the commit lands
        # server-side anyway. Ground truth is the remote content —
        # fall through to the verify loop instead of failing here.
        log("! push-files timed out after 600s — verifying by remote content")
        proc = None
    if proc is not None:
        log(proc.stdout.strip())
        if proc.stderr.strip():
            log("stderr: " + proc.stderr.strip())
        if proc.returncode != 0:
            log(f"! push failed rc={proc.returncode}")
            return False
    local = open(OUT_PATH, "rb").read()
    local_md5 = hashlib.md5(local).hexdigest()
    log(f"local highlights.json: {len(local)} bytes md5={local_md5}")
    # Raw CDN can lag a few seconds behind a push; retry briefly.
    import time
    for attempt in range(6):
        try:
            status, body = http_get(RAW_URL, timeout=30)
            if status == 200:
                r_md5 = hashlib.md5(body).hexdigest()
                log(f"raw fetch attempt {attempt + 1}: {len(body)} bytes md5={r_md5}")
                if r_md5 == local_md5:
                    log("VERIFY OK: raw URL content matches local file (md5 equal)")
                    return True
        except Exception as exc:  # noqa: BLE001
            log(f"raw fetch attempt {attempt + 1} failed: {exc}")
        time.sleep(10)
    log("! VERIFY FAILED: raw URL content did not match local file in time")
    return False


# ----------------------------------------------------------------- main ----

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-push", action="store_true")
    ap.add_argument("--days", type=int, default=7)
    args = ap.parse_args()

    log(f"=== highlight_collector run {now_iso()} (window {args.days} days) ===")
    fresh = fetch_ft_matches(args.days)
    per_comp = {}
    for m in fresh:
        per_comp[m["competition"]] = per_comp.get(m["competition"], 0) + 1
    log(f"FT matches found: {len(fresh)} — {per_comp}")

    searches_used = 0
    for m in fresh:
        label = f"{m['home']} {m['scoreHome']}-{m['scoreAway']} {m['away']} [{m['competition']}]"
        srcs = []
        srcs += espn_summary_sources(m.pop("slug"), m["espnEventId"])
        srcs += seed_sources_for(m)
        if not any(s["kind"] == "youtube" for s in srcs) and searches_used < MAX_GENERIC_SEARCHES:
            searches_used += 1
            srcs += generic_youtube_sources(m)
        m["sources"] = srcs
        log(f"  {label}: {len(srcs)} source(s) "
            f"({', '.join(s['kind'] + ':' + s['label'] for s in srcs) or 'none yet'})")

    existing = load_existing()
    kept, pruned = merge(existing, fresh, args.days)
    payload = {"version": 1, "generatedAt": now_iso(), "matches": kept}
    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    total_src = sum(len(m["sources"]) for m in kept)
    log(f"wrote {OUT_PATH}: {len(kept)} matches, {total_src} sources, pruned {pruned}")

    if args.no_push:
        log("--no-push: stopping before push")
        return 0
    ok = push_and_verify()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
