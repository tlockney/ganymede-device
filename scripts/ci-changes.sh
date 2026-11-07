#!/bin/sh
# Which CI jobs a pull request needs (ci.yml, #45). Prints `ts=true|false`
# (the test and browser jobs) and `swift=true|false` (the macOS swift
# job), for $GITHUB_OUTPUT.
#
# On a pull request, actions/checkout checks out the merge commit, so
# HEAD^1 is the base and `git diff HEAD^1 HEAD` is what the PR changes.
# Docs and Markdown need neither; anything not listed needs both. A push
# to main diffs against the commit main was at before it (BASE_SHA,
# github.event.before; HEAD^1 without it) with the same rules (#49). Any
# other event, and a push whose base can't be found or diffed, runs
# everything.
set -eu

everything() {
  echo ts=true
  echo swift=true
  exit 0
}

case ${GITHUB_EVENT_NAME:-} in
  pull_request) base=HEAD^1 ;;
  push)
    # Only a push to main is diffed; a tag push runs everything.
    [ "${GITHUB_REF:-}" = refs/heads/main ] || everything
    base=${BASE_SHA:-HEAD^1}
    case $base in *[!0]*) ;; *) everything ;; esac
    if ! git cat-file -e "$base^{commit}" 2> /dev/null; then
      git fetch -q --no-tags --depth=1 origin "$base" 2> /dev/null || everything
    fi
    ;;
  *) everything ;;
esac

ts=false
swift=false
files=$(git diff --name-only "$base" HEAD) || everything
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case $f in
    *.md | docs/* | LICENSE) ;;
    Package.swift | Package.resolved | swift/*) swift=true ;;
    src/* | test/* | scripts/build.mjs | package.json | package-lock.json | tsconfig*.json) ts=true ;;
    *) ts=true; swift=true ;;
  esac
done <<EOF2
$files
EOF2

echo "ts=$ts"
echo "swift=$swift"
