#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

log() {
    printf '[+] %s\n' "$*"
}

die() {
    printf '[x] %s\n' "$*" >&2
    exit 1
}

install_system_dependencies() {
    command -v apt-get > /dev/null 2>&1 || return 0

    local -a elevate=()
    if (( EUID != 0 )); then
        command -v sudo > /dev/null 2>&1 || die "sudo is required to install system packages"
        elevate=(sudo)
    fi

    log "Installing system dependencies"
    "${elevate[@]}" apt-get update
    "${elevate[@]}" apt-get install -y ca-certificates git golang-go
}

install_go_tool() {
    local name=$1
    local package=$2

    if command -v "$name" > /dev/null 2>&1; then
        log "$name is already installed"
        return 0
    fi

    log "Installing $name"
    GOBIN="$USER_BIN" go install "$package"
}

main() {
    if ! command -v go > /dev/null 2>&1; then
        install_system_dependencies
    fi
    command -v go > /dev/null 2>&1 || die "Go 1.21+ is required"

    USER_BIN="${XDG_BIN_HOME:-${HOME}/.local/bin}"
    export USER_BIN
    mkdir -p "$USER_BIN"

    install_go_tool subfinder github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
    install_go_tool assetfinder github.com/tomnomnom/assetfinder@latest
    install_go_tool httpx github.com/projectdiscovery/httpx/cmd/httpx@latest
    install_go_tool amass github.com/owasp-amass/amass/v4/...@master

    printf '\nCore tools were installed in %s\n' "$USER_BIN"
    if [[ ":$PATH:" != *":$USER_BIN:"* ]]; then
        printf 'Add this directory to PATH before running Subdomreco:\n'
        printf '  export PATH="%s:$PATH"\n' "$USER_BIN"
    fi
    printf '\nOptional engines (install separately): findomain, sublist3r\n'
}

USER_BIN=""
main "$@"
