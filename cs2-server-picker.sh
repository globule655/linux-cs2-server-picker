#!/bin/bash

# CS2 Server Picker for Linux
# Blocks CS2 server relay IP addresses using iptables
# Rules are non-persistent and will be cleared on reboot

set -eo pipefail

# Configuration
STEAM_API_URL="https://api.steampowered.com/ISteamApps/GetSDRConfig/v1/?appid=730"
CHAIN_NAME="CS2_SERVER_BLOCK"
CACHE_FILE="/tmp/cs2_servers.json"
STATE_FILE="/tmp/cs2_blocked_servers.txt"
LATENCY_CACHE_FILE="/tmp/cs2_latencies.cache"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
ORANGE='\033[38;5;208m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Associative array for latency cache
declare -A LATENCY_CACHE

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root (use sudo)${NC}"
        exit 1
    fi
}

# Check required dependencies
check_dependencies() {
    local deps=("curl" "jq" "iptables")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required dependencies: ${missing[*]}${NC}"
        echo "Install with: sudo apt install ${missing[*]} (Debian/Ubuntu)"
        echo "          or: sudo dnf install ${missing[*]} (Fedora/RHEL)"
        echo "          or: sudo pacman -S ${missing[*]} (Arch)"
        exit 1
    fi
}

# Initialize iptables chain
init_chain() {
    # Create chain if it doesn't exist
    if ! iptables -L "$CHAIN_NAME" -n &> /dev/null; then
        echo -e "${BLUE}Creating iptables chain: $CHAIN_NAME${NC}"
        iptables -N "$CHAIN_NAME"
        iptables -I OUTPUT 1 -j "$CHAIN_NAME"
    fi
}

# Fetch server data from Steam API
fetch_server_data() {
    echo -e "${BLUE}Fetching server data from Steam API...${NC}"
    
    if ! curl -s -o "$CACHE_FILE" "$STEAM_API_URL"; then
        echo -e "${RED}Error: Failed to fetch server data${NC}"
        exit 1
    fi
    
    if ! jq empty "$CACHE_FILE" 2>/dev/null; then
        echo -e "${RED}Error: Invalid JSON response from Steam API${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Server data fetched successfully${NC}"
}

# Parse server locations and IPs
parse_servers() {
    jq -r '.pops | to_entries[] | select(.value.relays != null) | 
        .key as $code | 
        .value.desc as $desc | 
        .value.relays[].ipv4 as $ip | 
        "\($desc) (\($code))|\($ip)"' "$CACHE_FILE" | sort -u > /tmp/cs2_servers_parsed.txt
}

# Get list of unique locations
get_locations() {
    jq -r '.pops | to_entries[] | select(.value.relays != null) | 
        "\(.value.desc) (\(.key))"' "$CACHE_FILE" | sort -u
}

# Get IPs for a specific location
get_ips_for_location() {
    local location="$1"
    local code=$(echo "$location" | grep -oP '\(([^)]+)\)$' | tr -d '()')
    
    jq -r --arg code "$code" \
        '.pops[$code].relays[]?.ipv4' "$CACHE_FILE" 2>/dev/null || true
}

# Get locations that are currently blocked
get_blocked_locations() {
    if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]] && [[ -f /tmp/cs2_servers_parsed.txt ]]; then
        while IFS= read -r ip; do
            grep "|${ip}$" /tmp/cs2_servers_parsed.txt 2>/dev/null | head -n 1 | cut -d'|' -f1
        done < "$STATE_FILE" | sort -u
    fi
}

# Measure latency for a single IP
measure_single_latency() {
    local ip="$1"
    
    # Ping with 3 packets, 2 second timeout
    local ping_result=$(ping -c 3 -W 2 "$ip" 2>/dev/null | grep 'avg' | awk -F'/' '{print $5}')
    
    if [[ -n "$ping_result" ]]; then
        # Round to nearest integer (LC_NUMERIC=C ensures '.' is recognized as decimal separator)
        LC_NUMERIC=C printf "%.0f" "$ping_result"
    else
        echo "999"  # Return high value for unreachable servers
    fi
}

# Get latency color based on value
get_latency_color() {
    local latency="$1"
    
    if [[ "$latency" == "N/A" ]] || [[ "$latency" -ge 999 ]]; then
        echo "$RED"
    elif [[ "$latency" -le 24 ]]; then
        echo "$GREEN"
    elif [[ "$latency" -le 60 ]]; then
        echo "$YELLOW"
    elif [[ "$latency" -le 99 ]]; then
        echo "$ORANGE"
    else
        echo "$RED"
    fi
}

# Format latency display
format_latency() {
    local latency="$1"
    
    if [[ "$latency" -ge 999 ]]; then
        echo "N/A"
    else
        echo "${latency}ms"
    fi
}

# Load latency cache from file
load_latency_cache() {
    if [[ -f "$LATENCY_CACHE_FILE" ]]; then
        while IFS='=' read -r location latency; do
            [[ -n "$location" ]] && LATENCY_CACHE["$location"]="$latency"
        done < "$LATENCY_CACHE_FILE"
    fi
}

# Save latency cache to file
save_latency_cache() {
    > "$LATENCY_CACHE_FILE"
    for location in "${!LATENCY_CACHE[@]}"; do
        echo "$location=${LATENCY_CACHE[$location]}" >> "$LATENCY_CACHE_FILE"
    done
}

# Measure latency for all locations
measure_all_latencies() {
    local -n locations_ref=$1
    
    echo -e "${BLUE}Measuring latency for all server locations...${NC}"
    echo ""
    
    local total=${#locations_ref[@]}
    local current=0
    
    for location in "${locations_ref[@]}"; do
        current=$((current + 1))
        
        # Get first IP for this location
        local first_ip=$(get_ips_for_location "$location" | head -n 1)
        
        if [[ -n "$first_ip" ]]; then
            echo -ne "[$current/$total] Testing $location... "
            
            local latency=$(measure_single_latency "$first_ip")
            LATENCY_CACHE["$location"]="$latency"
            
            local color=$(get_latency_color "$latency")
            local display=$(format_latency "$latency")
            echo -e "${color}${display}${NC}"
        else
            LATENCY_CACHE["$location"]="999"
            echo -e "${RED}No IPs found${NC}"
        fi
    done
    
    # Save cache
    save_latency_cache
    
    echo ""
    echo -e "${GREEN}Latency measurement complete!${NC}"
    echo ""
    read -p "Press Enter to continue..."
}

# Show interactive checklist menu
show_checklist() {
    local -n locations_ref=$1
    local -n selected_ref=$2
    
    while true; do
        clear
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}    CS2 Server Picker - Select Locations to Block${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "Use number to toggle, 'a' for all, 'n' for none, 'd' when done"
        echo ""
        
        local idx=1
        for location in "${locations_ref[@]}"; do
            local marker=" "
            if [[ " ${selected_ref[*]} " =~ " ${location} " ]]; then
                marker="✓"
            fi
            
            # Get latency info
            local latency="${LATENCY_CACHE[$location]:-999}"
            local latency_color=$(get_latency_color "$latency")
            local latency_display=$(format_latency "$latency")
            
            echo -e "${GREEN}[$marker]${NC} $idx. $location - ${latency_color}${latency_display}${NC}"
            idx=$((idx + 1))
        done
        
        echo ""
        echo -e "${YELLOW}Currently blocked: $(count_blocked_ips) IPs${NC}"
        echo ""
        read -p "Choice: " choice
        
        case "$choice" in
            [0-9]*)
                if [[ $choice -ge 1 && $choice -le ${#locations_ref[@]} ]]; then
                    local selected_location="${locations_ref[$((choice-1))]}"
                    
                    # Toggle selection
                    if [[ " ${selected_ref[*]} " =~ " ${selected_location} " ]]; then
                        # Remove from selection
                        selected_ref=("${selected_ref[@]/$selected_location}")
                    else
                        # Add to selection
                        selected_ref+=("$selected_location")
                    fi
                fi
                ;;
            a|A)
                selected_ref=("${locations_ref[@]}")
                ;;
            n|N)
                selected_ref=()
                ;;
            d|D)
                break
                ;;
        esac
    done
}

# Count currently blocked IPs
count_blocked_ips() {
    iptables -L "$CHAIN_NAME" -n 2>/dev/null | grep -c "^DROP" || echo "0"
}

# Apply iptables rules
apply_rules() {
    local -n selected_locations=$1
    
    echo -e "${BLUE}Applying iptables rules...${NC}"
    
    # Get current state
    local -a current_blocked=()
    if [[ -f "$STATE_FILE" ]]; then
        mapfile -t current_blocked < "$STATE_FILE"
    fi
    
    # Collect new IPs to block
    local -a new_ips=()
    for location in "${selected_locations[@]}"; do
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && new_ips+=("$ip")
        done < <(get_ips_for_location "$location")
    done
    
    # Remove duplicates
    local -a unique_new_ips=($(printf "%s\n" "${new_ips[@]}" | sort -u))
    
    # Find IPs to unblock (in current but not in new)
    local -a to_unblock=()
    for ip in "${current_blocked[@]}"; do
        if [[ ! " ${unique_new_ips[*]} " =~ " ${ip} " ]]; then
            to_unblock+=("$ip")
        fi
    done
    
    # Find IPs to block (not currently in iptables)
    local -a to_block=()
    for ip in "${unique_new_ips[@]}"; do
        if ! iptables -C "$CHAIN_NAME" -d "$ip" -j DROP 2>/dev/null; then
            to_block+=("$ip")
        fi
    done
    
    # Unblock IPs
    if [[ ${#to_unblock[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Unblocking ${#to_unblock[@]} IP(s)...${NC}"
        for ip in "${to_unblock[@]}"; do
            iptables -D "$CHAIN_NAME" -d "$ip" -j DROP 2>/dev/null || true
            echo "  - Unblocked: $ip"
        done
    fi
    
    # Block IPs
    if [[ ${#to_block[@]} -gt 0 ]]; then
        echo -e "${GREEN}Blocking ${#to_block[@]} IP(s)...${NC}"
        for ip in "${to_block[@]}"; do
            if ! iptables -C "$CHAIN_NAME" -d "$ip" -j DROP 2>/dev/null; then
                iptables -A "$CHAIN_NAME" -d "$ip" -j DROP
                echo "  + Blocked: $ip"
            fi
        done
    fi
    
    # Save state
    printf "%s\n" "${unique_new_ips[@]}" > "$STATE_FILE"
    
    echo -e "${GREEN}Done! Total blocked IPs: ${#unique_new_ips[@]}${NC}"
}

# Show current blocked servers
show_blocked() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    Currently Blocked IPs${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
        # Ensure we have server data to look up locations
        if [[ ! -f "$CACHE_FILE" ]] || [[ ! -f /tmp/cs2_servers_parsed.txt ]]; then
            echo -e "${YELLOW}Fetching server data for location lookup...${NC}"
            fetch_server_data
            parse_servers
        fi
        
        local idx=1
        while IFS= read -r ip; do
            # Look up location for this IP
            local location=$(grep "|${ip}$" /tmp/cs2_servers_parsed.txt 2>/dev/null | head -n 1 | cut -d'|' -f1)
            if [[ -n "$location" ]]; then
                printf "%4d. %-15s  %s\n" "$idx" "$ip" "$location"
            else
                printf "%4d. %-15s  ${YELLOW}(Unknown location)${NC}\n" "$idx" "$ip"
            fi
            idx=$((idx + 1))
        done < "$STATE_FILE"
        
        echo ""
        echo -e "${YELLOW}Total: $(wc -l < "$STATE_FILE") IP(s) blocked${NC}"
    else
        echo -e "${YELLOW}No IPs currently blocked${NC}"
    fi
    echo ""
}

# Clear all rules
clear_all_rules() {
    echo -e "${YELLOW}Clearing all CS2 server blocks...${NC}"
    
    # Flush the chain
    iptables -F "$CHAIN_NAME" 2>/dev/null || true
    
    # Remove state file
    rm -f "$STATE_FILE"
    
    echo -e "${GREEN}All rules cleared${NC}"
}

# Remove chain completely
remove_chain() {
    echo -e "${YELLOW}Removing CS2 server picker iptables chain...${NC}"
    
    # Remove jump rule from OUTPUT
    iptables -D OUTPUT -j "$CHAIN_NAME" 2>/dev/null || true
    
    # Flush and delete chain
    iptables -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -X "$CHAIN_NAME" 2>/dev/null || true
    
    # Remove state file
    rm -f "$STATE_FILE"
    
    echo -e "${GREEN}Chain removed${NC}"
}

# Main menu
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}    CS2 Server Picker for Linux${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "1. Block/Unblock servers (interactive selection)"
        echo "2. Show currently blocked servers"
        echo "3. Refresh latency measurements"
        echo "4. Clear all blocks"
        echo "5. Remove chain and exit"
        echo "6. Exit"
        echo ""
        read -p "Choice: " choice
        
        case "$choice" in
            1)
                fetch_server_data
                parse_servers
                
                # Get locations
                mapfile -t locations < <(get_locations)
                
                # Load cached latencies
                load_latency_cache
                
                # Measure latencies if cache is empty or stale
                if [[ ${#LATENCY_CACHE[@]} -eq 0 ]]; then
                    measure_all_latencies locations
                fi
                
                # Get currently selected locations from state
                local -a selected=()
                mapfile -t selected < <(get_blocked_locations)
                
                show_checklist locations selected
                apply_rules selected
                
                read -p "Press Enter to continue..."
                ;;
            2)
                show_blocked
                read -p "Press Enter to continue..."
                ;;
            3)
                fetch_server_data
                parse_servers
                
                # Get locations
                mapfile -t locations < <(get_locations)
                
                # Clear cache and remeasure
                unset LATENCY_CACHE
                declare -gA LATENCY_CACHE
                rm -f "$LATENCY_CACHE_FILE"
                measure_all_latencies locations
                ;;
            4)
                clear_all_rules
                read -p "Press Enter to continue..."
                ;;
            5)
                remove_chain
                exit 0
                ;;
            6)
                exit 0
                ;;
        esac
    done
}

# Main execution
main() {
    check_root
    check_dependencies
    init_chain
    main_menu
}

main "$@"
