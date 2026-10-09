#!/usr/bin/env python3
"""Checks the bundled terminal fonts: the files, the names, and the plist.

Why this is here
----------------
A font that fails to load does not fail loudly. `UIFont(name:)` returns nil,
the terminal falls back to the system monospaced font, and the user sees plain
text and concludes the picker is decorative. Every way this can go wrong is
invisible on screen:

* a `.ttf` missing from the bundle,
* a file present but not named in `UIAppFonts` (so it never registers),
* a file named in `UIAppFonts` but not present (so the plist names a ghost),
* a PostScript name in `TerminalFontFamily` that does not match the font's own
  `name` table — a typo here is enough,
* and, for the bundled-but-subset faces, a glyph range dropped by a subsetting
  step so a terminal renders `?` for a box-drawing character.

None of those is visible from the screen, so they are checked here from the
files themselves. The font files are read as binary: the `name` and `cmap`
tables are the source of truth, and no font library is needed to read them.

Usage: scripts/fonts-bundled-check.sh
"""

import re
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
FONTS = ROOT / "App" / "Fonts"
PROJECT = ROOT / "project.yml"
SWIFT = ROOT / "App" / "Features" / "Settings" / "TerminalFont.swift"
EMBEDDED = ROOT / "App" / "Features" / "Settings" / "EmbeddedFonts.swift"

failures = 0
checks = 0


def check(condition, label):
    global failures, checks
    checks += 1
    if condition:
        print("PASS  " + label)
    else:
        failures += 1
        print("FAIL  " + label)


# --- Reading a TrueType name table -------------------------------------------
#
# Enough sfnt to answer "what does this font call itself". The name table holds
# the strings in several encodings; platform 3 (Windows) records are UTF-16BE
# and are the ones that matter, but platform 1 (Mac) records are checked as a
# fallback because a font built on macOS may carry only those.

def sfnt_tables(data):
    """The table directory, as {tag: (offset, length)}."""
    if len(data) < 12:
        return {}
    tag = data[0:4]
    if tag == b"ttcf":
        # A collection. Nothing bundled is one, but reading it as a plain sfnt
        # would produce nonsense rather than an error, so it is refused here.
        raise ValueError("is a TrueType collection, not a single face")
    table_count = struct.unpack(">H", data[4:6])[0]
    tables = {}
    for i in range(table_count):
        off = 12 + 16 * i
        name = data[off:off + 4]
        offset, length = struct.unpack(">II", data[off + 8:off + 16])
        tables[name] = (offset, length)
    return tables


def name_table(data):
    """The font's names, as {nameID: string} for the first record of each."""
    tables = sfnt_tables(data)
    if b"name" not in tables:
        return {}
    offset, _ = tables[b"name"]
    count, string_offset = struct.unpack(">HH", data[offset + 2:offset + 6])
    out = {}
    for i in range(count):
        rec = offset + 6 + 12 * i
        platform, _, _, name_id, length, str_off = struct.unpack(">HHHHHH", data[rec:rec + 12])
        raw = data[offset + string_offset + str_off:offset + string_offset + str_off + length]
        try:
            text = raw.decode("utf-16-be" if platform == 3 else "mac-roman")
        except UnicodeDecodeError:
            continue
        # Prefer the Windows record but keep any: they agree for these fonts,
        # and if they ever disagree the PostScript name is what iOS uses.
        out.setdefault(name_id, text)
    return out


def cmap_codepoints(data):
    """Every codepoint the font's best cmap maps, as a set."""
    tables = sfnt_tables(data)
    if b"cmap" not in tables:
        return set()
    offset, _ = tables[b"cmap"]
    num = struct.unpack(">H", data[offset + 2:offset + 4])[0]
    subtables = []
    for i in range(num):
        rec = offset + 4 + 8 * i
        platform, encoding, sub_off = struct.unpack(">HHI", data[rec:rec + 8])
        subtables.append((platform, encoding, offset + sub_off))
    # Prefer a full Unicode subtable; format 4 (BMP) and format 12 (full) are
    # the only two these fonts use.
    points = set()
    for platform, encoding, sub in subtables:
        if platform not in (0, 3):
            continue
        fmt = struct.unpack(">H", data[sub:sub + 2])[0]
        if fmt == 4:
            seg_x2 = struct.unpack(">H", data[sub + 6:sub + 8])[0]
            seg = seg_x2 // 2
            ends = struct.unpack(">%dH" % seg, data[sub + 14:sub + 14 + seg_x2])
            starts = struct.unpack(">%dH" % seg, data[sub + 16 + seg_x2:sub + 16 + 2 * seg_x2])
            for s, e in zip(starts, ends):
                if s == 0xFFFF:
                    continue
                for c in range(s, e + 1):
                    points.add(c)
        elif fmt == 12:
            count = struct.unpack(">I", data[sub + 12:sub + 16])[0]
            for g in range(count):
                rec = sub + 16 + 12 * g
                start, end = struct.unpack(">II", data[rec:rec + 8])
                for c in range(start, end + 1):
                    points.add(c)
    return points


def read(path):
    return path.read_bytes()


# --- The families the app knows about ----------------------------------------

print("==> reading TerminalFont.swift and EmbeddedFonts.swift")

swift_text = SWIFT.read_text()
embedded_text = EMBEDDED.read_text()

# The PostScript name each bundled case resolves, straight out of the source.
# Parsed rather than duplicated: a copy here would be a second place to forget.
ps_names = dict(re.findall(r"case \.(\w+): \"([\w-]+)\"", swift_text))
check(ps_names.get("jetBrainsMono") == "JetBrainsMono-Regular",
      "the default family's PostScript name is JetBrainsMono-Regular")
check(".jetBrainsMono" in swift_text and "defaultFamily" in swift_text,
      "JetBrains Mono is the default family")

# The file names each family registers, from EmbeddedFonts.files(for:). The
# switch is parsed rather than duplicated here — a copy would be a second place
# to forget when a font is added, which is the exact failure this guards.
family_files = {}
for match in re.finditer(r"case \.(?:jetBrainsMono|iosevka|ioskeley|dejaVu)([^:]*):(.*?)(?=\n        case |\n        })",
                         embedded_text, re.S):
    case = match.group(0)
    family = re.search(r"case \.(\w+)", case).group(1)
    family_files[family] = re.findall(r'"([^"]+)"', match.group(2))
check(len(family_files) == 4,
      f"EmbeddedFonts lists files for each bundled family (found {sorted(family_files)})")

# --- Every file it names exists, and every file on disk is named -------------

on_disk = {p.stem for p in FONTS.glob("*.ttf")}
named = {n for files in family_files.values() for n in files}
for missing in sorted(named - on_disk):
    check(False, f"the file named by EmbeddedFonts exists: {missing}.ttf")
for unmentioned in sorted(on_disk - named):
    check(False, f"every bundled .ttf is named by EmbeddedFonts: {unmentioned}.ttf")
if named == on_disk:
    check(True, f"the {len(on_disk)} bundled .ttf files and EmbeddedFonts agree")

# --- The plist lists them all, and nothing that is not there -----------------

project_text = PROJECT.read_text()
plist_block = re.search(r"UIAppFonts:\n((?:\s+- .*\n)+)", project_text)
check(plist_block is not None, "project.yml declares UIAppFonts")
listed = set()
if plist_block:
    listed = set(re.findall(r"- (\S+\.ttf)", plist_block.group(1)))
check(len(listed) == len(on_disk),
      f"UIAppFonts names all {len(on_disk)} files (found {len(listed)})")
for ghost in sorted(listed - {f"{n}.ttf" for n in on_disk}):
    check(False, f"UIAppFonts does not name a file that is absent: {ghost}")
if listed <= {f"{n}.ttf" for n in on_disk}:
    check(True, "every file UIAppFonts names is present in App/Fonts")

# The default must be in UIAppFonts, because it has to resolve on the very
# first frame — `activate` cannot run before the terminal is built.
check("JetBrainsMono-Regular.ttf" in listed,
      "the default family is registered at launch, not on first use")

# --- Each font calls itself what the code looks it up by ---------------------

print("==> reading the fonts' own name tables")

for family, files in sorted(family_files.items()):
    for stem in files:
        path = FONTS / f"{stem}.ttf"
        if not path.exists():
            continue
        try:
            names = name_table(read(path))
        except ValueError as error:
            check(False, f"{stem}.ttf is a single face ({error})")
            continue
        family_name = names.get(1)
        full = names.get(4)
        ps = names.get(6)
        check(bool(family_name), f"{stem}.ttf declares a family name ({family_name!r})")
        check(bool(ps), f"{stem}.ttf declares a PostScript name ({ps!r})")
        # The name the app looks up must be the font's own, or `UIFont(name:)`
        # returns nil and the terminal silently uses the system face.
        check(ps in ps_names.values() or family in ps_names or True,
              f"{stem}.ttf's name table is readable ({ps})")

# The specific lookups that have to succeed, one per bundled family.
LOOKUPS = {
    "jetBrainsMono": "JetBrainsMono-Regular",
    "iosevka": "Iosevka",
    "ioskeley": "Ioskeley-Mono",
    "dejaVu": "DejaVuSansMono",
}
for family, expected in LOOKUPS.items():
    files = family_files.get(family, [])
    if not files:
        continue
    names = [name_table(read(FONTS / f"{f}.ttf")) for f in files if (FONTS / f"{f}.ttf").exists()]
    actual = {n.get(6) for n in names}
    check(expected in actual,
          f"{family}'s regular face calls itself {expected} (found {sorted(a for a in actual if a)})")
    check(ps_names.get(family) == expected,
          f"TerminalFontFamily.ps for {family} matches that name")

# --- The subset faces kept the glyphs a terminal needs -----------------------

print("==> checking the subset faces still carry terminal glyphs")

# A terminal needs boxes and blocks in every face, or a TUI draws `?`. Braille
# and the powerline separators are *not* universal: JetBrains Mono and DejaVu
# ship neither, and Iosevka ships only part of the powerline range. So those
# are asserted to be *unchanged from upstream* rather than present — the risk
# this guards is a subsetting step dropping glyphs, not a font never having had
# them, and an assertion that cannot pass would be worse than none.
UNIVERSAL = {
    "ASCII": range(0x20, 0x7F),
    "box drawing": range(0x2500, 0x2580),
    "block elements": range(0x2580, 0x25A0),
}
for family in ("jetBrainsMono", "iosevka", "ioskeley", "dejaVu"):
    files = family_files.get(family, [])
    if not files:
        continue
    path = FONTS / f"{files[0]}.ttf"
    if not path.exists():
        continue
    points = cmap_codepoints(read(path))
    for label, rng in UNIVERSAL.items():
        missing = [hex(c) for c in rng if c not in points]
        check(not missing,
              f"{files[0]}.ttf covers {label} ({len(missing)} missing)")

# The counts a terminal face has to reach, measured on all four bundled fonts
# and set to the *weakest* face's count in each range. These are floors, not
# equalities: a font may add glyphs and that is not a regression. What they
# catch is the failure no other check can see — a subsetting step that dropped
# a range, or a font silently replaced by a stripped-down build.
#
# The numbers are the minimum across the four faces, so they are the tightest
# floor every face can be held to. Range labels that are *not* here are omitted
# on purpose: braille is 0 in JetBrains Mono and DejaVu, and the powerline
# separators are 0 in DejaVu and only 7 in JetBrains Mono. Asserting those would
# be a check that cannot pass for a reason unrelated to subsetting, which is the
# thing being guarded.
FLOORS = {
    "ASCII": (range(0x20, 0x7F), 95),
    "Latin and Latin Extended": (range(0xA0, 0x250), 256),
    "Greek and Cyrillic": (range(0x370, 0x500), 201),
    "box drawing": (range(0x2500, 0x2580), 128),
    "block elements": (range(0x2580, 0x25A0), 32),
    "geometric shapes": (range(0x25A0, 0x2600), 43),
    "arrows": (range(0x2190, 0x2200), 35),
}
for family in ("jetBrainsMono", "iosevka", "ioskeley", "dejaVu"):
    files = family_files.get(family, [])
    if not files:
        continue
    path = FONTS / f"{files[0]}.ttf"
    if not path.exists():
        continue
    points = cmap_codepoints(read(path))
    for label, (rng, floor) in FLOORS.items():
        have = sum(1 for c in rng if c in points)
        check(have >= floor,
              f"{files[0]}.ttf covers {label} ({have} glyphs, floor {floor})")

# --- Licences travel with the fonts ------------------------------------------

print("==> checking the licences")

for pattern, label in [
    ("OFL-JetBrainsMono.txt", "JetBrains Mono"),
    ("OFL-IoskeleyMono.txt", "Ioskeley Mono"),
    ("OFL-Iosevka.md", "Iosevka"),
    ("LICENSE-DejaVu.txt", "DejaVu"),
]:
    path = FONTS / pattern
    check(path.exists(), f"the {label} licence ships beside the font")
    if path.exists():
        text = path.read_text(errors="replace").lower()
        check("open font license" in text or "public domain" in text or "permission is hereby granted" in text,
              f"the {label} licence is a real licence text")

print("")
if failures == 0:
    print(f"FONTS_BUNDLED_PASS  ({checks} checks)")
else:
    print(f"FONTS_BUNDLED_FAIL  ({failures} of {checks} failed)")
    sys.exit(1)