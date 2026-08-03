#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
WORKSPACE_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
CLASSIFIER="$WORKSPACE_ROOT/harness/lib/sensitive_classifier.py"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/b1n433.XXXXXX")"

cleanup() {
  if [[ -n "${fixture_root:-}" && -d "$fixture_root" && "$fixture_root" != "/" ]]; then
    rm -rf -- "$fixture_root"
  fi
}
trap cleanup EXIT INT TERM

fail() {
  printf 'test-sensitive-scanner: FAIL: %s\n' "$1" >&2
  exit 1
}

expect_clean() {
  local fixture="$1"
  local label="$2"
  if ! python3 -B "$CLASSIFIER" --quiet < "$fixture"; then
    fail "$label should be accepted"
  fi
}

expect_blocked() {
  local fixture="$1"
  local label="$2"
  if python3 -B "$CLASSIFIER" --quiet < "$fixture"; then
    fail "$label should be blocked"
  fi
}

callable_fixture="$fixture_root/callable.py"
printf '%s\n' \
  'api_key = resolve_runtime_credential_identifier_that_is_long_enough()' \
  'secret_key = settings.runtime_credential_identifier_that_is_long_enough' \
  'private_key = credential_provider.lookup_for_current_environment(context)' \
  'api_key = credential_provider.lookup_for_current_environment(context).value' \
  'api_key = resolve_named_environment_value("RUNTIME_KEY")' \
  'mnemonic = process.env.RUNTIME_MNEMONIC_IDENTIFIER' \
  'seed_phrase = ${RUNTIME_SEED_PHRASE_IDENTIFIER}' \
  > "$callable_fixture"
expect_clean "$callable_fixture" "callable and identifier expressions"

credential_key="API"'_KEY'
secondary_key="SECRET"'_KEY'
safe_reference='settings.runtime_credential_identifier_that_is_long_enough'
hex_identifier='abcdefabcdefabcdefabcdefabcdefab'
quoted_value='Q7vN4xLm2pRa8sTy6uWi3oEz9cDf5gHj'
hex_value='9f4e8d2c7b6a5f1039482716abcdef12'
prefixed_hex_value='0xabcdefabcdefabcdefabcdefabcdefab'
provider_value='ghp_Q7vN4xLm2pRa8sTy6uWi3oEz9cDf'
entropy_value='9nQx+7Lm/2pR=8sTy-6uWi_3oEz5cDf'

hex_identifier_fixture="$fixture_root/hex-identifier.txt"
printf '%s=%s\n' "$credential_key" "$hex_identifier" > "$hex_identifier_fixture"
expect_clean "$hex_identifier_fixture" "hex-shaped bare identifier"

quoted_fixture="$fixture_root/quoted.txt"
printf '%s = "%s"\n' "$credential_key" "$quoted_value" > "$quoted_fixture"
expect_blocked "$quoted_fixture" "quoted literal"

hex_fixture="$fixture_root/hex.txt"
printf '%s=%s\n' "$credential_key" "$hex_value" > "$hex_fixture"
expect_blocked "$hex_fixture" "hexadecimal literal"

prefixed_hex_fixture="$fixture_root/prefixed-hex.txt"
printf '%s=%s\n' "$credential_key" "$prefixed_hex_value" > "$prefixed_hex_fixture"
expect_blocked "$prefixed_hex_fixture" "0x-prefixed hexadecimal literal"

quoted_hex_fixture="$fixture_root/quoted-hex.txt"
printf '%s="%s"\n' "$credential_key" "$hex_identifier" > "$quoted_hex_fixture"
expect_blocked "$quoted_hex_fixture" "quoted hexadecimal literal"

provider_fixture="$fixture_root/provider.txt"
printf '%s=%s\n' "$credential_key" "$provider_value" > "$provider_fixture"
expect_blocked "$provider_fixture" "provider-prefixed literal"

entropy_fixture="$fixture_root/entropy.txt"
printf '%s=%s\n' "$credential_key" "$entropy_value" > "$entropy_fixture"
expect_blocked "$entropy_fixture" "high-entropy literal"

multi_quoted_fixture="$fixture_root/multi-quoted.txt"
printf '%s = %s; %s = "%s"\n' \
  "$credential_key" "$safe_reference" "$secondary_key" "$quoted_value" \
  > "$multi_quoted_fixture"
expect_blocked "$multi_quoted_fixture" "later quoted literal assignment"

multi_hex_fixture="$fixture_root/multi-hex.txt"
printf '%s = %s; %s = %s\n' \
  "$credential_key" "$safe_reference" "$secondary_key" "$hex_value" \
  > "$multi_hex_fixture"
expect_blocked "$multi_hex_fixture" "later hexadecimal literal assignment"

multi_provider_fixture="$fixture_root/multi-provider.txt"
printf '%s = %s; %s = %s\n' \
  "$credential_key" "$safe_reference" "$secondary_key" "$provider_value" \
  > "$multi_provider_fixture"
expect_blocked "$multi_provider_fixture" "later provider-prefixed literal assignment"

multi_entropy_fixture="$fixture_root/multi-entropy.txt"
printf '%s = %s; %s = %s\n' \
  "$credential_key" "$safe_reference" "$secondary_key" "$entropy_value" \
  > "$multi_entropy_fixture"
expect_blocked "$multi_entropy_fixture" "later high-entropy literal assignment"

callable_fallback_fixture="$fixture_root/callable-fallback.txt"
printf '%s = resolve_runtime_credential() || "%s"\n' \
  "$credential_key" "$quoted_value" > "$callable_fallback_fixture"
expect_blocked "$callable_fallback_fixture" "callable with literal fallback"

reference_concat_fixture="$fixture_root/reference-concat.txt"
printf '%s = %s + "%s"\n' \
  "$credential_key" "$safe_reference" "$provider_value" \
  > "$reference_concat_fixture"
expect_blocked "$reference_concat_fixture" "reference with literal concatenation"

bypass_fixture="$fixture_root/bypass.txt"
printf '%s = %s; %s = "%s"\n%s = %s; %s = %s\n%s = %s; %s = %s\n%s = %s; %s = %s\n%s = resolve_runtime_credential() || "%s"\n%s = %s + "%s"\n' \
  "$credential_key" "$safe_reference" "$secondary_key" "$quoted_value" \
  "$credential_key" "$safe_reference" "$secondary_key" "$hex_value" \
  "$credential_key" "$safe_reference" "$secondary_key" "$provider_value" \
  "$credential_key" "$safe_reference" "$secondary_key" "$entropy_value" \
  "$credential_key" "$quoted_value" \
  "$credential_key" "$safe_reference" "$provider_value" \
  > "$bypass_fixture"

classifier_report="$fixture_root/classifier-report.txt"
if python3 -B "$CLASSIFIER" < "$quoted_fixture" > /dev/null 2> "$classifier_report"; then
  fail "classifier report should return a blocked status"
fi
if ! rg -q 'category=quoted-literal' "$classifier_report"; then
  fail "classifier report should include only the finding category"
fi
if rg -F -q "$quoted_value" "$classifier_report"; then
  fail "classifier report must redact candidate values"
fi

assert_report_redacted() {
  local report="$1"
  local candidate
  for candidate in "$quoted_value" "$hex_value" "$provider_value" "$entropy_value"; do
    if rg -F -q "$candidate" "$report"; then
      fail "scanner report must redact all candidate values"
    fi
  done
}

make_repository() {
  local repository="$1"
  mkdir -p "$repository/src"
  cp -R "$WORKSPACE_ROOT/harness" "$repository/harness"
  git -C "$repository" init -q -b main
  git -C "$repository" config user.name 'Harness Regression'
  git -C "$repository" config user.email 'harness-regression@example.invalid'
}

staged_repository="$fixture_root/staged-repository"
make_repository "$staged_repository"
cp "$callable_fixture" "$staged_repository/src/runtime.py"
cp "$hex_identifier_fixture" "$staged_repository/src/identifier.py"
git -C "$staged_repository" add src/runtime.py src/identifier.py
if ! "$staged_repository/harness/bin/sensitive-check" > /dev/null 2>&1; then
  fail "staged callable/reference and hex-shaped identifiers should pass"
fi
git -C "$staged_repository" commit --no-verify -qm 'clean baseline'
if ! "$staged_repository/harness/bin/sensitive-check" > /dev/null 2>&1; then
  fail "tracked callable/reference and hex-shaped identifiers should pass"
fi
cp "$bypass_fixture" "$staged_repository/src/config.py"
git -C "$staged_repository" add src/config.py
staged_report="$fixture_root/staged-report.txt"
if "$staged_repository/harness/bin/sensitive-check" > /dev/null 2> "$staged_report"; then
  fail "staged credential literals should be blocked"
fi
if ! rg -q 'credential literal in staged content' "$staged_report"; then
  fail "staged additions should be classified explicitly"
fi
assert_report_redacted "$staged_report"

tracked_repository="$fixture_root/tracked-repository"
make_repository "$tracked_repository"
cp "$bypass_fixture" "$tracked_repository/src/config.py"
git -C "$tracked_repository" add src/config.py
git -C "$tracked_repository" commit --no-verify -qm 'tracked fixture'
tracked_report="$fixture_root/tracked-report.txt"
if "$tracked_repository/harness/bin/sensitive-check" > /dev/null 2> "$tracked_report"; then
  fail "tracked multi-assignment and composite literals should be blocked"
fi
if ! rg -q 'credential literal in tracked content' "$tracked_report"; then
  fail "tracked content should be classified explicitly"
fi
assert_report_redacted "$tracked_report"

path_repository="$fixture_root/path-repository"
make_repository "$path_repository"
printf '%s\n' 'fixture only' > "$path_repository/.env"
git -C "$path_repository" add .env
if "$path_repository/harness/bin/sensitive-check" > /dev/null 2>&1; then
  fail "forbidden staged paths should remain blocked"
fi

outgoing_repository="$fixture_root/outgoing-repository"
make_repository "$outgoing_repository"
cp "$callable_fixture" "$outgoing_repository/src/runtime.py"
cp "$hex_identifier_fixture" "$outgoing_repository/src/identifier.py"
git -C "$outgoing_repository" add src/runtime.py src/identifier.py
git -C "$outgoing_repository" commit --no-verify -qm 'clean baseline'
clean_sha="$(git -C "$outgoing_repository" rev-parse HEAD)"
zero_sha='0000000000000000000000000000000000000000'
if ! printf 'refs/heads/main %s refs/heads/main %s\n' "$clean_sha" "$zero_sha" | \
  (cd "$outgoing_repository" && harness/hooks/pre-push) > /dev/null 2>&1; then
  fail "clean outgoing commits should pass"
fi

cp "$bypass_fixture" "$outgoing_repository/src/config.py"
git -C "$outgoing_repository" add src/config.py
git -C "$outgoing_repository" commit --no-verify -qm 'sensitive fixture'
sensitive_sha="$(git -C "$outgoing_repository" rev-parse HEAD)"
git -C "$outgoing_repository" switch --detach -q "$clean_sha"
outgoing_report="$fixture_root/outgoing-report.txt"
if printf 'refs/heads/main %s refs/heads/main %s\n' "$sensitive_sha" "$zero_sha" | \
  (cd "$outgoing_repository" && harness/hooks/pre-push) > /dev/null 2> "$outgoing_report"; then
  fail "credential literals in outgoing commits should be blocked"
fi
if ! rg -q 'credential literal found in outgoing commit' "$outgoing_report"; then
  fail "outgoing additions should be classified explicitly"
fi
assert_report_redacted "$outgoing_report"

printf 'test-sensitive-scanner: PASS\n'
