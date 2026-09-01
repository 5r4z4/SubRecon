#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly VERSION="2.0.0"
readonly DEFAULT_ENGINES="subfinder,assetfinder,amass,findomain,sublist3r"

DOMAIN=""
OUTPUT_ROOT="./results"
ENGINE_CSV="$DEFAULT_ENGINES"
THREADS=50
TIMEOUT=10
SKIP_HTTP=false
INSTALL_ONLY=false

if [[ -t 2 && "${NO_COLOR:-}" == "" ]]; then
    readonly BLUE=$'\033[0;34m'
    readonly YELLOW=$'\033[0;33m'
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly RESET=$'\033[0m'
else
    readonly BLUE="" YELLOW="" RED="" GREEN="" RESET=""
fi

usage() {
    cat <<'EOF'
Subdomreco - authorized subdomain reconnaissance automation

Usage:
  ./subdomreco.sh --domain example.com [options]
  ./subdomreco.sh --install

Required:
  -d, --domain DOMAIN       Domain that you are authorized to assess

Options:
  -o, --output DIRECTORY   Output root (default: ./results)
  -e, --engines LIST       Comma-separated engines (default: all supported)
  -t, --threads NUMBER     httpx worker count (default: 50)
      --timeout SECONDS    httpx request timeout (default: 10)
      --skip-http          Enumerate only; do not probe discovered hosts
      --install            Install the core toolchain and exit
  -h, --help               Show help
  -v, --version            Show version

Supported engines:
  subfinder, assetfinder, amass, findomain, sublist3r

Example:
  ./subdomreco.sh -d example.com -e subfinder,assetfinder -o ./results

Use this tool only on systems for which you have explicit authorization.
EOF
}

log() {
    printf '%s[+]%s %s\n' "$BLUE" "$RESET" "$*" >&2
}

success() {
    printf '%s[✓]%s %s\n' "$GREEN" "$RESET" "$*" >&2
}

warn() {
    printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

die() {
    printf '%s[✗]%s %s\n' "$RED" "$RESET" "$*" >&2
    exit 1
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_valid_domain() {
    local value=$1
    (( ${#value} <= 253 )) || return 1
    [[ "$value" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -d|--domain)
                (( $# >= 2 )) || die "$1 requires a value"
                DOMAIN=$2
                shift 2
                ;;
            -o|--output)
                (( $# >= 2 )) || die "$1 requires a value"
                OUTPUT_ROOT=$2
                shift 2
                ;;
            -e|--engines)
                (( $# >= 2 )) || die "$1 requires a value"
                ENGINE_CSV=$2
                shift 2
                ;;
            -t|--threads)
                (( $# >= 2 )) || die "$1 requires a value"
                THREADS=$2
                shift 2
                ;;
            --timeout)
                (( $# >= 2 )) || die "$1 requires a value"
                TIMEOUT=$2
                shift 2
                ;;
            --skip-http)
                SKIP_HTTP=true
                shift
                ;;
            --install)
                INSTALL_ONLY=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                printf 'subdomreco %s\n' "$VERSION"
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                die "Unknown option: $1 (use --help)"
                ;;
        esac
    done

    (( $# == 0 )) || die "Unexpected positional arguments: $*"
}

engine_command() {
    case "$1" in
        subfinder) printf 'subfinder\n' ;;
        assetfinder) printf 'assetfinder\n' ;;
        amass) printf 'amass\n' ;;
        findomain) printf 'findomain\n' ;;
        sublist3r) printf 'sublist3r\n' ;;
        *) return 1 ;;
    esac
}

run_engine() {
    local engine=$1
    local output_file=$2

    case "$engine" in
        subfinder)
            subfinder -silent -d "$DOMAIN" -o "$output_file"
            ;;
        assetfinder)
            assetfinder --subs-only "$DOMAIN" > "$output_file"
            ;;
        amass)
            amass enum -passive -d "$DOMAIN" -o "$output_file"
            ;;
        findomain)
            findomain -q -t "$DOMAIN" > "$output_file"
            ;;
        sublist3r)
            sublist3r -d "$DOMAIN" -o "$output_file"
            ;;
        *)
            return 2
            ;;
    esac
}

write_summary() {
    local summary_file=$1
    local discovered_count=$2
    local live_count=$3
    local completed_count=$4
    local generated_at
    generated_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

    cat > "$summary_file" <<EOF
{
  "tool": "subdomreco",
  "version": "$VERSION",
  "target": "$DOMAIN",
  "generated_at": "$generated_at",
  "engines_requested": "$ENGINE_CSV",
  "engines_completed": $completed_count,
  "subdomains_discovered": $discovered_count,
  "live_urls": $live_count,
  "http_probe_skipped": $SKIP_HTTP
}
EOF
}

main() {
    parse_args "$@"

    local script_dir
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

    if [[ "$INSTALL_ONLY" == true ]]; then
        "$script_dir/scripts/install.sh"
        exit 0
    fi

    [[ -n "$DOMAIN" ]] || die "--domain is required (use --help)"
    DOMAIN=${DOMAIN,,}
    DOMAIN=${DOMAIN%.}
    is_valid_domain "$DOMAIN" || die "Invalid domain: $DOMAIN (provide a hostname such as example.com)"
    is_positive_integer "$THREADS" || die "--threads must be a positive integer"
    is_positive_integer "$TIMEOUT" || die "--timeout must be a positive integer"
    [[ -n "$OUTPUT_ROOT" ]] || die "--output cannot be empty"

    local -a requested_engines=()
    local -a active_engines=()
    local -a pids=()
    local -a output_files=()
    local -a log_files=()
    local engine command_name

    IFS=',' read -r -a requested_engines <<< "$ENGINE_CSV"
    (( ${#requested_engines[@]} > 0 )) || die "--engines cannot be empty"

    for engine in "${requested_engines[@]}"; do
        [[ -n "$engine" ]] || die "Empty engine name in --engines"
        command_name=$(engine_command "$engine") || die "Unsupported engine: $engine"
        if command -v "$command_name" > /dev/null 2>&1; then
            active_engines+=("$engine")
        else
            warn "Skipping $engine: command '$command_name' is not installed"
        fi
    done

    (( ${#active_engines[@]} > 0 )) || die "No enumeration engines are installed. Run ./subdomreco.sh --install"

    local timestamp safe_target run_dir raw_dir
    timestamp=$(date -u +'%Y%m%dT%H%M%SZ')
    safe_target=${DOMAIN//./_}
    run_dir="${OUTPUT_ROOT%/}/${safe_target}/${timestamp}"
    raw_dir="$run_dir/raw"
    mkdir -p "$raw_dir"

    log "Target: $DOMAIN"
    log "Output: $run_dir"
    log "Starting ${#active_engines[@]} enumeration engine(s) in parallel"

    local raw_file engine_log
    for engine in "${active_engines[@]}"; do
        raw_file="$raw_dir/${engine}.txt"
        engine_log="$raw_dir/${engine}.log"
        : > "$raw_file"
        run_engine "$engine" "$raw_file" > "$engine_log" 2>&1 &
        pids+=("$!")
        output_files+=("$raw_file")
        log_files+=("$engine_log")
    done

    local completed_count=0
    local index
    for index in "${!pids[@]}"; do
        if wait "${pids[$index]}"; then
            success "${active_engines[$index]} completed"
            (( completed_count += 1 ))
        else
            warn "${active_engines[$index]} failed; inspect ${log_files[$index]}"
        fi
    done

    (( completed_count > 0 )) || die "All enumeration engines failed"

    local subdomains_file="$run_dir/subdomains.txt"
    awk -v domain="$DOMAIN" '
        {
            value = tolower($1)
            sub(/^\*\./, "", value)
            sub(/\.$/, "", value)
            if (value !~ /^[a-z0-9.-]+$/) next
            if (value == domain ||
                (length(value) > length(domain) &&
                 substr(value, length(value) - length(domain)) == "." domain)) {
                print value
            }
        }
    ' "${output_files[@]}" | LC_ALL=C sort -u > "$subdomains_file"

    local discovered_count
    discovered_count=$(wc -l < "$subdomains_file")
    discovered_count=${discovered_count//[[:space:]]/}
    success "Discovered $discovered_count unique subdomain(s)"

    local live_file="$run_dir/live_urls.txt"
    local live_count=0
    : > "$live_file"

    if [[ "$SKIP_HTTP" == false && "$discovered_count" -gt 0 ]]; then
        if command -v httpx > /dev/null 2>&1; then
            log "Probing discovered hosts with httpx"
            if httpx -silent -l "$subdomains_file" -threads "$THREADS" \
                -timeout "$TIMEOUT" -retries 1 -follow-redirects -o "$live_file"; then
                live_count=$(wc -l < "$live_file")
                live_count=${live_count//[[:space:]]/}
                success "Found $live_count live URL(s)"
            else
                warn "httpx failed; enumeration results are still available"
            fi
        else
            warn "Skipping HTTP probing: ProjectDiscovery httpx is not installed"
        fi
    elif [[ "$SKIP_HTTP" == true ]]; then
        log "HTTP probing skipped by request"
    fi

    write_summary "$run_dir/summary.json" "$discovered_count" "$live_count" "$completed_count"

    printf '\nResults\n'
    printf '  Subdomains: %s\n' "$subdomains_file"
    printf '  Live URLs:  %s\n' "$live_file"
    printf '  Summary:    %s\n' "$run_dir/summary.json"
}

main "$@"
