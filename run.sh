#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .env.local ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env.local
  set +a
  echo "Loaded .env.local"
fi

swift build -c release
echo "Starting iAletheia..."
.build/release/iAletheia
