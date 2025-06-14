#!/bin/bash
# ==============================================================================
# Automated Huge Pages Configuration Script (v2)
# ==============================================================================
#
# Description:
# This script automatically calculates the required number of Huge Pages for
# MariaDB/MySQL and a specific PHP version's OPcache, then creates a system
# configuration file to apply these settings on boot.
#
# Usage:
#   sudo ./setup_hugepages.sh <php_version>
#   Example: sudo ./setup_hugepages.sh php83
#
# Author: Boris Lucas
# Date: June 15, 2025
#
# ==============================================================================

# --- Function to display messages ---
log() {
    echo "[INFO] $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# --- Permission Check ---
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run with root privileges. Please use sudo."
fi

# --- Argument Check for PHP Version ---
if [ -z "$1" ]; then
    echo "[ERROR] Missing PHP version argument."
    echo ""
    echo "Usage: sudo $0 <php_version>"
    echo "Example: sudo $0 php83"
    echo ""
    AVAILABLE_VERSIONS=$(for dir in /usr/local/lsws/lsphp*; do if [ -d "$dir" ]; then basename "$dir" | sed 's/ls//'; fi; done | tr '\n' ' ')
    if [ -n "$AVAILABLE_VERSIONS" ]; then
        echo "Detected available PHP versions: ${AVAILABLE_VERSIONS}"
    else
        echo "No OpenLiteSpeed PHP versions found in /usr/local/lsws/"
    fi
    exit 1
fi

PHP_TARGET_VERSION_SHORT=${1#php} # Extracts '83' from 'php83'
PHP_INI_PATH="/usr/local/lsws/lsphp${PHP_TARGET_VERSION_SHORT}/etc/php.ini"

if [ ! -f "$PHP_INI_PATH" ]; then
    error "PHP configuration file not found at '$PHP_INI_PATH'. Please check the version name and ensure it's an OLS PHP version."
fi


# --- Find MariaDB/MySQL configuration file ---
MY_CNF="/etc/my.cnf"
if [ ! -f "$MY_CNF" ]; then
    error "MariaDB/MySQL configuration file not found at $MY_CNF. Please ensure MariaDB is installed."
fi

# --- Function to parse memory values (e.g., 8G, 8192M, 1024K) and convert to MB ---
parse_memory_to_mb() {
    local mem_value=$1
    # Return 0 if input is empty or just a unit
    if [[ -z "$mem_value" ]] || [[ "$mem_value" =~ ^[a-zA-Z]+$ ]]; then
        echo 0
        return
    fi
    local value=${mem_value//[^0-9]/}
    local unit=${mem_value//[0-9]/}

    unit=$(echo "$unit" | tr '[:lower:]' '[:upper:]')

    case "$unit" in
        G|GB)
            echo $((value * 1024))
            ;;
        M|MB)
            echo $value
            ;;
        K|KB)
            echo $((value / 1024))
            ;;
        *)
            # If no unit, assume it's in bytes for sysctl values, but here we expect MB from PHP config
            # Defaulting to the value itself assuming it might be in MB without a suffix.
            echo $value
            ;;
    esac
}

# --- Get MariaDB InnoDB Buffer Pool Size ---
log "Reading MariaDB configuration from $MY_CNF..."
INNODB_BUFFER_POOL_SIZE_RAW=$(grep -E "^innodb_buffer_pool_size" "$MY_CNF" | awk -F'=' '{print $2}' | tr -d '[:space:]')

if [ -z "$INNODB_BUFFER_POOL_SIZE_RAW" ]; then
    error "Could not find 'innodb_buffer_pool_size' in $MY_CNF."
fi

INNODB_BUFFER_POOL_MB=$(parse_memory_to_mb "$INNODB_BUFFER_POOL_SIZE_RAW")
log "Detected InnoDB Buffer Pool Size: ${INNODB_BUFFER_POOL_SIZE_RAW} (~${INNODB_BUFFER_POOL_MB} MB)"

# --- Get PHP OPcache Settings ---
log "Reading PHP OPcache configuration from $PHP_INI_PATH..."

# Get OPcache memory consumption, default to 128MB if not set
OPCACHE_MEM_RAW=$(grep -E "^opcache.memory_consumption" "$PHP_INI_PATH" | awk -F'=' '{print $2}' | tr -d '[:space:]')
OPCACHE_MEM_MB=$(parse_memory_to_mb "${OPCACHE_MEM_RAW:-128M}")
log "Detected OPcache Memory Consumption: ${OPCACHE_MEM_RAW:-128M} (~${OPCACHE_MEM_MB} MB)"

# Get JIT buffer size, default to 0MB if not set
OPCACHE_JIT_RAW=$(grep -E "^opcache.jit_buffer_size" "$PHP_INI_PATH" | awk -F'=' '{print $2}' | tr -d '[:space:]')
OPCACHE_JIT_MB=$(parse_memory_to_mb "${OPCACHE_JIT_RAW:-0M}")
log "Detected OPcache JIT Buffer Size: ${OPCACHE_JIT_RAW:-0M} (~${OPCACHE_JIT_MB} MB)"

# --- Calculate Total Huge Pages Needed ---
log "Calculating total Huge Pages required..."

# Add a small overhead (e.g., 64MB) for system processes and PHP itself
PHP_OVERHEAD_MB=64
TOTAL_MEMORY_MB=$((INNODB_BUFFER_POOL_MB + OPCACHE_MEM_MB + OPCACHE_JIT_MB + PHP_OVERHEAD_MB))
log "Total memory to cover with Huge Pages: ${TOTAL_MEMORY_MB} MB"

# Get kernel's Huge Page size (usually 2048 KB)
HUGEPAGE_SIZE_KB=$(grep 'Hugepagesize' /proc/meminfo | awk '{print $2}')
if [ -z "$HUGEPAGE_SIZE_KB" ]; then
    HUGEPAGE_SIZE_KB=2048 # Fallback to default
fi
log "Detected Kernel Hugepagesize: ${HUGEPAGE_SIZE_KB} KB"

# Calculate the final number of pages, adding one extra page for safety margin
NUM_HUGEPAGES=$(( (TOTAL_MEMORY_MB * 1024) / HUGEPAGE_SIZE_KB + 1 ))
log "Calculated number of Huge Pages to reserve: ${NUM_HUGEPAGES}"

# --- Create the Kernel Configuration File ---
log "Creating sysctl configuration file at /etc/sysctl.d/98-hugepages.conf..."
SYSCTL_CONF_FILE="/etc/sysctl.d/98-hugepages.conf"

cat > "$SYSCTL_CONF_FILE" << EOF
# --- Huge Pages Configuration (Generated by Script) ---
# This value is calculated based on MariaDB buffer pool and PHP OPcache requirements.
vm.nr_hugepages = ${NUM_HUGEPAGES}
EOF

log "Successfully created ${SYSCTL_CONF_FILE}."

# --- Apply settings to the live system ---
log "Applying settings to the current kernel session..."
sysctl -p "$SYSCTL_CONF_FILE"

# --- Final Instructions ---
echo
echo "========================================================================"
echo "    >>> AUTOMATED HUGE PAGES CONFIGURATION COMPLETE <<<"
echo "========================================================================"
echo
echo "The kernel has been configured to reserve ${NUM_HUGEPAGES} Huge Pages."
echo
echo "IMPORTANT: Two final manual steps are required:"
echo
echo "1. CONFIGURE YOUR APPLICATIONS:"
echo "   - In your MariaDB config (/etc/my.cnf), add 'large-pages=1' under the [mysqld] section."
echo "   - In your PHP config (${PHP_INI_PATH}), add 'opcache.huge_code_pages=1' under the [opcache] section."
echo
echo "2. REBOOT YOUR SERVER:"
echo "   A reboot is strongly recommended to ensure the kernel properly allocates"
echo "   a clean, contiguous block of memory for Huge Pages."
echo "   Run the command: sudo reboot"
echo
echo "========================================================================"

