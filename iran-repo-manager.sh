#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# IRAN MIRROR FINDER FOR MOST OF LINUX DISTROs
# ==============================================

# Configuration
TIMEOUT=8
BACKUP_DIR="$HOME/backup_repo"
CACHE_DIR="$HOME/.cache/iran-repo-manager"
BLACKLIST="$CACHE_DIR/blacklist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR_FILE="$SCRIPT_DIR/mirrors.list"

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Global vars
DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_CODENAME=""
ARCH="x86_64"
declare -a MIRRORS=()
declare -a RESULTS=()       # each entry: "score|latency_ms|speed_kb|last_epoch|success_path|url"
declare -a SORTED_RESULTS=()

mkdir -p "$CACHE_DIR" "$BACKUP_DIR"
touch "$BLACKLIST"

# ------------------------------
# Terminal setup for non-blocking input
# ------------------------------
setup_terminal() {
    OLD_STTY=$(stty -g 2>/dev/null || true)
    stty -echo -icanon min 0 time 0 2>/dev/null || true
}

restore_terminal() {
    stty "$OLD_STTY" 2>/dev/null || true
}

check_enter() {
    local ch
    ch=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [[ "$ch" == "0a" || "$ch" == "0d" ]]
}

# ------------------------------
# Helper functions
# ------------------------------
detect_distro() {
    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}Cannot detect OS.${NC}" >&2
        exit 1
    fi
    source /etc/os-release
    DISTRO_ID=$ID
    DISTRO_VERSION=$VERSION_ID
    DISTRO_CODENAME=${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}
}

expand_url() {
    local url="$1"
    url="${url//\$distro/$DISTRO_ID}"
    url="${url//\$version/$DISTRO_VERSION}"
    url="${url//\$codename/${DISTRO_CODENAME:-$DISTRO_VERSION}}"
    url="${url//\$basearch/$ARCH}"
    url="${url%/}"  # remove trailing slash
    echo "$url"
}

# Get possible test paths for the distribution (returns array)
get_test_paths() {
    local distro="$DISTRO_ID"
    local version="$DISTRO_VERSION"
    local codename="${DISTRO_CODENAME:-$version}"
    local arch="$ARCH"
    local paths=()

    case "$distro" in
        ubuntu|debian|kali|linuxmint)
            paths+=("/dists/${codename}/InRelease")
            paths+=("/dists/${codename}/Release")
            ;;
        fedora)
            paths+=("/linux/releases/${version}/Everything/${arch}/os/repodata/repomd.xml")
            paths+=("/releases/${version}/Everything/${arch}/os/repodata/repomd.xml")
            paths+=("/fedora/linux/releases/${version}/Everything/${arch}/os/repodata/repomd.xml")
            paths+=("/fedora/releases/${version}/Everything/${arch}/os/repodata/repomd.xml")
            paths+=("/pub/fedora/linux/releases/${version}/Everything/${arch}/os/repodata/repomd.xml")
            paths+=("/linux/${version}/os/repodata/repomd.xml")
            paths+=("/releases/${version}/os/repodata/repomd.xml")
            paths+=("/repodata/repomd.xml")
            ;;
        centos|rhel|almalinux|rocky)
            paths+=("/${version}/os/${arch}/repodata/repomd.xml")
            paths+=("/pub/centos/${version}/os/${arch}/repodata/repomd.xml")
            paths+=("/centos/${version}/os/${arch}/repodata/repomd.xml")
            paths+=("/repodata/repomd.xml")
            ;;
        arch|blackarch)
            paths+=("/core/os/${arch}/core.db")
            ;;
        opensuse*)
            paths+=("/repodata/repomd.xml")
            ;;
        *)
            paths+=("/")
            ;;
    esac
    printf '%s\n' "${paths[@]}"
}

# Get possible large test paths for speed measurement
get_large_test_paths() {
    local distro="$DISTRO_ID"
    local version="$DISTRO_VERSION"
    local codename="${DISTRO_CODENAME:-$version}"
    local arch="$ARCH"
    local paths=()

    case "$distro" in
        ubuntu|debian|kali|linuxmint)
            paths+=("/dists/${codename}/main/binary-${arch}/Packages.gz")
            paths+=("/dists/${codename}/main/binary-${arch}/Packages.xz")
            ;;
        fedora)
            paths+=("/linux/releases/${version}/Everything/${arch}/os/repodata/primary.xml.gz")
            paths+=("/releases/${version}/Everything/${arch}/os/repodata/primary.xml.gz")
            paths+=("/fedora/linux/releases/${version}/Everything/${arch}/os/repodata/primary.xml.gz")
            paths+=("/fedora/releases/${version}/Everything/${arch}/os/repodata/primary.xml.gz")
            paths+=("/pub/fedora/linux/releases/${version}/Everything/${arch}/os/repodata/primary.xml.gz")
            paths+=("/linux/${version}/os/repodata/primary.xml.gz")
            paths+=("/releases/${version}/os/repodata/primary.xml.gz")
            ;;
        centos|rhel|almalinux|rocky)
            paths+=("/${version}/os/${arch}/repodata/primary.xml.gz")
            paths+=("/pub/centos/${version}/os/${arch}/repodata/primary.xml.gz")
            paths+=("/centos/${version}/os/${arch}/repodata/primary.xml.gz")
            ;;
        arch|blackarch)
            paths+=("/core/os/${arch}/core.db")
            ;;
        *)
            paths+=("/")
            ;;
    esac
    printf '%s\n' "${paths[@]}"
}

# Test a single mirror: tries multiple paths until one works
test_mirror() {
    local base_url="$1"
    local test_paths=($(get_test_paths))
    local large_paths=($(get_large_test_paths))

    local curl_opts="-4 -L --connect-timeout $TIMEOUT --max-time 12 -s"
    local http_code time_total latency_ms speed_kb=0 last_epoch=0 found=false success_path=""

    # Try each small test path
    for test_path in "${test_paths[@]}"; do
        local full_url="${base_url}${test_path}"
        http_code=$(curl $curl_opts -o /dev/null -I -w "%{http_code}" "$full_url" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" || "$http_code" == "206" ]]; then
            found=true
            success_path="$test_path"
            # Get last-modified header
            local last_modified
            last_modified=$(curl $curl_opts -I "$full_url" 2>/dev/null | grep -i last-modified | head -1 | sed 's/.*: //' | tr -d '\r')
            if [[ -n "$last_modified" ]]; then
                last_epoch=$(date -d "$last_modified" +%s 2>/dev/null || echo 0)
            fi
            # Measure latency
            time_total=$(curl $curl_opts -o /dev/null -w "%{time_total}" "$full_url" 2>/dev/null || echo "0")
            latency_ms=$(awk "BEGIN {printf \"%.0f\", $time_total * 1000}")
            break
        fi
    done

    if ! $found; then
        echo "FAIL|unreachable"
        return
    fi

    # Try to measure speed using a large file
    for large_path in "${large_paths[@]}"; do
        local full_url="${base_url}${large_path}"
        local stats
        stats=$(curl $curl_opts --range 0-2097152 -w "%{time_total} %{size_download} %{http_code}" -o /dev/null "$full_url" 2>/dev/null || echo "0 0 000")
        local time_large=$(echo "$stats" | awk '{print $1}')
        local size_large=$(echo "$stats" | awk '{print $2}')
        local code=$(echo "$stats" | awk '{print $3}')

        if [[ "$code" == "200" || "$code" == "206" ]] && (( $(echo "$size_large > 1000" | awk '{print ($1>1000)}') )); then
            speed_kb=$(awk "BEGIN {printf \"%.0f\", $size_large / $time_large / 1024}")
            break
        fi
    done

    # Fallback to small file speed
    if (( speed_kb == 0 )); then
        local small_stats
        small_stats=$(curl $curl_opts -w "%{time_total} %{size_download}" -o /dev/null "${base_url}${success_path}" 2>/dev/null || echo "0 0")
        local time_small=$(echo "$small_stats" | awk '{print $1}')
        local size_small=$(echo "$small_stats" | awk '{print $2}')
        if (( $(echo "$time_small > 0.01" | awk '{print ($1>0.01)}') )); then
            speed_kb=$(awk "BEGIN {printf \"%.0f\", $size_small / $time_small / 1024}")
        fi
    fi

    echo "OK|$latency_ms|$speed_kb|$last_epoch|$success_path"
}

calculate_score() {
    local lat="$1"
    local spd="$2"
    if (( spd < 1 )); then spd=1; fi
    awk "BEGIN {printf \"%.2f\", ($lat * 0.6) + (100000 / $spd * 0.4)}"
}

# Backup current repository configuration
backup_repo() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_path="$BACKUP_DIR/backup-$timestamp"
    mkdir -p "$backup_path"
    
    case "$DISTRO_ID" in
        ubuntu|debian|kali|linuxmint)
            if [[ -f /etc/apt/sources.list ]]; then
                cp /etc/apt/sources.list "$backup_path/sources.list"
            fi
            if [[ -d /etc/apt/sources.list.d ]]; then
                cp -r /etc/apt/sources.list.d "$backup_path/"
            fi
            if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
                cp /etc/apt/sources.list.d/ubuntu.sources "$backup_path/ubuntu.sources"
            fi
            ;;
        fedora|centos|rhel|almalinux|rocky)
            if [[ -d /etc/yum.repos.d ]]; then
                cp -r /etc/yum.repos.d "$backup_path/"
            fi
            ;;
        arch|blackarch)
            if [[ -f /etc/pacman.d/mirrorlist ]]; then
                cp /etc/pacman.d/mirrorlist "$backup_path/mirrorlist"
            fi
            ;;
    esac
    
    echo "$backup_path"
}

# Restore from backup
restore_repo() {
    local backups=()
    while IFS= read -r -d '' dir; do
        backups+=("$dir")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type d -name "backup-*" -print0 | sort -r)
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No backups found in $BACKUP_DIR${NC}"
        return
    fi
    
    echo -e "${BLUE}Available backups:${NC}"
    local i=1
    for b in "${backups[@]}"; do
        echo "$i) $(basename "$b")"
        ((i++))
    done
    echo ""
    read -r -p "Enter backup number to restore (or 'q' to quit): " choice
    if [[ "$choice" == "q" ]]; then return; fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#backups[@]} )); then
        echo -e "${RED}Invalid choice${NC}"
        return
    fi
    
    local selected="${backups[$((choice-1))]}"
    echo -e "${YELLOW}Restoring from $(basename "$selected")...${NC}"
    
    local pre_restore_backup=$(backup_repo)
    echo -e "Current state backed up to $pre_restore_backup"
    
    case "$DISTRO_ID" in
        ubuntu|debian|kali|linuxmint)
            if [[ -f "$selected/sources.list" ]]; then
                sudo cp "$selected/sources.list" /etc/apt/sources.list
            fi
            if [[ -d "$selected/sources.list.d" ]]; then
                sudo cp -r "$selected/sources.list.d"/* /etc/apt/sources.list.d/ 2>/dev/null || true
            fi
            if [[ -f "$selected/ubuntu.sources" ]]; then
                sudo cp "$selected/ubuntu.sources" /etc/apt/sources.list.d/ubuntu.sources
            fi
            sudo apt-get update
            ;;
        fedora|centos|rhel|almalinux|rocky)
            if [[ -d "$selected/yum.repos.d" ]]; then
                sudo cp -r "$selected/yum.repos.d"/* /etc/yum.repos.d/ 2>/dev/null || true
            fi
            sudo dnf clean all
            sudo dnf makecache
            ;;
        arch|blackarch)
            if [[ -f "$selected/mirrorlist" ]]; then
                sudo cp "$selected/mirrorlist" /etc/pacman.d/mirrorlist
            fi
            sudo pacman -Sy
            ;;
    esac
    echo -e "${GREEN}Restore completed.${NC}"
}

# Get repository base URL from success_path
get_repo_base() {
    local base_url="$1"
    local success_path="$2"
    local distro="$DISTRO_ID"
    
    if [[ -z "$success_path" ]]; then
        echo "$base_url"
        return
    fi
    
    if [[ "$distro" =~ (ubuntu|debian|kali|linuxmint) ]]; then
        echo "$base_url"
        return
    fi
    
    if [[ "$distro" == "fedora" ]]; then
        local base="${success_path%/repodata/*}"
        if [[ -n "$base" ]]; then
            echo "${base_url}${base}"
            return
        fi
    fi
    
    if [[ "$distro" =~ (centos|rhel|almalinux|rocky) ]]; then
        local base="${success_path%/repodata/*}"
        if [[ -n "$base" ]]; then
            echo "${base_url}${base}"
            return
        fi
    fi
    
    echo "$base_url"
}

# Apply selected mirror to system
apply_repo() {
    local selected_url="$1"
    local success_path="$2"
    
    local backup_path=$(backup_repo)
    echo -e "${GREEN}Backup saved to: $backup_path${NC}"
    
    local repo_base
    repo_base=$(get_repo_base "$selected_url" "$success_path")
    echo -e "${BLUE}Using repo base: ${YELLOW}$repo_base${NC}"
    
    case "$DISTRO_ID" in
        ubuntu|debian|kali|linuxmint)
            local codename="${DISTRO_CODENAME:-$DISTRO_VERSION}"
            local keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
            if [[ ! -f "$keyring" && "$DISTRO_ID" == "debian" ]]; then
                keyring="/usr/share/keyrings/debian-archive-keyring.gpg"
            fi
            
            # Clear /etc/apt/sources.list.d/ (optional)
            sudo rm -f /etc/apt/sources.list.d/*.list 2>/dev/null || true
            sudo rm -f /etc/apt/sources.list.d/*.sources 2>/dev/null || true
            
            # Write legacy sources.list with signed-by option to avoid warnings after modernize-sources
            {
                echo "# Generated by Iran Repo Manager on $(date)"
                echo "deb [signed-by=$keyring] $repo_base $codename main restricted universe multiverse"
                echo "deb [signed-by=$keyring] $repo_base $codename-updates main restricted universe multiverse"
                echo "deb [signed-by=$keyring] $repo_base $codename-security main restricted universe multiverse"
                echo "deb [signed-by=$keyring] $repo_base $codename-backports main restricted universe multiverse"
            } | sudo tee /etc/apt/sources.list > /dev/null
            
            # Run apt modernize-sources if available (Ubuntu)
            if command -v apt &>/dev/null && apt modernize-sources --help &>/dev/null; then
                echo -e "${BLUE}Running apt modernize-sources...${NC}"
                sudo apt modernize-sources -y
            fi
            
            sudo apt-get update -o Acquire::Retries=3
            ;;
        
        fedora)
            local releasever="$DISTRO_VERSION"
            local basearch="$ARCH"
            local final_base="${repo_base//\$releasever/$releasever}"
            final_base="${final_base//\$basearch/$basearch}"
            
            for repo in fedora fedora-updates; do
                if [ -f "/etc/yum.repos.d/${repo}.repo" ]; then
                    sudo cp "/etc/yum.repos.d/${repo}.repo" "/etc/yum.repos.d/${repo}.repo.backup" 2>/dev/null || true
                    sudo sed -i "s|^metalink=|#metalink=|g" "/etc/yum.repos.d/${repo}.repo"
                    sudo sed -i "s|^baseurl=.*|baseurl=${final_base}|g" "/etc/yum.repos.d/${repo}.repo"
                fi
            done
            sudo dnf clean all
            sudo dnf makecache
            ;;
        
        centos|rhel|almalinux|rocky)
            local releasever="$DISTRO_VERSION"
            local basearch="$ARCH"
            local final_base="${repo_base//\$releasever/$releasever}"
            final_base="${final_base//\$basearch/$basearch}"
            
            local repo_files=()
            if [[ -f /etc/yum.repos.d/CentOS-Base.repo ]]; then
                repo_files+=("/etc/yum.repos.d/CentOS-Base.repo")
            else
                while IFS= read -r f; do
                    repo_files+=("$f")
                done < <(grep -l "baseurl" /etc/yum.repos.d/*.repo 2>/dev/null || true)
            fi
            
            for repo_file in "${repo_files[@]}"; do
                sudo cp "$repo_file" "${repo_file}.backup" 2>/dev/null || true
                sudo sed -i "s|^mirrorlist=|#mirrorlist=|g" "$repo_file"
                sudo sed -i "s|^baseurl=.*|baseurl=${final_base}|g" "$repo_file"
            done
            sudo dnf clean all
            sudo dnf makecache
            ;;
        
        arch|blackarch)
            sudo cp /etc/pacman.d/mirrorlist "/etc/pacman.d/mirrorlist.backup" 2>/dev/null || true
            echo "Server = $repo_base/\$repo/os/\$arch" | sudo tee /etc/pacman.d/mirrorlist > /dev/null
            sudo pacman -Sy
            ;;
        
        *)
            echo -e "${RED}Unsupported distribution: $DISTRO_ID${NC}"
            return 1
            ;;
    esac
    
    echo -e "${GREEN}Mirror applied successfully!${NC}"
}

# ------------------------------
# Scanning and ranking
# ------------------------------
scan_mirrors() {
    RESULTS=()
    local total=${#MIRRORS[@]}
    local tested=0
    local skip_requested=false

    echo -e "${CYAN}Scanning $total mirrors...${NC}"
    echo -e "${YELLOW}Press ENTER at any time to skip the current mirror.${NC}\n"

    setup_terminal
    trap 'restore_terminal' EXIT INT TERM

    for raw_url in "${MIRRORS[@]}"; do
        tested=$((tested + 1))
        skip_requested=false
        if check_enter; then
            skip_requested=true
        fi

        local url
        url=$(expand_url "$raw_url")
        echo -ne "[${tested}/${total}] Testing ${YELLOW}$url${NC} ... "

        if grep -qFx "$url" "$BLACKLIST" 2>/dev/null; then
            echo -e "${YELLOW}blacklisted${NC}"
            continue
        fi

        if $skip_requested; then
            echo -e "${YELLOW}skipped by user${NC}"
            continue
        fi

        local test_result
        test_result=$(test_mirror "$url" 2>/dev/null || echo "FAIL|unknown")
        
        if [[ "$test_result" == FAIL\|* ]]; then
            local reason="${test_result#FAIL|}"
            echo -e "${RED}FAIL ($reason)${NC}"
            continue
        fi

        IFS='|' read -r status latency_ms speed_kb last_epoch success_path <<< "$test_result"
        local score
        score=$(calculate_score "$latency_ms" "$speed_kb")
        echo -e "${GREEN}OK${NC} | ${latency_ms}ms | ${speed_kb} KB/s | score=${score}"
        RESULTS+=("$score|$latency_ms|$speed_kb|$last_epoch|$success_path|$url")
    done

    restore_terminal
    trap - EXIT INT TERM
}

rank_mirrors() {
    if [[ ${#RESULTS[@]} -eq 0 ]]; then
        echo -e "${RED}No working mirrors found.${NC}"
        return
    fi

    mapfile -t SORTED_RESULTS < <(printf '%s\n' "${RESULTS[@]}" | sort -t'|' -k1,1n)

    echo -e "\n${BLUE}==============================${NC}"
    echo -e "${BLUE}Mirror ranking (best first):${NC}"
    echo -e "${BLUE}==============================${NC}"

    local i=1
    for entry in "${SORTED_RESULTS[@]}"; do
        IFS='|' read -r score lat spd last_epoch success_path url <<< "$entry"
        local last_str="unknown"
        if [[ "$last_epoch" -gt 0 ]]; then
            last_str=$(date -d "@$last_epoch" "+%Y-%m-%d" 2>/dev/null || echo "unknown")
        fi
        echo -e "${YELLOW}$i.${NC} ${GREEN}$url${NC}"
        echo -e "   Score: ${CYAN}$score${NC} | Latency: ${lat}ms | Speed: ${spd} KB/s | Last: ${last_str}"
        ((i++))
    done
    echo ""
}

# ------------------------------
# Main menu
# ------------------------------
main_menu() {
    while true; do
        # Clear screen for better visibility (optional)
        # clear
        echo -e "\e[35m======================================\e[0m"
        echo -e "\e[32m||     >>> IR REPO MANAGER <<<      ||\e[0m"
        echo -e "\e[31m||         Script by \e[0mSiaMia\e[31m         ||\e[0m"
        echo -e "\e[35m======================================\e[0m"
        echo ""
        echo "Detected: $DISTRO_ID $DISTRO_VERSION ${DISTRO_CODENAME:+($DISTRO_CODENAME)}"
        echo ""
        echo "1) Scan and auto-select best mirror"
        echo "2) Scan and choose manually"
        echo "3) List all mirrors"
        echo "4) Manage blacklist"
        echo "5) Restore from backup"
        echo "6) Exit"
        echo ""
        read -r -p "Choose an option: " opt

        case $opt in
            1)
                scan_mirrors
                rank_mirrors
                if [[ ${#SORTED_RESULTS[@]} -eq 0 ]]; then
                    echo -e "${RED}No mirror selected.${NC}"
                    continue
                fi
                IFS='|' read -r score lat spd last_epoch success_path best_url <<< "${SORTED_RESULTS[0]}"
                echo -e "${GREEN}Auto-selected:${NC} $best_url"
                read -r -p "Apply this mirror? (y/N) " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    apply_repo "$best_url" "$success_path"
                fi
                ;;
            2)
                scan_mirrors
                rank_mirrors
                if [[ ${#SORTED_RESULTS[@]} -eq 0 ]]; then
                    echo -e "${RED}No mirrors available.${NC}"
                    continue
                fi
                echo "Enter the number of the mirror to select (1-${#SORTED_RESULTS[@]}), or 'q' to quit:"
                read -r -p "> " choice
                if [[ "$choice" == "q" ]]; then break; fi
                if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#SORTED_RESULTS[@]} )); then
                    echo -e "${RED}Invalid choice.${NC}"
                    continue
                fi
                idx=$((choice - 1))
                IFS='|' read -r score lat spd last_epoch success_path selected_url <<< "${SORTED_RESULTS[$idx]}"
                echo -e "${GREEN}Selected:${NC} $selected_url"
                read -r -p "Apply this mirror? (y/N) " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    apply_repo "$selected_url" "$success_path"
                fi
                ;;
            3)
                echo -e "${CYAN}Available mirrors (placeholders):${NC}"
                for i in "${!MIRRORS[@]}"; do
                    echo "$((i+1))) ${MIRRORS[$i]}"
                done
                ;;
            4)
                echo -e "${BLUE}Blacklist Manager${NC}"
                if [[ ! -s "$BLACKLIST" ]]; then
                    echo -e "${YELLOW}Blacklist is empty.${NC}"
                else
                    echo "Current blacklisted mirrors:"
                    cat "$BLACKLIST"
                fi
                read -r -p "Clear blacklist? (y/N) " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    > "$BLACKLIST"
                    echo -e "${GREEN}Blacklist cleared.${NC}"
                fi
                ;;
            5)
                restore_repo
                ;;
            6)
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                ;;
        esac
    done
}

load_mirrors() {
    if [[ ! -f "$MIRROR_FILE" ]]; then
        echo -e "${RED}mirrors.list not found in $SCRIPT_DIR${NC}"
        exit 1
    fi
    mapfile -t MIRRORS < <(grep -v '^#' "$MIRROR_FILE" | grep -v '^[[:space:]]*$')
}

# ------------------------------
# Entry point
# ------------------------------
detect_distro
load_mirrors

if [[ $# -eq 0 ]]; then
    main_menu
else
    case "$1" in
        scan)
            scan_mirrors
            rank_mirrors
            ;;
        list)
            load_mirrors
            for i in "${!MIRRORS[@]}"; do
                url=$(expand_url "${MIRRORS[$i]}")
                echo "$((i+1))) $url"
            done
            ;;
        auto)
            scan_mirrors
            rank_mirrors
            if [[ ${#SORTED_RESULTS[@]} -gt 0 ]]; then
                IFS='|' read -r score lat spd last_epoch success_path best_url <<< "${SORTED_RESULTS[0]}"
                echo -e "${GREEN}Best mirror:${NC} $best_url"
                apply_repo "$best_url" "$success_path"
            else
                echo -e "${RED}No working mirror found.${NC}"
            fi
            ;;
        *)
            echo "Usage: $0 [scan|list|auto]"
            ;;
    esac
fi