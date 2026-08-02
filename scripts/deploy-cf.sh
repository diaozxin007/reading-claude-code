#!/usr/bin/env bash
# deploy-cf.sh — Cloudflare Pages build script for reading-claude-code.
# Site is served from domain root (readingclaude.club), not nested under
# /reading-claude-code/ like GitHub Pages, so mdBook's site-url and the
# SEO base URL both need to be overridden for this build target only.
set -euo pipefail

MDBOOK_VERSION=0.4.40
CF_BASE_URL="${CF_BASE_URL:-https://readingclaude.club}"
GH_BASE_URL="https://diaozxin007.github.io/reading-claude-code"

curl -L "https://github.com/rust-lang/mdBook/releases/download/v${MDBOOK_VERSION}/mdbook-v${MDBOOK_VERSION}-x86_64-unknown-linux-gnu.tar.gz" | tar -xz

(cd zh && MDBOOK_OUTPUT__HTML__SITE_URL="/zh/" ../mdbook build)
(cd en && MDBOOK_OUTPUT__HTML__SITE_URL="/en/" ../mdbook build)

mkdir -p _site
cp -r zh/book _site/zh
cp -r en/book _site/en
cp scripts/index.html scripts/sitemap.xml scripts/robots.txt \
   scripts/0fa76633fefe4b8bacbca952a42d6269.txt scripts/og-cover.png _site/

# per-page canonical / hreflang / description (reads BASE_URL from env)
BASE_URL="$CF_BASE_URL" bash scripts/fix-seo.sh _site

# static files (robots.txt / sitemap.xml / index.html) still hardcode the
# GH Pages domain — rewrite just those copies in _site, source files untouched
for f in _site/index.html _site/sitemap.xml _site/robots.txt; do
  sed -i "s#${GH_BASE_URL}#${CF_BASE_URL}#g" "$f"
done

echo "✅ Cloudflare build complete → _site (base: ${CF_BASE_URL})"
