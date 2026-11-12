#!/bin/sh
# Builds the site and publishes it to the gh-pages branch, which GitHub Pages serves.
# Usage: tools/deploy-pages.sh [remote]   (from the project root; default remote: origin)
#
# The branch is replaced by a single new commit each time, so old 40 MB snapshots don't pile up
# in the repository's history.
set -eu
remote=${1:-origin}
url=$(git remote get-url "$remote")
rev=$(git describe --always --dirty)
# The site is committed from a temporary repository, which would not see this one's author settings.
name=$(git config user.name)
email=$(git config user.email)

zig build
files="index.html term.js rvterm64.wasm snapshot64.bin.gz"
site=$(mktemp -d)
trap 'rm -rf "$site"' EXIT
for f in $files; do cp "zig-out/web/$f" "$site/"; done
touch "$site/.nojekyll" # serve the files as they are, without Jekyll

git -C "$site" init -q -b gh-pages
git -C "$site" add -A
git -C "$site" -c user.name="$name" -c user.email="$email" commit -q -m "Deploy $rev"
git -C "$site" push -f "$url" gh-pages
