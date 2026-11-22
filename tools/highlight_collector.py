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
           some clips are highlights, some are studio analysis (study §1.2).
       (b) YouTube: a small seed map of previously verified videos (from the
           demo build, DEMO-HIGHLIGHT-REPORT.md) re-verified live, plus a
           generic search function (youtube_search) that parses the YouTube
           search-results page. EVERY YouTube id is verified through the
           oEmbed endpoint (HTTP 200) before inclusion; unverified = excluded.
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
                        "matchDate": ev["date"].replace("+00:00", "Z"),
                        "espnEventId": str(ev["id"]),
                        "sources": [],
                    })
                except Exception as exc:  # noqa: BLE001
                    log(f"  ! event parse failed ({slug} {day}): {exc}")
    return matches


def espn_summary_sources(slug, event_id):
    """Direct-MP4 videos from the ESPN summary endpoint."""
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
    """Best-effort generic search for a match with no YouTube source yet."""
    query = f"{match['home']} vs {match['away']} highlights"
    ids = youtube_search(query)
    out = []
    for vid in ids[:GENERIC_CANDIDATES_PER_MATCH]:
        meta = youtube_verify(vid)
        if meta is None:
            continue
        author = meta.get("author_name") or "YouTube"
        title = (meta.get("title") or "").lower()
        # Cheap relevance gate: at least one team name fragment in the title.
        frags = [match["home"].split()[0].lower(), match["away"].split()[0].lower()]
        if not any(f in title for f in frags):
            continue
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
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
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
