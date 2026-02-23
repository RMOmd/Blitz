#!/bin/bash

# Цвета и символы
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[1;94m'
NC='\033[0m'
BOLD='\033[1m'

CHECK_MARK="[✓]"
CROSS_MARK="[✗]"
INFO_MARK="[i]"
WARNING_MARK="[!]"

log_info() { echo -e "${BLUE}${INFO_MARK} ${1}${NC}"; }
log_success() { echo -e "${GREEN}${CHECK_MARK} ${1}${NC}"; }
log_warning() { echo -e "${YELLOW}${WARNING_MARK} ${1}${NC}"; }
log_error() { echo -e "${RED}${CROSS_MARK} ${1}${NC}" >&2; }

handle_error() {
    log_error "Error occurred at line $1"
    exit 1
}

trap 'handle_error $LINENO' ERR

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root."
        exit 1
    fi
    log_info "Running with root privileges"
}

check_os_version() {
    local os_name os_version
    log_info "Checking OS compatibility..."
    
    if [ -f /etc/os-release ]; then
        os_name=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        os_version=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
    else
        log_error "Unsupported OS."
        exit 1
    fi

    if ! command -v bc &> /dev/null; then
        log_info "Installing bc package..."
        apt update -qq && apt install -y -qq bc
    fi

    if [[ "$os_name" == "ubuntu" && $(echo "$os_version >= 22" | bc) -eq 1 ]] ||
       [[ "$os_name" == "debian" && $(echo "$os_version >= 12" | bc) -eq 1 ]]; then
        log_success "OS check passed: $os_name $os_version"
    else
        log_error "Supported only on Ubuntu 22+ or Debian 12+."
        exit 1
    fi
    
    log_info "Checking CPU for AVX support..."
    if grep -q -m1 -o -E 'avx|avx2|avx512' /proc/cpuinfo; then
        log_success "CPU supports AVX."
    else
        log_error "CPU DOES NOT support AVX (Required for MongoDB 8.0)."
        log_info "Use 'nodb' version: bash <(curl -sL https://raw.githubusercontent.com/ReturnFI/Blitz/nodb/install.sh)"
        exit 1
    fi
}

install_mongodb() {
    log_info "Installing MongoDB..."
    if command -v mongod &> /dev/null; then
        log_success "MongoDB already installed"
        return 0
    fi
    
    curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor
    local codename=$(lsb_release -cs)
    local repo_line="deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/$(if [ "$codename" = "bookworm" ]; then echo "debian"; else echo "ubuntu"; fi) $codename/mongodb-org/8.0 $(if [ "$codename" = "bookworm" ]; then echo "main"; else echo "multiverse"; fi)"

    echo "$repo_line" | tee /etc/apt/sources.list.d/mongodb-org-8.0.list > /dev/null
    apt update -qq && apt install -y -qq mongodb-org
    systemctl enable mongod && systemctl start mongod
}

install_packages() {
    local REQUIRED_PACKAGES=("jq" "curl" "pwgen" "python3" "python3-pip" "python3-venv" "bc" "zip" "unzip" "lsof" "gnupg" "lsb-release")
    log_info "Installing system packages..."
    apt update -qq
    apt install -y -qq "${REQUIRED_PACKAGES[@]}"
    install_mongodb
}

download_and_extract_release() {
    log_info "Downloading Blitz panel..."
    [ -d "/etc/hysteria" ] && rm -rf /etc/hysteria
    
    local arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local zip_name="Blitz-${arch}.zip"
    local download_url="https://github.com/ReturnFI/Blitz/releases/latest/download/${zip_name}"
    
    mkdir -p /etc/hysteria
    curl -sL -o "/tmp/${zip_name}" "$download_url"
    unzip -q "/tmp/${zip_name}" -d /etc/hysteria
    rm "/tmp/${zip_name}"

    # ПРЯМАЯ ЗАГРУЗКА GEO DATA (чтобы не висло)
    log_info "Downloading Geo-data files manually..."
    curl -L -o /etc/hysteria/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
    curl -L -o /etc/hysteria/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
    
    [ -f "/etc/hysteria/core/scripts/auth/user_auth" ] && chmod +x /etc/hysteria/core/scripts/auth/user_auth
}

setup_python_env() {
    log_info "Setting up Python venv (this may take a few minutes)..."
    cd /etc/hysteria
    python3 -m venv hysteria2_venv
    source hysteria2_venv/bin/activate
    
    # Установка без кэша для экономии места и с выводом процесса
    pip install --no-cache-dir --upgrade pip
    if pip install --no-cache-dir -r requirements.txt; then
        log_success "Python requirements installed"
    else
        log_error "Pip installation failed."
        exit 1
    fi
}

add_alias() {
    local alias_cmd="alias hys2='source /etc/hysteria/hysteria2_venv/bin/activate && /etc/hysteria/menu.sh'"
    if ! grep -q "hys2" ~/.bashrc; then
        echo "$alias_cmd" >> ~/.bashrc
        log_success "Alias 'hys2' added."
    fi
}

run_menu() {
    cd /etc/hysteria
    chmod +x menu.sh
    log_info "Launching Blitz Menu..."
    ./menu.sh
}

main() {
    echo -e "\n${BOLD}${BLUE}======== Blitz Setup Script (Modified) ========${NC}\n"
    
    # ПРЕДВАРИТЕЛЬНАЯ ОЧИСТКА МЕСТА
    log_info "Cleaning logs to free up space..."
    truncate -s 0 /var/log/btmp /var/log/auth.log 2>/dev/null || true
    
    check_root
    check_os_version
    install_packages
    download_and_extract_release
    setup_python_env
    add_alias
    
    echo -e "\n${YELLOW}Starting in 3 seconds...${NC}"
    sleep 3
    run_menu
}

main
