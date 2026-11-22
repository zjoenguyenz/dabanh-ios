import Foundation

/// ONE shared team-name normalization + matching layer (FIX-127,
/// 2026-11-20, owner order: fix the whole name-variant fault family
/// completely, in one pass — no more per-name patches).
///
/// Before this module existed, three layers each reduced team names
/// their own way and disagreed exactly on spelling variants:
/// - FixtureGrouping normalised with a filler drop but NO aliases,
///   so one match split into several fixture cards whenever sources
///   spelled it differently ("Al Ahli" vs "Al-Ahli Jeddah",
///   "FK Rostov" vs "FC Rostov" vs "FC Rostov … Samara",
///   "Ý U17" vs "Italy U17", "Bờ Biển Ngà U17" vs "Ivory Coast U17").
/// - MatchMatching canonicalised with private alias tables whose
///   whole-name lookup ran on the UNSTRIPPED name, so "y u17"
///   missed the "y" → "italy" alias and a youth fixture could never
///   bind its state (DB-04 variant 2).
/// - Crests keyed its learned-logo registry with the grouping
///   reduction while cards looked badges up by other spellings, so
///   a feed-carried logo (Al-Ahli, Krylya Sovetov) sat in the
///   registry under a key the lookup never produced.
///
/// Every layer now calls THIS module — FixtureGrouping for fixture
/// identity, MatchMatching for state binding, Crests for the static
/// map candidates and the learned-logo registry — and no layer
/// keeps a private normalization or alias table.
///
/// The pipeline (one pass over the name, in order):
/// 1. `norm` — lowercase, special-letter fold (ı→i, ø→o, æ→ae,
///    œ→oe, ß→ss, ł→l, ð→d, þ→th — letters the diacritic fold
///    cannot decompose; without it FotMob's "Sumqayıt" reduced to
///    "sumqay t" and "Iğdır" to "igd r"), diacritics stripped,
///    only [a-z0-9 ] kept (all of that is Crests.norm over the
///    pre-folded string).
/// 2. The leading Vietnamese club decoration "Câu lạc bộ (bóng
///    đá)" is dropped — the same phrase MatchTitle.fixtureKey
///    already strips; listings write "Câu lạc bộ bóng đá Rostov"
///    beside "FK Rostov" for one club.
/// 3. Age markers (U17/U19/U21/U23…, glued "u17" or split "u 17",
///    anywhere in the name) are EXTRACTED and re-attached as one
///    canonical trailing tag AFTER alias resolution — this is what
///    lets the stem hit the alias table ("y u17" → stem "y" →
///    "italy" → "italy u17") while a youth side still never
///    collides with its senior team ("italy" ≠ "italy u17").
/// 4. Filler tokens dropped (the union of the grouping set and
///    the matching layer's measured additions) plus standalone
///    all-numeric tokens.
/// 5. Token aliases (measured transliteration/spelling variants).
/// 6. Women's markers stripped from the stem edges — CANONICAL
///    key only; the grouping key keeps them, exactly as before
///    (marker discipline lives in the state lookup, and
///    LeagueClassifier's women/youth guard reads the grouping
///    key's markers).
/// 7. Trailing city qualifiers dropped while a stem remains
///    (measured set: "jeddah" — FotMob's "Al-Ahli Jeddah" is the
///    playlist's "Al Ahli"; "samara" — "Krylya Sovetov Samara" is
///    "Krylya Sovetov"). A qualifier is dropped ONLY from the
///    tail and ONLY while the surviving stem still contains at
///    least one non-generic token — one that identifies the
///    club — so a name that IS a place ("Samara" alone) is
///    untouched, a qualified name whose stem still identifies
///    the club is the only thing merged, and a name like
///    "Al-Jeddah" (article + qualifier, nothing else) keeps both
///    tokens instead of collapsing to the bare article. "doha"/"dubai" are deliberately NOT in
///    the set: "Al Ahli Doha" is a different club from the Saudi
///    Al-Ahli, and "Shabab Al-Ahli Dubai" is written with its
///    qualifier by every source alike — no evidence either drop
///    is needed, and the Doha one would be wrong.
/// 8. Whole-name aliases on the stem, then the Brazilian state
///    suffix strip, then whole-name aliases once more (the
///    measured tail of the old canonicalise: "vitoria salvador
///    ba" resolves on the first pass, "bragantino sp" on the
///    second).
///
/// Every alias entry exists because a real listing or feed
/// produced the variant (the tables carry their evidence dates);
/// the 2026-11-20 corpus run additionally verified that the
/// canonical keys merge NO two distinct clubs (zero collisions
/// across FotMob team-id pairs and ESPN team-id pairs).
enum TeamNameNorm {

    // MARK: - Tables (the ONE alias/normalization table set)

    /// Letters the Unicode diacritic fold cannot decompose,
    /// folded by hand before Crests.norm runs (step 1). Applied
    /// to the lowercased string.
    private static let specialLetters: [(String, String)] = [
        ("ı", "i"), ("ø", "o"), ("æ", "ae"), ("œ", "oe"),
        ("ß", "ss"), ("ł", "l"), ("ð", "d"), ("þ", "th"),
    ]

    /// Filler tokens: FixtureGrouping's measured set plus
    /// Addendum 2's measured additions — `de do da del` (particles),
    /// `dsc`, `sl`, `s` (possessive artifact), `futbol`/`football`
    /// (spelled-out FC). One union set for every layer now.
    /// `vfl`/`tsg` (2026-11-20, REVIEW-127B-LOOP2 Finding 1): the
    /// German club-form prefixes — ESPN and the playlist write
    /// "VfL Wolfsburg" / "VfL Bochum" / "TSG Hoffenheim" while
    /// FotMob and LiveScore write the bare names, so the prefixed
    /// spelling keyed apart from the bare one. The drop is
    /// symmetric (every source's spelling passes this same set),
    /// so a source that writes the prefix and one that does not
    /// land on the same stem either way.
    private static let fillerTokens: Set<String> = [
        "fc", "cf", "sc", "afc", "ca", "cd", "fk", "sk",
        "club", "clb", "ac", "as", "sd", "us", "ec",
        "de", "do", "da", "del", "dsc", "sl", "s", "futbol", "football",
        "vfl", "tsg",
    ]

    /// Women's markers (Addendum 2 §A2.1): stripped from the
    /// canonical key's stem edges; `hasWomenMarker` tests any
    /// position.
    private static let womenMarkers: Set<String> = [
        "women", "w", "nu", "feminin", "femmes", "femenino", "femenina",
    ]

    /// Token aliases (measured): applied per token after the
    /// filler drop.
    /// - munchen/wien/koln/mgladbach/lyonnes: Addendum 2 §A2.2.
    /// - krylia → krylya (2026-11-20): the playlist writes both
    ///   transliterations of Крылья; FotMob and Flashscore both
    ///   write "Krylya Sovetov".
    /// - sumgayit → sumqayit (2026-11-20): the playlist writes
    ///   "Sumgayit", Flashscore "Sumqayit", FotMob "Sumqayıt"
    ///   (which step 1 folds to "sumqayit").
    /// - heidenheimer → heidenheim (2026-11-20): a playlist
    ///   listing's demonym form ("Darmstadt vs Heidenheimer")
    ///   beside every feed's "Heidenheim".
    /// - utd → united (2026-11-20, REVIEW-127B-LOOP2 Finding 1):
    ///   the playlist writes "Manchester Utd", Flashscore writes
    ///   "Sydney Utd"; every feed's full form is "United", and
    ///   "Utd" is never anything but that abbreviation in a club
    ///   name, so the token map is safe at token level.
    /// - monchengladbach → gladbach (2026-11-20, REVIEW-127B-LOOP2
    ///   Finding 1): joins ESPN/FotMob/playlist "Borussia
    ///   Monchengladbach" to the "borussia gladbach" stem the
    ///   "borussia m gladbach" whole-name alias produces from
    ///   LiveScore's apostrophe spelling.
    /// - liviy → livyi, bereg → bereh (2026-11-20, near-miss
    ///   sweep): the Лівий Берег transliterations — FotMob
    ///   "Liviy Bereh", Flashscore "Livyi Bereg", the playlist
    ///   "Livyi Bereh", all one club in one measured fixture
    ///   (vs Shakhtar Donetsk, 2026-11-20). Same transliteration
    ///   idiom as krylia/sumgayit above.
    private static let tokenAliases: [String: String] = [
        "munchen": "munich",
        "wien": "vienna",
        "koln": "cologne",
        "mgladbach": "gladbach",
        "lyonnes": "lyon",
        "krylia": "krylya",
        "sumgayit": "sumqayit",
        "heidenheimer": "heidenheim",
        "utd": "united",
        "monchengladbach": "gladbach",
        "liviy": "livyi",
        "bereg": "bereh",
    ]

    /// Whole-name aliases: whole stem only, never substring.
    /// The first block is Addendum 2 §A2.2 (measured) plus the
    /// survey's VN national-team aliases (LIVESCORE-CLOCK-SURVEY
    /// §3.2). The second block is measured on the live playlist +
    /// feeds of 2026-11-20 (FIX-127 corpus):
    /// - "cote d ivoire" / "bo bien nga" → "ivory coast": the
    ///   playlist writes all three spellings of Côte d'Ivoire
    ///   (the VN one as "Bờ Biển Ngà", also as "U17 Bờ Biển Ngà")
    ///   beside FotMob's "Ivory Coast".
    /// - "bielefeld" → "arminia bielefeld": a playlist listing
    ///   writes bare "CLB Bielefeld"; every feed writes the full
    ///   club name.
    /// - "aarhus agf" / "agf aarhus" → "agf": playlist word-order
    ///   variants of FotMob's "AGF". The bare token "aarhus" is
    ///   deliberately NOT aliased — Aarhus Fremad is a different
    ///   club (FotMob id 8109, measured the same day).
    /// - "lyngby bk" → "lyngby": playlist suffix beside FotMob's
    ///   "Lyngby".
    /// - "sv darmstadt" → "darmstadt": ESPN writes "SV Darmstadt
    ///   98", FotMob writes "Darmstadt 98" — one club, two keys,
    ///   two fixture cards each bound to a different source.
    private static let wholeNameAliases: [String: String] = [
        "atletico penarol": "penarol",
        "montevideo city torque": "montevideo city",
        "servette chenois": "servette",
        "servette geneve": "servette",
        "vitoria ba": "vitoria",
        "rb bragantino": "bragantino",
        "red bull bragantino": "bragantino",
        "bragantino sp": "bragantino",
        "vitoria salvador ba": "vitoria",
        "koge": "hb koge",
        "anh": "england",
        "phap": "france",
        "y": "italy",
        "duc": "germany",
        "tay ban nha": "spain",
        "ha lan": "netherlands",
        "bo dao nha": "portugal",
        "bi": "belgium",
        "dan mach": "denmark",
        "thuy si": "switzerland",
        "ao": "austria",
        "ba lan": "poland",
        "sec": "czechia",
        "tho nhi ky": "turkiye",
        "nga": "russia",
        "han quoc": "south korea",
        "nhat ban": "japan",
        "my": "usa",
        "uc": "australia",
        "cote d ivoire": "ivory coast",
        "bo bien nga": "ivory coast",
        "bielefeld": "arminia bielefeld",
        "aarhus agf": "agf",
        "agf aarhus": "agf",
        "lyngby bk": "lyngby",
        "sv darmstadt": "darmstadt",
        // REVIEW-127B-LOOP2 Finding 1 (2026-11-20) — measured in
        // the round's own corpus, each pair on the same fixture
        // (same opponent, same date) across sources:
        // - "man city" → "manchester city": the playlist carries
        //   both spellings of the Fulham fixture (2026-11-21) as
        //   two groups, the short one unbindable; every feed
        //   writes the full name.
        // - "dortmund" → "borussia dortmund": a playlist listing
        //   writes bare "Dortmund" ("B. Monchengladbach vs
        //   Dortmund"); every feed writes the full club name.
        //   The bielefeld precedent, same shape.
        // - "borussia m gladbach" → "borussia gladbach":
        //   LiveScore's "Borussia M'gladbach" — step 1 turns the
        //   apostrophe into a space, stranding the "m"; the
        //   monchengladbach token alias lands the other sources
        //   on this same stem.
        // - "athletic bilbao" / "ath bilbao" → "athletic": the
        //   playlist's "Athletic Bilbao" (12 listings) and
        //   Flashscore's "Ath Bilbao" beside ESPN/FotMob
        //   "Athletic Club" (→ "athletic" via the club filler).
        // - "rcd espanyol" / "rcd espanyol barcelona" →
        //   "espanyol": the playlist's two RCD spellings of the
        //   same Athletic fixture beside the feeds' "Espanyol".
        "man city": "manchester city",
        "dortmund": "borussia dortmund",
        "borussia m gladbach": "borussia gladbach",
        "athletic bilbao": "athletic",
        "ath bilbao": "athletic",
        "rcd espanyol": "espanyol",
        "rcd espanyol barcelona": "espanyol",
        // Near-miss sweep dispositions (2026-11-20, FIX-127C) —
        // each measured on ONE fixture (same opponent + same
        // date) in the corpus; bare-stem entries passed the
        // aarhus test (no distinct club measured under the
        // target stem anywhere in the corpus):
        // - "atletico bucaramanga" → "bucaramanga" and
        //   "belgrano cordoba" → "belgrano": the playlist itself
        //   carries both spellings of one fixture (vs América de
        //   Cali / vs Vélez Sarsfield, 2026-11-21).
        // - "central coast" → "central coast mariners" and
        //   "machida" → "machida zelvia": playlist-internal
        //   splits of one fixture (vs Perth Glory / vs V-Varen
        //   Nagasaki, 2026-11-21); no competing club measured
        //   under either bare stem.
        // - "kvc westerlo" → "westerlo": playlist vs FotMob on
        //   the Cercle Brugge fixture (2026-11-21).
        // - "hellas verona f c" → "hellas verona": the split
        //   "F.C." decoration (step 1 spaces the dots) in
        //   playlist listings of the Cesena fixture. Bare
        //   "verona" (Flashscore) is deliberately NOT aliased:
        //   Chievo Verona is a second, distinct Verona club
        //   measured in the corpus — the aarhus shape.
        // - "es troyes" / "estac troyes" → "troyes": three
        //   playlist spellings of one Le Havre fixture
        //   (2026-11-21); "Troyes B" keeps its own stem.
        // - "hanoi" → "ha noi": the playlist's glued "Hanoi FC"
        //   beside FotMob's "Ha Nội FC" (Trường Tươi Đồng Nai
        //   fixture, 2026-11-21).
        // - "ogc nice" → "nice": playlist vs ESPN/FotMob on the
        //   Paris Saint-Germain fixture (2026-11-21).
        // - The Medellín family → "independiente medellin": the
        //   playlist's word-order "Medellin Independiente" and
        //   "Dep.Independiente Medellin" and Flashscore's
        //   "Ind. Medellin", all on the Santa Fe fixture
        //   (2026-11-21) that FotMob writes in full.
        // - "b gladbach" → "borussia gladbach": the playlist's
        //   "B. Monchengladbach vs Dortmund" listing — Finding 1
        //   item 3's own cited instance, split on both sides.
        //   The token alias lands its stem here ("b gladbach")
        //   after the "dortmund" alias closed the other side;
        //   same fixture, same date (2026-11-21) as the feeds'
        //   full spelling, and no other club produces this stem
        //   ("Bergisch Gladbach" keeps its own).
        "atletico bucaramanga": "bucaramanga",
        "belgrano cordoba": "belgrano",
        "central coast": "central coast mariners",
        "kvc westerlo": "westerlo",
        "hellas verona f c": "hellas verona",
        "es troyes": "troyes",
        "estac troyes": "troyes",
        "machida": "machida zelvia",
        "hanoi": "ha noi",
        "ogc nice": "nice",
        "medellin independiente": "independiente medellin",
        "ind medellin": "independiente medellin",
        "dep independiente medellin": "independiente medellin",
        "b gladbach": "borussia gladbach",
        // The other side of the same Medellín listings
        // (FIX-127C post-fix sweep): "Dep.Independiente
        // Medellin vs Independiente Santa Fe" — the feeds and
        // the playlist's own other listings write the opponent
        // as plain "Santa Fe" on the same fixture, so without
        // this entry those two listings still cannot bind.
        "independiente santa fe": "santa fe",
        // REVIEW-127C-LOOP1 Finding 1 (2026-11-20, FIX-127D) —
        // playlist spellings NO feed produces, while the
        // fixture's state exists in the pool under the feed
        // key; without these the groups can never bind (the
        // DB-08 render, and for Le Havre / Nam Định a duplicate
        // unbindable card beside the bindable one). Each
        // measured same-fixture (same opponent, same date) in
        // the corpus, each stem produced by one club only:
        // - "havre athletic" → "le havre": the playlist's
        //   "Havre Athletic Club" (6 listings) vs Troyes,
        //   2026-11-21; ESPN/FotMob/Flashscore all carry the
        //   state as "Le Havre".
        // - "xm hai phong" → "hai phong" and "thep xanh nam
        //   dinh" → "nam dinh": the playlist's sponsor
        //   spellings ("XM Hải Phòng", "Thép Xanh Nam Định")
        //   of the same V.League fixture, 2026-11-21; FotMob
        //   and LiveScore carry it as "hai phong vs nam dinh".
        // - "rc deportivo" → "deportivo a coruna": the
        //   playlist's "RC Deportivo" vs Deportivo Alavés,
        //   2026-11-21; FotMob/LiveScore carry the state
        //   under the full name (ESPN's bare "Deportivo"
        //   stays a feed-side split, as before).
        "havre athletic": "le havre",
        "xm hai phong": "hai phong",
        "thep xanh nam dinh": "nam dinh",
        "rc deportivo": "deportivo a coruna",
        // REVIEW-127C-LOOP1 §2.2 donation-loss tier (FIX-127D,
        // same pass, same proof standard — same opponent +
        // same date in the corpus; the playlist key itself
        // already binds, these close the stranded feed form so
        // its source can win and donate like the others):
        // - LiveScore's short K/J-League and J1 forms:
        //   "Jeonbuk FC" (vs Seoul, 2026-11-21), "Daejeon
        //   Citizen" (vs Gangwon, 2026-11-21), "Nagoya
        //   Grampus Eight" (vs Tokyo Verdy, 2026-11-21).
        // - ESPN's prefixed German forms: "TSV Eintracht
        //   Braunschweig" (vs Nürnberg, 2026-11-21) and
        //   LiveScore's anglicised "1. FC Nuremberg" on the
        //   same fixture.
        // - LiveScore's "Bodoe/Glimt" transliteration (vs
        //   Molde — the window's only Molde–Glimt fixture;
        //   every other source writes "Bodo Glimt").
        // - ESPN's French prefixed forms: "AJ Auxerre" (vs
        //   Monaco, 2026-11-21T19:45Z — FotMob/LiveScore
        //   carry the same instant as "Auxerre"), "Stade de
        //   Reims" (vs Saint-Étienne, 2026-11-21T19:00Z;
        //   "stade rennais" is a different club and a
        //   different stem — the exact-stem alias cannot
        //   reach it).
        // - ESPN's "SpVgg Greuther Fürth" (vs Hannover 96,
        //   2026-11-21).
        // - FotMob/LiveScore's bare "Elversberg" (vs
        //   Freiburg, 2026-11-21): the playlist and ESPN bind
        //   the fixture under "sv elversberg" ("SV 07
        //   Elversberg" / "SV Elversberg"), so the bare form
        //   maps UP to the binding key.
        // - FotMob's Danish "FC København" (women's fixture
        //   vs ASA Aarhus, 2026-11-21; LiveScore carries it
        //   as "FC Copenhagen") — the age-tagged U17 stem is
        //   carried separately and lands on "copenhagen u17"
        //   exactly as before.
        // - LiveScore's "Ulsan Hyundai" (vs Incheon United,
        //   2026-11-21): the club's current name, and
        //   FotMob's form, is "Ulsan HD".
        // - Flashscore's "Sheffield Wed" (vs Barnsley,
        //   2026-11-21; "Sheffield United" is a different
        //   stem and untouched).
        // - LiveScore's "MK Dons" (vs Mansfield Town,
        //   2026-11-21; "Milton Keynes Irish" is a distinct
        //   club and a different stem).
        "jeonbuk": "jeonbuk hyundai motors",
        "daejeon citizen": "daejeon hana citizen",
        "nagoya grampus eight": "nagoya grampus",
        "tsv eintracht braunschweig": "eintracht braunschweig",
        "nuremberg": "nurnberg",
        "bodoe glimt": "bodo glimt",
        "aj auxerre": "auxerre",
        "spvgg greuther furth": "greuther furth",
        "stade reims": "reims",
        "elversberg": "sv elversberg",
        "kobenhavn": "copenhagen",
        "ulsan hyundai": "ulsan hd",
        "sheffield wed": "sheffield wednesday",
        "mk dons": "milton keynes dons",
        // FIX-127E (2026-11-20) — the residual Finding-1-class
        // group FIX-127D §8 left behind, plus the two Deportivo
        // feed-side splits §8 recorded for disposition. Each
        // entry measured same-fixture (same pairing + same
        // kickoff instant) in the corpus, each stem produced by
        // one club only:
        // - "ad san carlos" → "deportiva san carlos" and
        //   "escorpiones belen" → "escorpiones": the playlist's
        //   "Escorpiones Belen vs AD San Carlos" (2 listings,
        //   2026-11-21 09:00 ICT = 02:00Z) is FotMob's Primera
        //   División Apertura fixture (league 938190, match
        //   5961131) and LiveScore's "Escorpiones vs Deportiva
        //   San Carlos" at the identical instant (Esd
        //   20261121020000). BOTH sides carry an alias: with
        //   only the San Carlos side mapped, the pair key still
        //   strands on "escorpiones belen" (measured — the
        //   group stayed unbound); Belén is the club's locality
        //   qualifier, written only by the playlist.
        // - "deportivo" → "deportivo a coruna" and "alaves" →
        //   "deportivo alaves": ESPN writes BOTH sides of the
        //   fixture short — bare "Deportivo" (team id 90) and
        //   bare "Alavés" (team id 96), each the corpus's ONLY
        //   bare producer of its stem — a single event at
        //   2026-11-21T13:00Z, the identical pairing and
        //   instant FotMob and LiveScore carry as "Deportivo
        //   Alavés vs Deportivo A Coruña". Every other
        //   Deportivo club in the corpus carries its
        //   distinguishing token (Cali, Morón, Cuenca, Táchira,
        //   Lara, Armenio, Mixco, Malacateco), so the exact
        //   stems converge on this one fixture; both sides
        //   carry an alias because the pair key converges only
        //   when both do (the san carlos shape, above).
        // - "deportivo la coruna" → "deportivo a coruna":
        //   LiveScore's women's "Deportivo La Coruna W" (Liga F
        //   vs Levante Badalona, Esd 20261121110000) is
        //   FotMob's "Deportivo de A Coruña (W)" at the
        //   identical instant 2026-11-21T11:00Z; the Spanish
        //   spelling is the stem's only corpus producer.
        "ad san carlos": "deportiva san carlos",
        "escorpiones belen": "escorpiones",
        "deportivo": "deportivo a coruna",
        "alaves": "deportivo alaves",
        "deportivo la coruna": "deportivo a coruna",
        // REVIEW-127D-LOOP1 Finding 1 + Finding 2 (2026-11-20,
        // FIX-127F) — caught by the chain-4 sweep's
        // instant-proximity net (names ignored), the detector
        // the name-similarity nets structurally cannot replace:
        // - "tuong" → "paredes": the playlist's "Porto vs
        //   Tường" (3 listings, Cola TV) is the Taça de
        //   Portugal fixture vs Paredes at the identical
        //   kickoff instant (2026-11-21 03:45 ICT =
        //   2026-11-20T20:45Z) whose states the pool carries
        //   as "paredes vs porto" (FotMob match 6506251 +
        //   Flashscore). "Tường" is Vietnamese for "wall" and
        //   "Paredes" is Portuguese for "walls" — a translated
        //   club name, the national-team alias shape applied
        //   to a club. Census: the source stem's only corpus
        //   producer is the Cola TV spelling; the target's
        //   only producer is USC Paredes.
        // - "cercle brugge ksv" → "cercle brugge": the
        //   playlist's two spellings of the Westerlo fixture
        //   (identical kickoff 2026-11-21 02:45 ICT) rendered
        //   as two cards. Both groups bind (the KSV group to
        //   Flashscore's "Cercle Brugge KSV", the short group
        //   to FotMob's "Cercle Brugge"), so this closes the
        //   DB-04 duplicate shape, not a bind failure; each
        //   stem is produced by the one club's spellings only.
        "tuong": "paredes",
        "cercle brugge ksv": "cercle brugge",
        // REVIEW-127F-LOOP3 Findings F1–F7 (2026-11-20,
        // FIX-127G) — the rebuilt corpus (the playlist
        // rotated 457 → 474 channels between the chain-5
        // loop-1/2 fetch and loop 3's) carried a
        // Nov-21-evening / Nov-22 fixture block whose
        // spellings stranded seven more groups of the
        // DB-08 class. Each entry measured same-fixture
        // (same opponent, identical kickoff instant, team
        // ids) in the corpus, each stem produced by one
        // club only:
        // - "fcv farul constanta" → "farul constanta" and
        //   "u cluj" → "universitatea cluj": the Farul vs
        //   U Cluj fixture (Superliga, 2026-11-20T18:30Z,
        //   live 1–1 at fetch) is filed by FotMob and
        //   LiveScore under the FCV prefix (FotMob ids
        //   210132 / 89022) and by Flashscore with the
        //   away side as "U. Cluj", while the playlist
        //   and Flashscore's home side write the full
        //   names — the pool held the fixture under two
        //   keys, neither of them the playlist's, so the
        //   card rendered with no state and no home crest
        //   (the learned registry held Farul under the
        //   FCV stem). CFR Cluj and Viitorul Cluj are
        //   different stems and untouched.
        // - "daejeon" → "daejeon hana citizen": the
        //   playlist's bare "Daejeon" (vs Gangwon,
        //   2026-11-21T07:30Z) beside its own and the
        //   feeds' full-name filings (FotMob id 133900);
        //   a bound sibling group already carried the
        //   fixture — the duplicate-card shape. The
        //   volleyball namesake keys "daejeon jkj" and
        //   is untouched.
        // - "okayama" → "fagiano okayama": the playlist's
        //   bare "Okayama" (vs Gamba Osaka,
        //   2026-11-21T07:00Z; FotMob id 164739) beside
        //   its own full-name listings; the volleyball
        //   Seagulls keep their own stem.
        // - "baltika kaliningrad" → "baltika": the
        //   playlist's city-qualified spelling (vs
        //   Orenburg, 2026-11-21T10:00Z) beside FotMob's
        //   bare "Baltika" (id 49694).
        // - "losc lille" → "lille": the playlist's LOSC
        //   spelling (vs Lyon, 2026-11-21T19:45Z) beside
        //   every feed's bare "Lille".
        // - "rc celta" → "celta vigo": the playlist's
        //   "RC Celta" (vs Real Madrid,
        //   2026-11-21T20:00Z) beside every feed's
        //   "Celta Vigo".
        // - "atletico mineiro" → "atletico": the feeds
        //   file the Copa Sudamericana fixture (vs Boca
        //   Juniors, 2026-11-21T22:30Z; FotMob id 10272)
        //   as "Atlético" / "Atlético-MG" — the MG state
        //   strip lands both on the bare stem. Atlético
        //   Madrid never keys bare "atletico" in the
        //   corpus (always "atletico madrid") and every
        //   other Atlético keeps its distinguishing
        //   token — the "deportivo" bare-stem class,
        //   census-proven on both stems.
        "fcv farul constanta": "farul constanta",
        "u cluj": "universitatea cluj",
        "daejeon": "daejeon hana citizen",
        "okayama": "fagiano okayama",
        "baltika kaliningrad": "baltika",
        "losc lille": "lille",
        "rc celta": "celta vigo",
        "atletico mineiro": "atletico",
        // FIX-129 (2026-11-20, DB-09 / FL-336) — the owner's
        // 1.28-test screenshots showed Troyes TWICE: the bound
        // Ligue 1 board "Troyes 2–1 Le Havre" and an unbound
        // featured card "Troyes vs Havre AC" (league KHÁC, "VS",
        // placeholder crest). A listing titled "Havre AC"
        // canonicalises to the bare stem "havre" — "ac" is a
        // filler token — while every feed and every other
        // listing lands on "le havre", so the group split and
        // neither state nor crest could bind to the twin. The
        // same detector pass (name sweep + kickoff-instant net
        // over the frozen corpus and the fresh playlist of
        // 2026-11-20 ~21:40Z) measured eleven more football
        // splits of the same class in the fresh playlist; each
        // entry below is measured same-fixture (same opponent,
        // identical kickoff instant) in that playlist, and the
        // one-club producer census over the frozen corpus, its
        // feeds and both fresh playlist files shows each source
        // stem produced by exactly one club:
        // - "havre" → "le havre" — the "Havre AC" / bare
        //   "Havre" forms of Le Havre AC (the club's own full
        //   name, carried by the feeds as "Le Havre AC"); the
        //   stem's only measured producer is the owner's
        //   device playlist (the title had rotated out of both
        //   fresh files by fetch time — the screenshot is the
        //   producer evidence).
        // - "dep independiente" → "independiente medellin" and
        //   "ind santa fe" → "santa fe" — the fresh playlist's
        //   "Dep.Independiente vs Ind. Santa Fe" (04:30 21/11)
        //   beside its own full-name listings of the same
        //   fixture; BOTH sides carry an alias (the san carlos
        //   shape — the pair key converges only when both do).
        // - "atl bucaramanga" → "bucaramanga" — "Atl.
        //   Bucaramanga vs America de Cali" (06:35 21/11)
        //   beside the full-name listings; the existing
        //   "atletico bucaramanga" entry covers the unabbreviated
        //   spelling only.
        // - "atl san luis" → "atletico san luis" — "Puebla Vs
        //   Atl San Luis" (08:00 21/11) beside the full form.
        // - "dep la coruna" → "deportivo a coruna" — "Alaves Vs
        //   Dep La Coruna" (20:00 21/11); the "alaves" side
        //   already converges (FIX-127E).
        // - "leeds" → "leeds united", "tottenham" →
        //   "tottenham hotspur", "ipswich" → "ipswich town" —
        //   bare short forms in the fresh playlist's 22:00
        //   21/11 listings ("Chelsea vs Leeds", "Tottenham Vs
        //   Ipswich Town", "Tottenham vs Ipswich") beside the
        //   full forms every feed writes.
        // - "psg" → "paris saint germain" — "Ogc Nice Vs Psg"
        //   (23:15 21/11) beside "OGC Nice vs Paris Saint
        //   Germain".
        // - "newcastle" → "newcastle united" — "Newcastle vs
        //   Arsenal" (00:30 22/11) beside the full form;
        //   "Newcastle Jets" is a different stem and untouched.
        // - "olympique lyon" → "lyon" — "LOSC Lille vs
        //   Olympique Lyon" (02:45 22/11) beside the same
        //   fixture's "… vs Lyon" listings and every feed's
        //   bare "Lyon".
        "havre": "le havre",
        "dep independiente": "independiente medellin",
        "ind santa fe": "santa fe",
        "atl bucaramanga": "bucaramanga",
        "atl san luis": "atletico san luis",
        "dep la coruna": "deportivo a coruna",
        "leeds": "leeds united",
        "tottenham": "tottenham hotspur",
        "ipswich": "ipswich town",
        "psg": "paris saint germain",
        "newcastle": "newcastle united",
        "olympique lyon": "lyon",
        // FIX-130 (2026-11-21, DB-12) — legal-name forms that
        // canonicalise AWAY from the short canon every source
        // uses, so a legal-name spelling could never bind.
        // Proven in the PLAN-130 survey (§5) with the frozen
        // corpus127 harness: today's canon outputs are
        // "rc strasbourg alsace", "stade brestois" and
        // "real betis balompie" beside the feeds' "strasbourg",
        // "brest" and "real betis". Notes on shape:
        // - The accented "Balompié" folds to "balompie" inside
        //   tn_norm before the lookup, so one entry covers both
        //   spellings.
        // - "Stade Brestois 29" reaches the table as
        //   "stade brestois" (the 29 drops earlier in the
        //   pipeline), so it needs no entry of its own.
        // - Near-neighbours stay distinct: Dynamo Brest /
        //   Dinamo Brest are different stems, Real Sociedad /
        //   Real Madrid untouched, "stade brestois b" keeps its
        //   reserve identity.
        // - The last two are the survey's flagged neighbours of
        //   the identical Stade/RC shape, folded in by the
        //   leader's D-4 ruling: ESPN's frozen fra.1 payload
        //   attests "Stade Rennais" while the other sources use
        //   "Rennes"; "rc lens" diverges from "lens" the same
        //   way "rc strasbourg" did from "strasbourg".
        "rc strasbourg alsace": "strasbourg",
        "rc strasbourg": "strasbourg",
        "racing strasbourg": "strasbourg",
        "stade brestois": "brest",
        "stade brest": "brest",
        "real betis balompie": "real betis",
        "stade rennais": "rennes",
        "rc lens": "lens",
        // FIX-MU-5 (item F, 2026-11-22) — the tvOS 1.7.3 alias
        // set (REGRESSION-20261122-ANALYSIS.md), diffed against
        // this table: all 20 were missing here. Same clubs,
        // same whole-name shape; the corpus127 harness verdict
        // for this exact table state is in
        // theme-mu/FIX-MU-5-REPORT.md.
        "ai cap": "egypt",
        "den haag": "ado den haag",
        "remo belem": "remo",
        "atletico paranaense": "athletico",
        "athletico paranaense": "athletico",
        "celta vigo b": "celta fortuna",
        "rc celta fortuna": "celta fortuna",
        "erzurum bb": "erzurumspor",
        "sassuolo calcio": "sassuolo",
        "u sassuolo calcio": "sassuolo",
        "hamburger sv": "hamburger",
        "hamburg sv": "hamburger",
        "juventus f c": "juventus",
        "venezia f c": "venezia",
        "sg dynamo dresden": "dynamo dresden",
        "kamatamare": "kamatamare sanuki",
        "union saint gilloise": "union st gilloise",
        "ksc": "karlsruher",
        "sarpsborg ff": "sarpsborg",
        "man united": "manchester united",
    ]

    /// Trailing city qualifiers (step 7 — measured 2026-11-20,
    /// see the pipeline note above for why the set is this small).
    private static let cityQualifiers: Set<String> = [
        "jeddah", "samara",
    ]

    /// Tokens that carry no club identity on their own — the
    /// filler set, the women's markers, and the bare articles.
    /// Used ONLY by the step-7 guard (REVIEW-127B-LOOP2 Angle 5):
    /// a qualifier drop may not leave a stem made solely of
    /// these. Without the guard, "Al-Jeddah" (article + the
    /// qualifier itself) dropped its discriminating token and
    /// collapsed to the bare article "al".
    private static let genericStemTokens: Set<String> =
        fillerTokens.union(womenMarkers).union(["al", "el", "the"])

    /// Brazilian federative-unit (state) codes — the measured set
    /// FixtureGrouping carried (2026-11-19): Brazilian listings
    /// decorate club names with the club's state ("São Paulo _SP")
    /// while every other source writes the bare club name.
    private static let stateSuffixTokens: Set<String> = [
        "ac", "al", "am", "ap", "ba", "ce", "df", "es", "go",
        "ma", "mg", "ms", "mt", "pa", "pb", "pe", "pi", "pr",
        "rj", "rn", "ro", "rr", "rs", "sc", "se", "sp", "to",
    ]

    // MARK: - Step 1: raw normalization

    /// Lowercase, special letters folded, diacritics stripped
    /// (đ→d), only [a-z0-9 ] kept, spaces collapsed. Crests.norm
    /// does the folding/filtering (it is the crest map's key
    /// algorithm); this step only pre-folds the letters that
    /// algorithm cannot decompose, so the two never disagree on
    /// the names both already handled.
    static func norm(_ s: String) -> String {
        var t = s.lowercased()
        for (from, to) in specialLetters {
            t = t.replacingOccurrences(of: from, with: to)
        }
        return Crests.norm(t)
    }

    // MARK: - The pipeline (steps 2–8)

    /// A glued age token: "u" + 1–2 digits ("u7"…"u23"). The
    /// digit guard keeps real names safe ("u cluj" is a club,
    /// not an age marker — and its split form is only taken when
    /// a digit token actually follows).
    private static func isAgeToken(_ t: String) -> Bool {
        (t.count == 2 || t.count == 3) && t.hasPrefix("u")
            && t.dropFirst().allSatisfy({ $0.isNumber })
    }

    private static func pipeline(_ name: String, stripWomen: Bool) -> String {
        var tokens = norm(name).split(separator: " ").map(String.init)

        // Step 2: the leading Vietnamese club decoration.
        if tokens.count >= 5,
           Array(tokens[0..<5]) == ["cau", "lac", "bo", "bong", "da"] {
            tokens.removeFirst(5)
        } else if tokens.count >= 3,
                  Array(tokens[0..<3]) == ["cau", "lac", "bo"] {
            tokens.removeFirst(3)
        }

        // Step 3: extract the age marker (first one wins); it is
        // re-attached after alias resolution, as the trailing tag.
        var age: String? = nil
        var stem: [String] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if isAgeToken(t) {
                if age == nil { age = t }
                i += 1
                continue
            }
            if t == "u", i + 1 < tokens.count,
               tokens[i + 1].count <= 2,
               tokens[i + 1].allSatisfy({ $0.isNumber }) {
                if age == nil { age = "u" + tokens[i + 1] }
                i += 2
                continue
            }
            stem.append(t)
            i += 1
        }

        // Steps 4–5: filler drop, numeric drop, token aliases.
        stem = stem
            .filter { !fillerTokens.contains($0) && !$0.allSatisfy({ $0.isNumber }) }
            .map { tokenAliases[$0] ?? $0 }

        // Step 6: women's markers off the stem edges (canonical
        // key only — the grouping key keeps them).
        if stripWomen {
            while let first = stem.first, womenMarkers.contains(first) {
                stem.removeFirst()
            }
            while let last = stem.last, womenMarkers.contains(last) {
                stem.removeLast()
            }
        }

        // Step 7: trailing city qualifiers — dropped only while
        // the surviving stem still contains at least one
        // non-generic token (a token that identifies the club).
        // The count guard alone let "al jeddah" drop to the bare
        // article "al": the qualifier was the discriminating
        // token and the article is not an identity.
        while stem.count >= 2, let last = stem.last,
              cityQualifiers.contains(last),
              stem.dropLast().contains(where: {
                  !genericStemTokens.contains($0)
              }) {
            stem.removeLast()
        }

        // Step 8: whole-name aliases → state suffix → aliases.
        var joined = stem.joined(separator: " ")
        if let alias = wholeNameAliases[joined] { joined = alias }
        joined = droppingStateSuffix(joined)
        if let alias = wholeNameAliases[joined] { joined = alias }

        if let age {
            joined = joined.isEmpty ? age : joined + " " + age
        }
        return joined
    }

    /// The fixture-identity key (FixtureGrouping): the full
    /// pipeline with women's markers KEPT — a women's fixture is
    /// its own fixture, and LeagueClassifier's women/youth guard
    /// reads the markers from this key.
    static func groupKey(forTeam name: String) -> String {
        pipeline(name, stripWomen: false)
    }

    /// The belonging key (MatchMatching + the Crests learned
    /// registry): the full pipeline with women's markers stripped
    /// from the stem edges; markedness itself is carried
    /// separately (`hasWomenMarker`) and the state lookup's
    /// marker discipline reasons about it, exactly as before.
    /// Idempotent over `groupKey` output, so a caller holding an
    /// already-grouped name lands on the same key as a caller
    /// holding the raw name.
    static func canonicalKey(forTeam name: String) -> String {
        pipeline(name, stripWomen: true)
    }

    /// The pair key for two raw team names (source feeds, Nuvio
    /// metas), or nil when either side canonicalises away.
    static func pairKey(team1: String, team2: String) -> String? {
        let a = canonicalKey(forTeam: team1)
        let b = canonicalKey(forTeam: team2)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        return [a, b].sorted().joined(separator: " vs ")
    }

    /// True when a raw team name carries a women's marker token,
    /// in any position.
    static func hasWomenMarker(_ name: String) -> Bool {
        norm(name)
            .split(separator: " ")
            .contains { womenMarkers.contains(String($0)) }
    }

    /// A canonical/group key with its trailing age tag removed —
    /// the crest layer's bridge from a youth spelling to the
    /// senior badge the static map carries.
    static func strippingAgeTag(_ key: String) -> String {
        var tokens = key.split(separator: " ").map(String.init)
        if let last = tokens.last, isAgeToken(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    /// A normalised name with ONE trailing Brazilian state token
    /// dropped (see stateSuffixTokens). Names of fewer than two
    /// tokens are returned untouched — the strip can never empty
    /// a name. (Moved here from FixtureGrouping, which now
    /// delegates; the crest candidate chain uses it too.)
    static func droppingStateSuffix(_ normalized: String) -> String {
        var tokens = normalized.split(separator: " ").map(String.init)
        if tokens.count >= 2, let last = tokens.last,
           stateSuffixTokens.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }
}
