#!/usr/bin/env python3
"""Low-footprint Scrollmapper reader. Stdlib only."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import textwrap
from datetime import date, datetime
from pathlib import Path
from typing import Any

REF_RE = re.compile(
    r"""
    ^\s*
    (?P<book>.+?)
    \s+
    (?P<chapter>\d+)
    (?:
        \s* : \s* (?P<v1>\d+)
        (?: \s* - \s* (?P<v2>\d+) )?
    )?
    \s*$
    """,
    re.VERBOSE | re.IGNORECASE,
)

ALIASES = {
    "gen": "Genesis",
    "genesis": "Genesis",
    "ex": "Exodus",
    "exo": "Exodus",
    "exod": "Exodus",
    "exodus": "Exodus",
    "lev": "Leviticus",
    "leviticus": "Leviticus",
    "num": "Numbers",
    "numbers": "Numbers",
    "deut": "Deuteronomy",
    "dt": "Deuteronomy",
    "deuteronomy": "Deuteronomy",
    "josh": "Joshua",
    "joshua": "Joshua",
    "judg": "Judges",
    "judges": "Judges",
    "ruth": "Ruth",
    "1sam": "I Samuel",
    "1 samuel": "I Samuel",
    "i samuel": "I Samuel",
    "1 kingdoms": "I Samuel",
    "i kingdoms": "I Samuel",
    "1kgsam": "I Samuel",
    "2sam": "II Samuel",
    "2 samuel": "II Samuel",
    "ii samuel": "II Samuel",
    "2 kingdoms": "II Samuel",
    "ii kingdoms": "II Samuel",
    "1kgs": "I Kings",
    "1 kings": "I Kings",
    "i kings": "I Kings",
    "3 kingdoms": "I Kings",
    "iii kingdoms": "I Kings",
    "2kgs": "II Kings",
    "2 kings": "II Kings",
    "ii kings": "II Kings",
    "4 kingdoms": "II Kings",
    "iv kingdoms": "II Kings",
    "1chr": "I Chronicles",
    "1 chronicles": "I Chronicles",
    "i chronicles": "I Chronicles",
    "1 paraleipomenon": "I Chronicles",
    "2chr": "II Chronicles",
    "2 chronicles": "II Chronicles",
    "ii chronicles": "II Chronicles",
    "ezra": "Ezra",
    "2 esdras": "Ezra",
    "ii esdras": "II Esdras",
    "1 esdras": "I Esdras",
    "i esdras": "I Esdras",
    "neh": "Nehemiah",
    "nehemiah": "Nehemiah",
    "esth": "Esther",
    "esther": "Esther",
    "add esth": "Additions to Esther",
    "additions to esther": "Additions to Esther",
    "job": "Job",
    "ps": "Psalms",
    "psa": "Psalms",
    "psalm": "Psalms",
    "psalms": "Psalms",
    "prov": "Proverbs",
    "proverbs": "Proverbs",
    "eccl": "Ecclesiastes",
    "ecc": "Ecclesiastes",
    "ecclesiastes": "Ecclesiastes",
    "song": "Song of Solomon",
    "sos": "Song of Solomon",
    "canticle": "Song of Solomon",
    "song of solomon": "Song of Solomon",
    "song of songs": "Song of Solomon",
    "isa": "Isaiah",
    "isaiah": "Isaiah",
    "jer": "Jeremiah",
    "jeremiah": "Jeremiah",
    "lam": "Lamentations",
    "lamentations": "Lamentations",
    "ezek": "Ezekiel",
    "ezekiel": "Ezekiel",
    "dan": "Daniel",
    "daniel": "Daniel",
    "hos": "Hosea",
    "hosea": "Hosea",
    "joel": "Joel",
    "amos": "Amos",
    "obad": "Obadiah",
    "obadiah": "Obadiah",
    "jonah": "Jonah",
    "mic": "Micah",
    "micah": "Micah",
    "nah": "Nahum",
    "nahum": "Nahum",
    "hab": "Habakkuk",
    "habakkuk": "Habakkuk",
    "zeph": "Zephaniah",
    "zephaniah": "Zephaniah",
    "hag": "Haggai",
    "haggai": "Haggai",
    "zech": "Zechariah",
    "zechariah": "Zechariah",
    "mal": "Malachi",
    "malachi": "Malachi",
    "tobit": "Tobit",
    "tob": "Tobit",
    "judith": "Judith",
    "jdt": "Judith",
    "wis": "Wisdom",
    "wisdom": "Wisdom",
    "wisdom of solomon": "Wisdom",
    "sir": "Sirach",
    "sirach": "Sirach",
    "ecclesiasticus": "Sirach",
    "bar": "Baruch",
    "baruch": "Baruch",
    "ep jer": "Epistle of Jeremiah",
    "letter of jeremiah": "Epistle of Jeremiah",
    "epistle of jeremiah": "Epistle of Jeremiah",
    "azariah": "Prayer of Azariah",
    "prayer of azariah": "Prayer of Azariah",
    "song of the three": "Prayer of Azariah",
    "susanna": "Susanna",
    "bel": "Bel and the Dragon",
    "bel and the dragon": "Bel and the Dragon",
    "manasseh": "Prayer of Manasses",
    "prayer of manasseh": "Prayer of Manasses",
    "prayer of manasses": "Prayer of Manasses",
    "1mac": "I Maccabees",
    "1 macc": "I Maccabees",
    "1 maccabees": "I Maccabees",
    "i maccabees": "I Maccabees",
    "2mac": "II Maccabees",
    "2 macc": "II Maccabees",
    "2 maccabees": "II Maccabees",
    "ii maccabees": "II Maccabees",
    "3mac": "III Maccabees",
    "3 macc": "III Maccabees",
    "3 maccabees": "III Maccabees",
    "iii maccabees": "III Maccabees",
    "mt": "Matthew",
    "matt": "Matthew",
    "matthew": "Matthew",
    "mk": "Mark",
    "mark": "Mark",
    "lk": "Luke",
    "luke": "Luke",
    "jn": "John",
    "joh": "John",
    "john": "John",
    "acts": "Acts",
    "rom": "Romans",
    "romans": "Romans",
    "1cor": "I Corinthians",
    "1 cor": "I Corinthians",
    "1 corinthians": "I Corinthians",
    "i corinthians": "I Corinthians",
    "2cor": "II Corinthians",
    "2 cor": "II Corinthians",
    "2 corinthians": "II Corinthians",
    "ii corinthians": "II Corinthians",
    "gal": "Galatians",
    "galatians": "Galatians",
    "eph": "Ephesians",
    "ephesians": "Ephesians",
    "phil": "Philippians",
    "philippians": "Philippians",
    "col": "Colossians",
    "colossians": "Colossians",
    "1th": "I Thessalonians",
    "1 thess": "I Thessalonians",
    "1 thessalonians": "I Thessalonians",
    "i thessalonians": "I Thessalonians",
    "2th": "II Thessalonians",
    "2 thess": "II Thessalonians",
    "2 thessalonians": "II Thessalonians",
    "ii thessalonians": "II Thessalonians",
    "1tim": "I Timothy",
    "1 timothy": "I Timothy",
    "i timothy": "I Timothy",
    "2tim": "II Timothy",
    "2 timothy": "II Timothy",
    "ii timothy": "II Timothy",
    "tit": "Titus",
    "titus": "Titus",
    "phlm": "Philemon",
    "philemon": "Philemon",
    "heb": "Hebrews",
    "hebrews": "Hebrews",
    "jas": "James",
    "james": "James",
    "1pet": "I Peter",
    "1 peter": "I Peter",
    "i peter": "I Peter",
    "2pet": "II Peter",
    "2 peter": "II Peter",
    "ii peter": "II Peter",
    "1jn": "I John",
    "1 john": "I John",
    "i john": "I John",
    "2jn": "II John",
    "2 john": "II John",
    "ii john": "II John",
    "3jn": "III John",
    "3 john": "III John",
    "iii john": "III John",
    "jude": "Jude",
    "rev": "Revelation of John",
    "revelation": "Revelation of John",
    "revelation of john": "Revelation of John",
    "apocalypse": "Revelation of John",
}


def eprint(*args: Any) -> None:
    print(*args, file=sys.stderr)


def data_root() -> Path:
    raw = os.environ.get("SCROLLMAPPER_DATA")
    if raw:
        return Path(raw)
    return Path(__file__).resolve().parent.parent / "share" / "scrollmapper"


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


class Library:
    def __init__(self, root: Path, translation: str, canon: str) -> None:
        self.root = root
        self.translation = translation
        self.canon_name = canon
        self.canons = load_json(root / "canons.json")
        text_path = root / "texts" / f"{translation}.json"
        if not text_path.is_file():
            available = sorted(p.stem for p in (root / "texts").glob("*.json"))
            raise FileNotFoundError(
                f"translation {translation!r} not installed. available: {', '.join(available) or '(none)'}"
            )
        payload = load_json(text_path)
        self.translation_label = payload.get("translation", translation)
        self.books: dict[str, dict[int, dict[int, str]]] = {}
        self.book_order: list[str] = []
        for book in payload.get("books", []):
            name = book["name"]
            chapters: dict[int, dict[int, str]] = {}
            for ch in book.get("chapters", []):
                verses = {int(v["verse"]): str(v["text"]).strip() for v in ch.get("verses", [])}
                chapters[int(ch["chapter"])] = verses
            self.books[name] = chapters
            self.book_order.append(name)
        self.canon_books = self._resolve_canon(canon)

    def _resolve_canon(self, canon: str) -> list[str]:
        spec = self.canons.get(canon)
        if spec is None:
            raise SystemExit(f"unknown canon {canon!r}. choose from: {', '.join(self.canons)}")
        wanted = spec.get("books") or self.book_order
        present = []
        seen = set()
        by_lower = {n.lower(): n for n in self.books}
        for name in wanted:
            real = self.books.get(name) and name or by_lower.get(name.lower())
            if real and real not in seen:
                present.append(real)
                seen.add(real)
        return present

    def resolve_book(self, raw: str) -> str:
        key = re.sub(r"\s+", " ", raw.strip().lower())
        key = key.replace("1st ", "1 ").replace("2nd ", "2 ").replace("3rd ", "3 ")
        key = key.replace("first ", "1 ").replace("second ", "2 ").replace("third ", "3 ")
        if key in ALIASES:
            target = ALIASES[key]
            if target in self.books:
                return target
        by_lower = {n.lower(): n for n in self.books}
        if key in by_lower:
            return by_lower[key]
        # prefix match among canon books first
        pool = self.canon_books or list(self.books)
        hits = [n for n in pool if n.lower().startswith(key)]
        if len(hits) == 1:
            return hits[0]
        hits = [n for n in self.books if n.lower().startswith(key)]
        if len(hits) == 1:
            return hits[0]
        raise SystemExit(f"unknown book {raw!r}")

    def parse_ref(self, raw: str) -> tuple[str, int, int | None, int | None]:
        m = REF_RE.match(raw)
        if not m:
            raise SystemExit(f"could not parse reference {raw!r} (try 'John 1:1' or 'Psalms 50')")
        book = self.resolve_book(m.group("book"))
        chapter = int(m.group("chapter"))
        v1 = int(m.group("v1")) if m.group("v1") else None
        v2 = int(m.group("v2")) if m.group("v2") else None
        return book, chapter, v1, v2

    def verses(
        self, book: str, chapter: int, v1: int | None = None, v2: int | None = None
    ) -> list[tuple[int, str]]:
        chapters = self.books.get(book)
        if not chapters or chapter not in chapters:
            raise SystemExit(f"{book} {chapter} is not in this translation")
        items = sorted(chapters[chapter].items())
        if v1 is None:
            return items
        end = v2 or v1
        if end < v1:
            v1, end = end, v1
        sliced = [(n, t) for n, t in items if v1 <= n <= end]
        if not sliced:
            raise SystemExit(f"{book} {chapter}:{v1}" + (f"-{end}" if end != v1 else "") + " not found")
        return sliced

    def iter_canon_verses(self):
        for book in self.canon_books:
            for chapter, verses in sorted(self.books[book].items()):
                for num, text in sorted(verses.items()):
                    yield book, chapter, num, text


def color_enabled() -> bool:
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("SCROLLMAPPER_COLOR", "").lower() in {"0", "false", "no"}:
        return False
    return sys.stdout.isatty()


def paint(text: str, code: str) -> str:
    if not color_enabled():
        return text
    return f"\033[{code}m{text}\033[0m"


def wrap_width(requested: int) -> int:
    cols = shutil.get_terminal_size((80, 24)).columns
    if requested > 0:
        return min(requested, cols) if sys.stdout.isatty() else requested
    return max(48, cols - 2) if sys.stdout.isatty() else 72


def render_block(title: str, body_lines: list[str], width: int, subtitle: str = "") -> str:
    inner = max(width, 24)
    bar = "─" * (inner - 2)
    out = [paint(f"┌{bar}┐", "2")]
    head = title
    if subtitle:
        head = f"{title}  ·  {subtitle}"
    pad = max(0, inner - 4 - len(head))
    out.append(paint("│ ", "2") + paint(head, "1") + " " * pad + paint(" │", "2"))
    out.append(paint(f"├{bar}┤", "2"))
    for line in body_lines:
        wrapped = textwrap.wrap(line, width=inner - 4) or [""]
        for w in wrapped:
            out.append(paint("│ ", "2") + w.ljust(inner - 4) + paint(" │", "2"))
    out.append(paint(f"└{bar}┘", "2"))
    return "\n".join(out)


def format_passage(
    lib: Library, book: str, chapter: int, verses: list[tuple[int, str]], width: int
) -> str:
    lines: list[str] = []
    for num, text in verses:
        lines.append(f"{num}  {text}")
    return render_block(
        f"{book} {chapter}",
        lines,
        width,
        subtitle=f"{lib.translation} · {lib.canon_name}",
    )


def cmd_books(lib: Library, width: int) -> int:
    missing_note = []
    spec = lib.canons[lib.canon_name]
    wanted = spec.get("books") or []
    have = set(lib.books)
    if wanted:
        missing = [b for b in wanted if b not in have]
        if missing:
            missing_note = ["", "absent from this translation: " + ", ".join(missing)]
    lines = [f"{i:>3}  {name}" for i, name in enumerate(lib.canon_books, 1)]
    print(
        render_block(
            spec.get("label", lib.canon_name),
            lines + missing_note,
            width,
            subtitle=lib.translation_label,
        )
    )
    return 0


def cmd_read(lib: Library, ref: str, width: int) -> int:
    book, chapter, v1, v2 = lib.parse_ref(ref)
    verses = lib.verses(book, chapter, v1, v2)
    print(format_passage(lib, book, chapter, verses, width))
    return 0


def cmd_search(lib: Library, query: str, width: int, limit: int) -> int:
    q = query.casefold()
    hits: list[str] = []
    for book, chapter, num, text in lib.iter_canon_verses():
        if q in text.casefold():
            hits.append(f"{book} {chapter}:{num}  {text}")
            if len(hits) >= limit:
                break
    if not hits:
        print(render_block("search", [f"no matches for {query!r} in {lib.canon_name} canon"], width))
        return 1
    print(render_block(f"search “{query}”", hits, width, subtitle=f"{len(hits)} shown"))
    return 0


def pick_from_list(rows: list[tuple[str, int, int, str]], when: date, salt: str) -> tuple[str, int, int, str]:
    if not rows:
        raise SystemExit("verse pool is empty")
    seed = f"{when.isoformat()}|{salt}".encode()
    digest = hashlib.sha256(seed).digest()
    idx = int.from_bytes(digest[:8], "big") % len(rows)
    return rows[idx]


def load_pool(root: Path) -> list[tuple[str, int, int, str]]:
    path = root / "boot-pool.tsv"
    if not path.is_file():
        raise SystemExit(f"pool not found: {path}")
    rows: list[tuple[str, int, int, str]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.startswith("#"):
            continue
        parts = raw.split("\t", 3)
        if len(parts) != 4:
            continue
        book, chapter, verse, text = parts
        try:
            rows.append((book, int(chapter), int(verse), text))
        except ValueError:
            continue
    return rows


def cmd_daily(
    when: date,
    width: int,
    plain: bool,
    *,
    rows: list[tuple[str, int, int, str]],
    salt: str,
    subtitle: str,
) -> int:
    book, chapter, num, text = pick_from_list(rows, when, salt)
    if plain:
        print(f"{book} {chapter}:{num}")
        print(text)
        return 0
    print(
        render_block(
            f"{book} {chapter}:{num}",
            [text],
            width,
            subtitle=subtitle,
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="scrollmapper",
        description="Low-footprint reader for Scrollmapper Bible databases. Orthodox canon is the default.",
    )
    p.add_argument(
        "--data",
        default=os.environ.get("SCROLLMAPPER_DATA"),
        help="data directory (or set SCROLLMAPPER_DATA)",
    )
    p.add_argument(
        "--translation",
        default=os.environ.get("SCROLLMAPPER_TRANSLATION", "KJVA"),
        help="installed translation id (default: KJVA)",
    )
    p.add_argument(
        "--canon",
        default=os.environ.get("SCROLLMAPPER_CANON", "orthodox"),
        choices=("orthodox", "catholic", "protestant", "full"),
        help="book filter (default: orthodox)",
    )
    p.add_argument(
        "--wrap",
        type=int,
        default=int(os.environ.get("SCROLLMAPPER_WRAP", "72")),
        help="preferred wrap width",
    )
    sub = p.add_subparsers(dest="cmd")

    sub.add_parser("books", help="list books in the active canon")

    r = sub.add_parser("read", help="print a chapter or verse range")
    r.add_argument("ref", nargs="+", help="e.g. 'John 1:1-5' or 'Psalms 50'")

    v = sub.add_parser("verse", help="alias for read")
    v.add_argument("ref", nargs="+")

    s = sub.add_parser("search", help="case-insensitive substring search")
    s.add_argument("query", nargs="+")
    s.add_argument("--limit", type=int, default=20)

    d = sub.add_parser("daily", help="deterministic verse for a calendar day")
    d.add_argument("--date", dest="on_date", help="YYYY-MM-DD (default: today, local)")
    d.add_argument("--plain", action="store_true", help="no box drawing")
    d.add_argument(
        "--pool",
        action="store_true",
        help="use the curated Orthodox display pool (default for login; no JSON load)",
    )
    d.add_argument(
        "--full",
        action="store_true",
        help="hash over every verse in the active translation+canon",
    )

    sub.add_parser("info", help="show configured translation and canon")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = Path(args.data) if args.data else data_root()
    if not root.is_dir():
        eprint(f"data directory not found: {root}")
        return 2
    width = wrap_width(args.wrap)
    cmd = args.cmd or "daily"

    def load_lib() -> Library:
        try:
            return Library(root, args.translation, args.canon)
        except FileNotFoundError as exc:
            raise SystemExit(str(exc)) from exc

    if cmd == "daily":
        # Every attribute here must be read with getattr. `cmd = args.cmd or
        # "daily"` above routes a BARE invocation into this branch, but argparse
        # only adds subparser-scoped dests when that subparser actually runs —
        # so with no subcommand the Namespace has `cmd=None` and none of
        # on_date/plain/pool/full. Reading them directly raised AttributeError
        # for `scrollmapper` with no args, the `sm` alias, and
        # `nix run path:./modules/scrollmapper` (whose default app passes none).
        on_date = getattr(args, "on_date", None)
        if on_date:
            when = date.fromisoformat(on_date)
        else:
            when = datetime.now().astimezone().date()
        use_full = bool(getattr(args, "full", False))
        use_pool = bool(getattr(args, "pool", False)) or not use_full
        if use_full:
            lib = load_lib()
            rows = list(lib.iter_canon_verses())
            salt = f"{lib.translation}|{lib.canon_name}|full"
            sub = f"daily · {when.isoformat()} · {lib.translation} · {lib.canon_name}"
        else:
            rows = load_pool(root)
            salt = f"{args.translation}|{args.canon}|pool"
            sub = f"daily · {when.isoformat()} · pool · {args.canon}"
        return cmd_daily(
            when,
            width,
            bool(getattr(args, "plain", False)),
            rows=rows,
            salt=salt,
            subtitle=sub,
        )

    lib = load_lib()
    if cmd in {"read", "verse"}:
        return cmd_read(lib, " ".join(args.ref), width)
    if cmd == "books":
        return cmd_books(lib, width)
    if cmd == "search":
        return cmd_search(lib, " ".join(args.query), width, args.limit)
    if cmd == "info":
        print(
            render_block(
                "scrollmapper",
                [
                    f"translation  {lib.translation_label}",
                    f"canon        {lib.canon_name} ({len(lib.canon_books)} books present)",
                    f"source       {root}",
                    "data         Scrollmapper bible_databases (KJVA default)",
                ],
                width,
            )
        )
        return 0
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        sys.exit(0)
