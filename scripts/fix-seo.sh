#!/usr/bin/env bash
# fix-seo.sh — Post-build SEO fixer for reading-claude-code mdBook site.
#
# Replaces placeholder comments in built HTML with correct per-page:
#   1. <link rel="canonical"> pointing to self
#   2. <link rel="alternate" hreflang="..."> pointing to the zh↔en pair
#   3. <meta name="description"> / og:description / twitter:description
#
# Usage: bash scripts/fix-seo.sh [site_dir]
# Run AFTER `mdbook build` and site assembly into _site/

set -euo pipefail

SITE_DIR="${1:-_site}"
BASE_URL="https://diaozxin007.github.io/reading-claude-code"
DESCRIPTIONS_FILE="scripts/descriptions.json"
TITLES_FILE="scripts/titles.json"

if [[ ! -d "$SITE_DIR" ]]; then
  echo "❌ Site directory '$SITE_DIR' not found. Run mdbook build first."
  exit 1
fi

if [[ ! -f "$DESCRIPTIONS_FILE" ]]; then
  echo "❌ Descriptions file '$DESCRIPTIONS_FILE' not found."
  exit 1
fi

if [[ ! -f "$TITLES_FILE" ]]; then
  echo "❌ Titles file '$TITLES_FILE' not found."
  exit 1
fi

# Require jq for JSON lookup
if ! command -v jq &>/dev/null; then
  echo "❌ jq is required but not installed."
  exit 1
fi

# Portable sed in-place: GNU sed uses -i (no arg), BSD sed uses -i ''
sedi() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

fix_file() {
  local file="$1"
  # e.g. file = _site/en/interaction/ask-user-question.html
  # Strip SITE_DIR prefix to get relative path: en/interaction/ask-user-question.html
  local rel_path="${file#${SITE_DIR}/}"

  # Determine language: en or zh
  local lang="${rel_path%%/*}"
  if [[ "$lang" != "en" && "$lang" != "zh" ]]; then
    return 0  # Skip files not under en/ or zh/
  fi

  # Path within language dir: interaction/ask-user-question.html
  local page_path="${rel_path#${lang}/}"

  # Compute alternate language
  local alt_lang
  if [[ "$lang" == "en" ]]; then
    alt_lang="zh"
  else
    alt_lang="en"
  fi

  # --- 1. Canonical URL ---
  local canonical_url="${BASE_URL}/${lang}/${page_path}"
  local canonical_tag="<link rel=\"canonical\" href=\"${canonical_url}\">"

  # --- 2. Hreflang tags (one per line) ---
  local self_url="${BASE_URL}/${lang}/${page_path}"
  local alt_url="${BASE_URL}/${alt_lang}/${page_path}"
  local hreflang_self hreflang_alt hreflang_x

  if [[ "$lang" == "en" ]]; then
    hreflang_self="<link rel=\"alternate\" hreflang=\"en\" href=\"${self_url}\">"
    hreflang_alt="<link rel=\"alternate\" hreflang=\"zh-CN\" href=\"${alt_url}\">"
  else
    hreflang_self="<link rel=\"alternate\" hreflang=\"zh-CN\" href=\"${self_url}\">"
    hreflang_alt="<link rel=\"alternate\" hreflang=\"en\" href=\"${alt_url}\">"
  fi
  hreflang_x="<link rel=\"alternate\" hreflang=\"x-default\" href=\"${BASE_URL}/en/${page_path}\">"

  # --- 3. Per-page description ---
  local description
  description=$(jq -r --arg lang "$lang" --arg page "$page_path" \
    '.[$lang][$page] // empty' "$DESCRIPTIONS_FILE") || true

  # Fallback to book-level description if not in map
  if [[ -z "$description" ]]; then
    if [[ "$lang" == "en" ]]; then
      description="A deep dive into the design of Claude Code tool primitives"
    else
      description="关于 Claude Code 工具原语设计的深度拆解"
    fi
  fi

  # Escape special chars for sed replacement (& \ /)
  local desc_escaped
  desc_escaped=$(printf '%s' "$description" | sed 's/[&/\]/\\&/g')

  local og_desc_tag="<meta property=\"og:description\" content=\"${desc_escaped}\">"
  local tw_desc_tag="<meta name=\"twitter:description\" content=\"${desc_escaped}\">"
  local meta_desc_tag="<meta name=\"description\" content=\"${desc_escaped}\">"

  # --- Apply replacements (one sed call per placeholder to avoid \n issues) ---
  sedi "s|<!-- SEO:CANONICAL -->|${canonical_tag}|" "$file"
  sedi "s|<!-- SEO:HREFLANG -->|${hreflang_self}\n${hreflang_alt}\n${hreflang_x}|" "$file"
  sedi "s|<!-- SEO:OG_DESCRIPTION -->|${og_desc_tag}\n${meta_desc_tag}|" "$file"
  sedi "s|<!-- SEO:TWITTER_DESCRIPTION -->|${tw_desc_tag}|" "$file"
  sedi "s|<!-- SEO:OG_URL -->|<meta property=\"og:url\" content=\"${canonical_url}\">|" "$file"

  # --- Remove mdBook's default global <meta name="description"> (duplicates our per-page one) ---
  sedi '/^<meta name="description" content="A deep dive into the design of Claude Code/d' "$file"
  sedi '/^<meta name="description" content="一本关于 Claude Code 工具原语设计的深度拆解/d' "$file"

  # --- Replace <title> with SEO-optimized per-page title ---
  local title
  title=$(jq -r --arg lang "$lang" --arg page "$page_path" \
    '.[$lang][$page] // empty' "$TITLES_FILE") || true

  if [[ -n "$title" ]]; then
    local title_escaped
    title_escaped=$(printf '%s' "$title" | sed 's/[&/\]/\\&/g')
    sedi "s|<title>.*</title>|<title>${title_escaped}</title>|" "$file"
    # Also update og:title to match
    sedi "s|<meta property=\"og:title\" content=\"[^\"]*\"|<meta property=\"og:title\" content=\"${title_escaped}\"|" "$file"
    sedi "s|<meta name=\"twitter:title\" content=\"[^\"]*\"|<meta name=\"twitter:title\" content=\"${title_escaped}\"|" "$file"
  fi
}

# --- Main ---
echo "🔧 Fixing SEO meta tags in $SITE_DIR ..."

count=0
while IFS= read -r -d '' htmlfile; do
  fix_file "$htmlfile"
  count=$((count + 1))
done < <(find "$SITE_DIR/en" "$SITE_DIR/zh" -name "*.html" -print0 2>/dev/null)

echo "✅ Fixed $count HTML files."
