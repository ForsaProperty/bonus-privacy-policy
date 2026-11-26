#!/usr/bin/env bash
# Claude Code PreToolUse hook: never create a NEW doc file in this repo.
# Docs live in forsa-vault (vault-mcp: https://vault.forsaprop.com/mcp).
# Editing an existing file and deleting docs are not blocked here; CI
# (ForsaProperty/.github no-docs workflow) judges edits to existing docs.
# Generated from ForsaProperty/.github scripts/hook.template.sh by build.sh;
# edit it there, not here.
set -uo pipefail

VAULT_URL="https://vault.forsaprop.com/mcp"
input="$(cat)"

json_get() {  # json_get <key...>: first non-empty tool_input.<key>
  local k v
  for k in "$@"; do
    v=""
    if command -v jq >/dev/null 2>&1; then
      v="$(printf '%s' "$input" | jq -r --arg k "$k" '.tool_input[$k] // empty' 2>/dev/null)"
    elif command -v python3 >/dev/null 2>&1; then
      v="$(printf '%s' "$input" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tool_input",{}).get(sys.argv[1]) or "")
except Exception: pass' "$k" 2>/dev/null)"
    elif command -v node >/dev/null 2>&1; then
      v="$(printf '%s' "$input" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const v=(JSON.parse(s).tool_input||{})[process.argv[1]];if(v)console.log(v)}catch(e){}})' "$k" 2>/dev/null)"
    else
      v="$(printf '%s' "$input" | sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)"
    fi
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  done
  return 0
}

file="$(json_get file_path notebook_path)"
[[ -z "$file" ]] && exit 0
[[ -e "$file" ]] && exit 0          # existing file: not a new doc

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
case "$file" in /*) abs="$file" ;; *) abs="$root/$file" ;; esac
# Resolve symlinks via the nearest existing ancestor; the file and its folders
# may not exist yet.
norm() {
  local p="$1" tail=""
  while [[ ! -d "$p" && "$p" != "/" && "$p" != "." ]]; do tail="/$(basename "$p")$tail"; p="$(dirname "$p")"; done
  printf '%s%s' "$(cd "$p" 2>/dev/null && pwd -P)" "$tail"
}
abs="$(norm "$(dirname "$abs")")/$(basename "$abs")"
root="$(cd "$root" 2>/dev/null && pwd -P)" || exit 0
case "$abs" in "$root"/*) rel="${abs#"$root"/}" ;; *) exit 0 ;; esac   # outside the repo

# --- BEGIN is_doc ---
NODOCS_ALLOW=()
load_allow() {  # load_allow <repo-root>
  local f="${1:-.}/.github/no-docs-allow" line
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && NODOCS_ALLOW+=("$line")
  done < "$f"
  return 0
}

# is_doc PATH -> exit 0 when PATH (repo-relative) is a doc that must live in the vault.
is_doc() {
  local p="${1#./}" lc base dir
  # bash 3.2 (macOS /bin/bash) has no ${x,,}; fall back to tr there.
  if ((BASH_VERSINFO[0] >= 4)); then lc="${p,,}"; else lc="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"; fi
  base="${lc##*/}"
  if [[ "$lc" == */* ]]; then dir="${lc%/*}/"; else dir=""; fi

  # ---- Allowlist (always fine) ----
  case "$base" in
    readme.md|agents.md|claude.md|claude.local.md|changelog.md) return 1 ;;
    license*|licence*|copying*|notice|notice.*|*-ofl.txt|ofl.txt|*-license.txt) return 1 ;;
  esac
  case "$lc" in
    .github/*) return 1 ;;                                   # issue/PR templates, workflows
    node_modules/*|*/node_modules/*|vendor/*|*/vendor/*) return 1 ;;  # third-party
    # Agent instructions, skills, commands, hooks (incl. their assets) and settings.
    .claude/agents/*|.claude/commands/*|.claude/hooks/*|.claude/skills/*) return 1 ;;
    .claude/settings*.json|.claude/settings*.json.example) return 1 ;;
  esac
  # Per-repo exceptions for files that code reads (ratchet baselines, manifests,
  # served .md): one bash glob per line in .github/no-docs-allow (# = comment).
  local pat
  for pat in ${NODOCS_ALLOW[@]+"${NODOCS_ALLOW[@]}"}; do
    # shellcheck disable=SC2053
    [[ "$p" == $pat ]] && return 1
  done
  # Tests, fixtures and shipped assets may legitimately be any format
  # (a PDF a parser test reads, an e2e journey spec, a vector PDF in an
  # iOS asset catalog, a served /public/auth.md).
  case "/$dir" in
    */fixtures/*|*/__fixtures__/*|*/testdata/*|*/test-data/*|*/test_data/*|*/__snapshots__/*) return 1 ;;
    */test/*|*/tests/*|*/__tests__/*|*/e2e/*|*/spec/*|*/specs/*) return 1 ;;
    */public/*|*/static/*|*.xcassets/*|*/res/raw/*|*/assets/*) return 1 ;;
  esac

  # ---- Doc folders ----
  # docs/ or doc/ at any depth: everything in them is a doc unless the file is
  # code or data (tokens.json, a verify script, a route called "docs" keeps working).
  case "/$dir" in
    */docs/*|*/doc/*)
      case "$base" in
        *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.py|*.go|*.dart|*.kt|*.java|*.swift|*.rb|*.php|*.rs|*.c|*.h|*.cpp|*.cs) return 1 ;;
        *.css|*.scss|*.sass|*.less|*.vue|*.svelte|*.astro|*.json|*.yml|*.yaml|*.toml|*.sql|*.sh|*.graphql|*.prisma) return 1 ;;
        *) return 0 ;;
      esac ;;
  esac

  # ---- Doc file types (anywhere, including other .claude/ paths) ----
  case "$base" in
    *.md|*.mdx|*.markdown|*.rst|*.adoc|*.asciidoc) return 0 ;;
    *.pdf|*.doc|*.docx|*.ppt|*.pptx|*.odt|*.odp|*.rtf|*.pages|*.key) return 0 ;;
  esac
  # .claude/: anything else that is not agents/commands/hooks/skills/settings
  # and looks like knowledge (notes, plans, handoffs) counts as a doc.
  case "$lc" in
    .claude/*.txt|.claude/*.org|.claude/*.html) return 0 ;;
  esac

  # ---- Loose notes as .txt ----
  # Config, data, fixtures and web files (robots.txt, requirements.txt, llms.txt,
  # store release notes, url lists) pass. Fail when the name says "notes" or it is
  # a loose .txt at the repo root that is not a known config file.
  case "$base" in
    *.txt)
      case "$base" in
        *note*|*todo*|*plan*|*handoff*|*hand-off*|*summary*|*meeting*|*minutes*|*brainstorm*|*idea*|*draft*|*scratch*|*context*|*phase*|*memo*|*journal*|*decision*|*roadmap*|*retro*|*transcript*|*howto*|*how-to*|*guide*|*spec.txt|*readme*)
          case "$dir" in *release-notes/*|*release_notes/*|*/metadata/*|metadata/*) return 1 ;; esac
          return 0 ;;
      esac
      if [[ -z "$dir" ]]; then
        case "$base" in
          requirements*.txt|*-requirements*.txt|constraints*.txt|robots.txt|humans.txt|ads.txt|app-ads.txt|security.txt|llms.txt|llms-full.txt|ai.txt|cmakelists.txt|runtime.txt|version.txt|apt.txt|packages.txt|*.lock.txt) return 1 ;;
          *) return 0 ;;
        esac
      fi
      return 1 ;;
  esac
  return 1
}
# --- END is_doc ---

load_allow "$root"
if is_doc "$rel"; then
  echo "Blocked: $rel is a doc file. Docs live in forsa-vault ($VAULT_URL), not in this repo. Write it with the vault-mcp tools (vault-mcp server) instead. Allowed in repos: README.md, AGENTS.md, CLAUDE.md, CHANGELOG.md, LICENSE*, .github/**, .claude/{agents,commands,hooks,skills}/**." >&2
  exit 2
fi
exit 0
