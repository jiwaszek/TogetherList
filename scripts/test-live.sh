#!/usr/bin/env bash
# Runs the live end-to-end tests (TogetherListSupabaseTests) against the Supabase
# project configured in Config/Secrets.xcconfig. Creates and deletes two
# throwaway accounts. Needs "Confirm email" turned off in the project.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="$ROOT/Config/Secrets.xcconfig"
[[ -f "$SECRETS" ]] || { echo "Missing $SECRETS (copy Config/Secrets.example.xcconfig)"; exit 1; }

value() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$SECRETS" | tail -1 | sed 's#\$()##g; s/[[:space:]]*$//'; }
export TOGETHERLIST_SUPABASE_URL="$(value SUPABASE_URL)"
export TOGETHERLIST_SUPABASE_KEY="$(value SUPABASE_PUBLISHABLE_KEY)"
[[ -n "$TOGETHERLIST_SUPABASE_URL" && -n "$TOGETHERLIST_SUPABASE_KEY" ]] || { echo "SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY not set in $SECRETS"; exit 1; }

echo "Live tests against $TOGETHERLIST_SUPABASE_URL"
cd "$ROOT/TogetherListKit"
swift test --filter TogetherListSupabaseTests "$@"
