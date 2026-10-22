#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Checks text against a denylist of terms that must not appear in this public
# repository. The denylist itself is never committed: it comes from the
# LEAK_DENYLIST environment variable (newline-separated, used by CI) or from
# ~/.config/leak-denylist/terms (one term per line, used by the git hooks).
#
# Output never contains the matched term or the matched line, because CI logs
# of a public repository are public too. Only the location is reported.
#
# Usage:
#   scripts/leak-check.sh staged           # staged diff (pre-commit)
#   scripts/leak-check.sh file <path>      # a file, e.g. a commit message
#   scripts/leak-check.sh range <a>..<b>   # diff and commit messages of a range
#   scripts/leak-check.sh stdin <label>    # text on stdin, e.g. an issue body

set -euo pipefail

terms_file=$(mktemp)
buf=$(mktemp)
trap 'rm -f "$terms_file" "$buf"' EXIT

if [ -n "${LEAK_DENYLIST:-}" ]; then
  printf '%s\n' "$LEAK_DENYLIST" >"$terms_file"
elif [ -f "$HOME/.config/leak-denylist/terms" ]; then
  cp "$HOME/.config/leak-denylist/terms" "$terms_file"
else
  echo "leak-check: no denylist found (set LEAK_DENYLIST or create ~/.config/leak-denylist/terms)" >&2
  exit 2
fi

# Drop blank lines and comments so an empty line never matches everything.
grep -vE '^[[:space:]]*(#|$)' "$terms_file" >"$terms_file.clean" || true
mv "$terms_file.clean" "$terms_file"

if [ ! -s "$terms_file" ]; then
  echo "leak-check: denylist is empty" >&2
  exit 2
fi

found=0

# Reads the text to check from $buf, so callers never run it in a pipeline
# subshell (which would lose the update to $found).
check() {
  local label=$1
  local lines
  lines=$(grep -niFf "$terms_file" "$buf" | cut -d: -f1 | tr '\n' ' ' || true)

  if [ -n "$lines" ]; then
    echo "leak-check: denylisted term in ${label} (line(s) ${lines% })" >&2
    found=1
  fi
}

added_lines() {
  { grep '^+' || true; } | { grep -v '^+++' || true; }
}

case "${1:-}" in
  staged)
    for path in $(git diff --cached --name-only --diff-filter=ACMR); do
      git diff --cached -U0 -- "$path" | added_lines >"$buf"
      check "staged changes to $path"
    done
    git diff --cached --name-only --diff-filter=ACMR >"$buf"
    check "staged file names"
    ;;
  file)
    cp "$2" "$buf"
    check "$2"
    ;;
  range)
    for path in $(git diff --name-only --diff-filter=ACMR "$2"); do
      git diff -U0 "$2" -- "$path" | added_lines >"$buf"
      check "changes to $path"
    done
    git diff --name-only --diff-filter=ACMR "$2" >"$buf"
    check "file names"
    for sha in $(git rev-list "$2"); do
      git log -1 --format='%an%n%ae%n%B' "$sha" >"$buf"
      check "commit $sha"
    done
    ;;
  stdin)
    cat >"$buf"
    check "$2"
    ;;
  *)
    echo "usage: $0 staged | file <path> | range <a>..<b> | stdin <label>" >&2
    exit 2
    ;;
esac

exit $found
