#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file_contains() {
    local file=$1
    local expected=$2
    grep -Fqx -- "$expected" "$file" || fail "$file does not contain $expected"
}

"$ROOT_DIR/subdomreco.sh" --help > /dev/null
[[ $("$ROOT_DIR/subdomreco.sh" --version) == "subdomreco 2.0.0" ]] || fail "version output"

if "$ROOT_DIR/subdomreco.sh" --domain 'https://example.com/path' > /dev/null 2>&1; then
    fail "invalid domains must be rejected"
fi

mkdir -p "$TEST_DIR/bin"

cat > "$TEST_DIR/bin/subfinder" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
domain=""
output=""
while (( $# > 0 )); do
    case "$1" in
        -d) domain=$2; shift 2 ;;
        -o) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf 'api.%s\n*.cdn.%s\nOUT-OF-SCOPE.invalid\n' "$domain" "$domain" > "$output"
MOCK

cat > "$TEST_DIR/bin/assetfinder" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
domain=${2:?missing domain}
printf 'dev.%s\nAPI.%s\n' "$domain" "$domain"
MOCK

cat > "$TEST_DIR/bin/httpx" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
input=""
output=""
while (( $# > 0 )); do
    case "$1" in
        -l) input=$2; shift 2 ;;
        -o) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
sed 's#^#https://#' "$input" | tee "$output"
MOCK

chmod +x "$TEST_DIR/bin/subfinder" "$TEST_DIR/bin/assetfinder" "$TEST_DIR/bin/httpx"

PATH="$TEST_DIR/bin:$PATH" NO_COLOR=1 "$ROOT_DIR/subdomreco.sh" \
    --domain example.com \
    --engines subfinder,assetfinder \
    --output "$TEST_DIR/results" > /dev/null

RUN_DIR=$(find "$TEST_DIR/results/example_com" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$RUN_DIR" ]] || fail "run directory was not created"

assert_file_contains "$RUN_DIR/subdomains.txt" "api.example.com"
assert_file_contains "$RUN_DIR/subdomains.txt" "cdn.example.com"
assert_file_contains "$RUN_DIR/subdomains.txt" "dev.example.com"
assert_file_contains "$RUN_DIR/live_urls.txt" "https://api.example.com"
grep -Fq '"subdomains_discovered": 3' "$RUN_DIR/summary.json" || fail "summary count"

printf 'All CLI tests passed.\n'
