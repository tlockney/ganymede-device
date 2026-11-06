#!/bin/sh
# Which CI jobs a pull request needs (ci.yml, #45). Prints `ts=true|false`
# (the test and browser jobs) and `swift=true|false` (the macOS swift
# job), for $GITHUB_OUTPUT.
#
# On a pull request, actions/checkout checks out the merge commit, so
# HEAD^1 is the base and `git diff HEAD^1 HEAD` is what the PR changes.
# Docs and Markdown need neither; anything not listed needs both. Any
# other event (a push to main) runs everything.
set -eu

if [ "${GITHUB_EVENT_NAME:-}" != pull_request ]; then
  echo ts=true
  echo swift=true
  exit 0
fi

ts=false
swift=false
files=$(git diff --name-only HEAD^1 HEAD)
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
