#!/bin/zsh
# Privacy scan: prove that nothing personal ships.
#
#   Tools/privacy_scan.sh                 scan the tracked files of the repository (or a given ref with --ref)
#   Tools/privacy_scan.sh --app <path>    also scan a built .app or .zip (file contents and `strings` of binaries)
#   Tools/privacy_scan.sh --ref <branch>  scan the whole history reachable from a ref instead of the working tree
#
# Terms come from local, gitignored places, so this script itself contains nothing personal:
#   private/scan-terms.txt         one term per line (case-insensitive); "re:<regex>" for an extended regex
#   private/scan-terms-public.txt  the same format; terms that may be in the working tree but must not be in
#                                  anything that is published. Only used with --ref and --app.
#   Config/secrets.local.json      the live webhook token and share code, if the file exists
# Generic patterns (webhook URLs with a token, share codes, tokens, home-folder paths) are always checked.
# Exit status 1 if anything is found.
set -uo pipefail
cd "$(dirname "$0")/.."
app=""; ref=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="$2"; shift 2;;
    --ref) ref="$2"; shift 2;;
    *) echo "unknown option $1"; exit 2;;
  esac
done

typeset -a fixed regexes
if [[ -f private/scan-terms.txt ]]; then
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == re:* ]]; then regexes+=("${line#re:}"); else fixed+=("$line"); fi
  done < private/scan-terms.txt
else
  echo "note: private/scan-terms.txt not found; only generic patterns are checked"
fi
# Terms for published things only (a branch given with --ref, a built app): never applied to the working tree.
typeset -a pubfixed pubregexes
if [[ -f private/scan-terms-public.txt ]]; then
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == re:* ]]; then pubregexes+=("${line#re:}"); else pubfixed+=("$line"); fi
  done < private/scan-terms-public.txt
fi
if [[ -f Config/secrets.local.json ]] && command -v jq >/dev/null; then
  for v in $(jq -r '[.discordWebhooks[]? | split("/") | .[-1], .[-2]] + [.privateServerShareCode // empty] + [(.privateServerLink // "" | capture("code=(?<c>[A-Za-z0-9]+)")? | .c // empty)] | .[]' Config/secrets.local.json 2>/dev/null); do
    [[ ${#v} -ge 8 ]] && fixed+=("$v")
  done
fi
regexes+=(
  'discord(app)?\.com/api/webhooks/[0-9]{6,}/[A-Za-z0-9_-]{20,}'
  'share\?code=[A-Za-z0-9]{12,}'
  'ROBLOSECURITY[=]'
  'gh[opsu]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
  '/Users/[A-Za-z0-9._-]+/'
  'DEVELOPMENT_TEAM *[:=] *[A-Z0-9]{10}'
)

hits=0
report() { # label, count, sample
  if [[ "$2" -gt 0 ]]; then hits=$((hits + $2)); printf '  HIT  %-34s %s  %s\n' "$1" "$2" "$3"; fi
}
mask() { local t="$1"; if [[ ${#t} -gt 6 ]]; then print -r -- "${t[1,3]}…(${#t} chars)"; else print -r -- "${t[1,1]}…(${#t} chars)"; fi }

scan_text() { # name of what is scanned, "published" for things that go public; text on stdin is saved to a temp file
  local what="$1" tmp; tmp=$(mktemp); cat > "$tmp"
  echo "== $what ($(wc -l < "$tmp" | tr -d ' ') lines)"
  if [[ "${2:-}" == published ]]; then
    for t in "${pubfixed[@]}"; do
      n=$(grep -c -i -F -- "$t" "$tmp"); report "published term $(mask "$t")" "$n" "$(grep -m1 -i -n -F -- "$t" "$tmp" | cut -c1-90)"
    done
    for r in "${pubregexes[@]}"; do
      n=$(grep -c -i -E -- "$r" "$tmp"); report "published pattern ${r[1,20]}" "$n" "$(grep -m1 -i -n -E -- "$r" "$tmp" | cut -c1-90)"
    done
  fi
  for t in "${fixed[@]}"; do
    n=$(grep -c -i -F -- "$t" "$tmp"); report "term $(mask "$t")" "$n" "$(grep -m1 -i -n -F -- "$t" "$tmp" | cut -c1-90)"
  done
  for r in "${regexes[@]}"; do
    n=$(grep -c -i -E -- "$r" "$tmp"); report "pattern ${r[1,28]}" "$n" "$(grep -m1 -i -n -E -- "$r" "$tmp" | cut -c1-90)"
  done
  rm -f "$tmp"
}

if [[ -n "$ref" ]]; then
  { git log "$ref" -p --format='commit %H%nAuthor: %an <%ae>%nCommitter: %cn <%ce>%n%B'; git ls-tree -r --name-only "$ref"; } | scan_text "git history of $ref" published
else
  { git ls-files -z | xargs -0 grep -I -n -H -e '' -- 2>/dev/null; git ls-files; } | scan_text "tracked files (working tree)"
fi

if [[ -n "$app" ]]; then
  work=$(mktemp -d)
  if [[ "$app" == *.zip ]]; then ditto -x -k "$app" "$work"; target="$work"; else target="$app"; fi
  {
    find "$target" -type f -print                                   # file names
    find "$target" -type f -exec grep -I -H -n -e '' {} + 2>/dev/null   # text files
    find "$target" -type f -exec sh -c 'strings -a "$1" | sed "s|^|$1: |"' _ {} \; 2>/dev/null   # binaries
    find "$target" -name '*.plist' -exec plutil -p {} \; 2>/dev/null
    codesign -dvvv "$(find "$target" -name '*.app' -maxdepth 2 | head -1)" 2>&1
  } | scan_text "built app: $(basename "$app")" published
  rm -rf "$work"
fi

if [[ $hits -eq 0 ]]; then echo "PRIVACY SCAN: CLEAN"; else echo "PRIVACY SCAN: $hits hit(s)"; exit 1; fi
