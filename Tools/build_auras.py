#!/usr/bin/env python3
"""Build auras.json from the Sol's RNG Wiki "Auras" page (CC BY-SA).

Usage:
  curl -s -A 'wiki-reader' 'https://sol-rng.fandom.com/api.php?action=parse&page=Auras&prop=wikitext&format=json' \
    | python3 Tools/build_auras.py > Packages/SiverKit/Sources/SiverCore/Resources/auras.json

Reads the API JSON (or raw wikitext) on stdin. Each `{{Aura Box|...|aura=NAME|chance=1/N <br>(1/M in {{Biome|B}})}}`
under a `==={{Rarity|TIER}} Auras===` heading becomes one entry.
"""
import json, re, sys, datetime

raw = sys.stdin.read()
try:
    raw = json.loads(raw)["parse"]["wikitext"]["*"]
except Exception:
    pass

def key(name):
    """Same normalization as AuraCatalog.key in Swift: lowercase letters and digits only."""
    return re.sub(r"[^a-z0-9]", "", name.lower())

def clean(text):
    text = re.sub(r"\[\[[^\]|]*\|([^\]]*)\]\]", r"\1", text)      # [[a|b]] -> b
    text = re.sub(r"\[\[([^\]]*)\]\]", r"\1", text)                # [[a]] -> a
    text = re.sub(r"\{\{[A-Za-z ]+\|([^{}|]*)(?:\|[^{}]*)?\}\}", r"\1", text)  # {{Biome|X}} -> X
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", text)).strip()

def number(s):
    return int(s.replace(",", "").replace(".", "")) if s else None

auras, tier = {}, None
for line in raw.splitlines():
    m = re.search(r"\{\{Rarity\|([^}|]+)\}\}\s*Auras", line)
    if line.startswith("===") and m:
        tier = m.group(1).strip()
        continue
    for box in re.finditer(r"\{\{Aura Box\|(.*)\}\}\s*$", line):
        body = box.group(1)
        name = re.search(r"\|aura=\s*([^|]+?)\s*(?:\||$)", "|" + body)
        chance = re.search(r"\|chance=(.*)$", body)
        if not name or not chance:
            continue
        display = clean(name.group(1))
        ctext = chance.group(1)
        base = re.match(r"\s*1\s*/\s*([\d,\.]+)", ctext)
        native = re.search(r"\(\s*1\s*/\s*([\d,\.]+)\s+in\s+(.*?)\)", ctext, re.I)
        only = re.search(r"\(\s*only in\s+(.*?)\)", ctext, re.I)
        entry = {"display": display, "tier": tier}
        if base:
            entry["chance"] = number(base.group(1))
        if native:
            entry["nativeChance"] = number(native.group(1))
            entry["nativeBiome"] = clean(native.group(2)).upper()
        if only:
            # Keep just the biome name: the first {{Biome|…}} inside the parentheses, else the plain text.
            biome = re.search(r"\{\{Biome\|([^{}|]*)(?:\|([^{}]*))?\}\}", only.group(1))
            entry["onlyIn"] = (biome.group(2) or biome.group(1)).strip().upper() if biome else clean(only.group(1)).upper()
        note = clean(re.sub(r"\([^)]*\)", " ", re.sub(r"^\s*1\s*/\s*[\d,\.]+", "", ctext)))
        if note:
            entry["note"] = note
        k = key(display)
        if k and k not in auras:
            auras[k] = entry

out = {
    "_about": "Aura catalog for SiverSol. Keys are aura names reduced to lowercase letters and digits, so the game's internal name (SeekerOfTheCrimsonMoon) and the display name (Seeker of the Crimson Moon) meet. chance = 1 in N. nativeChance / nativeBiome = the easier odds inside the aura's own biome.",
    "_source": "Sol's RNG Wiki, https://sol-rng.fandom.com/wiki/Auras, licensed CC BY-SA 3.0. Regenerate with Tools/build_auras.py.",
    "_generated": datetime.date.today().isoformat(),
    "auras": dict(sorted(auras.items())),
}
json.dump(out, sys.stdout, ensure_ascii=False, indent=1)
sys.stdout.write("\n")
