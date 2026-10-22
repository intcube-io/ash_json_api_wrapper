#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>
#
# SPDX-License-Identifier: MIT

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
chmod +x .githooks/* scripts/leak-check.sh
git config core.hooksPath .githooks

if [ ! -f "$HOME/.config/leak-denylist/terms" ]; then
  echo "Hooks installed, but ~/.config/leak-denylist/terms is missing: every commit will be refused until it exists." >&2
fi
