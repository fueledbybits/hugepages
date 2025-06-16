#!/bin/bash
# ==============================================================================
# Automated Huge Pages & THP Tuning Script (v5)
# ==============================================================================
#
# Description:
# This script automatically:
# 1. Calculates the required number of Huge Pages for MariaDB and PHP OPcache.
# 2. Creates a kernel configuration file to reserve the pages.
# 3. Modifies MariaDB and PHP configurations to use Huge Pages.
# 4. Creates and enables a systemd service to reliably disable Transparent Huge (Anon)
#    Pages (THP) on every boot for performance stability.
#
# Usage:
#   sudo ./setup_hugepages.sh <php_version>
#   Example: sudo ./setup_hugepages.sh php83
#
# Author: Boris Lucas
# Date: June 15, 2025
#
# ==============================================================================

# --- FUNCTION TO DISPLAY MESSAGES ---
log() {
    echo "[INFO] $1"
}
log-setup() {
    echo "[SETUP] $1"
}
log-empty() {
    echo " $1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

# --- PERMISSION CHECK ---
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run with root privileges. Please use sudo."
fi

# --- ARGUMENT CHECK FOR PHP VERSION ---
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


# Check if the PHP configuration file exists
if [ ! -f "$PHP_INI_PATH" ]; then
    error "PHP configuration file not found at '$PHP_INI_PATH'. Please check the version name and ensure it's an OLS PHP version."
fi


# --- FIND MARIADB/MYSQL CONFIGURATION FILE ---
MY_CNF="/etc/my.cnf"
if [ ! -f "$MY_CNF" ]; then
    error "MariaDB/MySQL configuration file not found at $MY_CNF. Please ensure MariaDB is installed."
fi


# --- FUNCTION TO PARSE MEMORY VALUES (E.G., 8G, 8192M, 1024K) AND CONVERT TO MB ---
parse_memory_to_mb() {
    local mem_value=$1
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
            echo $value
            ;;
    esac
}


# --- GET MARIADB INNODB BUFFER POOL SIZE ---

log "Reading MariaDB configuration from $MY_CNF..."
INNODB_BUFFER_POOL_SIZE_RAW=$(grep -E "^innodb_buffer_pool_size" "$MY_CNF" | awk -F'=' '{print $2}' | tr -d '[:space:]')

if [ -z "$INNODB_BUFFER_POOL_SIZE_RAW" ]; then
    error "Could not find 'innodb_buffer_pool_size' in $MY_CNF."
fi

INNODB_BUFFER_POOL_MB=$(parse_memory_to_mb "$INNODB_BUFFER_POOL_SIZE_RAW")
log "Detected InnoDB Buffer Pool Size: ${INNODB_BUFFER_POOL_SIZE_RAW} (~${INNODB_BUFFER_POOL_MB} MB)"



# Check the PHP /etc/php.d directory for the OPcache configuration file. Default to php.ini if not found.
log "Finding OPcache configuration file for $1..."
OPCACHE_CONF_FILE=$(find /usr/local/lsws/lsphp${PHP_TARGET_VERSION_SHORT}/etc/php.d/ -name "*-opcache.ini" 2>/dev/null | head -n 1)

IS_MAIN_PHP_INI=false
# If a specific opcache file isn't found, fall back to the main php.ini
if [ -z "$OPCACHE_CONF_FILE" ]; then
    log "Warning: No specific opcache.ini file found. Using main php.ini as a fallback."
    OPCACHE_CONF_FILE=$PHP_INI_PATH
    IS_MAIN_PHP_INI=true
else
    log "Using PHP OPcache config file: $OPCACHE_CONF_FILE"
fi



# --- GET PHP OPCACHE SETTINGS ---
log "Reading PHP OPcache configuration from $OPCACHE_CONF_FILE..."

# Get OPcache memory consumption, default to 128MB if not set
OPCACHE_MEM_RAW=$(grep -E "^opcache.memory_consumption" "$OPCACHE_CONF_FILE" | awk -F'=' '{print $2}' | tr -d '[:space:]')
OPCACHE_MEM_MB=$(parse_memory_to_mb "${OPCACHE_MEM_RAW:-128M}")
log "Detected OPcache Memory Consumption: ${OPCACHE_MEM_RAW:-128M} (~${OPCACHE_MEM_MB} MB)"

# Get JIT buffer size from the correct file, default to 0MB if not set
OPCACHE_JIT_RAW=$(grep -E "^opcache.jit_buffer_size" "$OPCACHE_CONF_FILE" | awk -F'=' '{print $2}' | tr -d '[:space:]')
OPCACHE_JIT_MB=$(parse_memory_to_mb "${OPCACHE_JIT_RAW:-0M}")
log "Detected OPcache JIT Buffer Size: ${OPCACHE_JIT_RAW:-0M} (~${OPCACHE_JIT_MB} MB)"


# --- CALCULATE TOTAL HUGE PAGES NEEDED ---

log "Calculating total Huge Pages required..."

PHP_OVERHEAD_MB=64
TOTAL_MEMORY_MB=$((INNODB_BUFFER_POOL_MB + OPCACHE_MEM_MB + OPCACHE_JIT_MB + PHP_OVERHEAD_MB))
log "Total memory to cover with Huge Pages: ${TOTAL_MEMORY_MB} MB"

HUGEPAGE_SIZE_KB=$(grep 'Hugepagesize' /proc/meminfo | awk '{print $2}')
if [ -z "$HUGEPAGE_SIZE_KB" ]; then
    HUGEPAGE_SIZE_KB=2048
fi
log "Detected Kernel Hugepagesize: ${HUGEPAGE_SIZE_KB} KB"

NUM_HUGEPAGES=$(( (TOTAL_MEMORY_MB * 1024) / HUGEPAGE_SIZE_KB + 1 ))
log "Calculated number of Huge Pages to reserve: ${NUM_HUGEPAGES}"



# --- CONFIGURE KERNEL ---

log "Creating sysctl configuration file to reserve Huge Pages..."
SYSCTL_CONF_FILE="/etc/sysctl.d/98-hugepages.conf"
echo "# --- Huge Pages Configuration (Generated by Script) ---" > "$SYSCTL_CONF_FILE"
echo "vm.nr_hugepages = ${NUM_HUGEPAGES}" >> "$SYSCTL_CONF_FILE"


# --- CONFIGURE MARIADB ---

if grep -q "^large-pages" "$MY_CNF"; then
    log "'large-pages' directive already present in $MY_CNF. No changes made."
else
    log "Adding 'large-pages=1' and comments to the [mysqld] section in $MY_CNF..."
    
    # Step 1: Add the main directive after the [mysqld] line.
    sed -i '/\[mysqld\]/a large-pages=1' "$MY_CNF"
    
    # Step 2: Add the comment BEFORE the new large-pages line.
    sed -i '/^large-pages=1/i # Enable Huge Pages for MariaDB (Added by script)' "$MY_CNF"
    
    # Step 3: Add the comment AFTER the new large-pages line.
    sed -i '/^large-pages=1/a # End of Huge Pages directive (Added by script)' "$MY_CNF"
fi



# --- CONFIGURE PHP ---

# Check if OPcache  directive is already set to 1
if grep -q -E "^\s*opcache\.huge_code_pages\s*=\s*1" "$OPCACHE_CONF_FILE"; then
    log "'opcache.huge_code_pages=1' is already active. No changes made."

# Check if the setting exists but is commented out or set to a different value
elif grep -q "opcache.huge_code_pages" "$OPCACHE_CONF_FILE"; then
    log "Found existing 'opcache.huge_code_pages' setting. Updating value to 1..."
    sed -i "s/.*opcache.huge_code_pages.*/opcache.huge_code_pages=1/" "$OPCACHE_CONF_FILE"

# If the setting does not exist at all, add it intelligently
else
    log "Adding 'opcache.huge_code_pages=1' to $OPCACHE_CONF_FILE..."
    
    # Check if we are editing the MAIN php.ini file
    if [ "$IS_MAIN_PHP_INI" = true ]; then
        # If we are, check if the [opcache] section header exists
        if grep -q "\[opcache\]" "$OPCACHE_CONF_FILE"; then
            # If it exists, add the new directive right after the section header
            log "Found [opcache] section in php.ini. Inserting directive..."
            sed -i '/\[opcache\]/a opcache.huge_code_pages=1' "$OPCACHE_CONF_FILE"
        else
            # If the section itself is missing, create it at the end of the file
            log "No [opcache] section found in php.ini. Creating section..."
            echo "" >> "$OPCACHE_CONF_FILE"
            echo "; Added by server tuning script" >> "$OPCACHE_CONF_FILE"
            echo "[opcache]" >> "$OPCACHE_CONF_FILE"
            echo "opcache.huge_code_pages=1" >> "$OPCACHE_CONF_FILE"
        fi
    else
        # If we are editing a file like 10-opcache.ini, just append the line.
        # This is the correct behavior for aaPanel's separated config files.
        echo "" >> "$OPCACHE_CONF_FILE"
        echo "; Added by server tuning script" >> "$OPCACHE_CONF_FILE"
        echo "opcache.huge_code_pages=1" >> "$OPCACHE_CONF_FILE"
    fi
fi




# --- CONFIGURE TRANSPARENT HUGE PAGES (THP) TO BE DISABLED ON BOOT VIA SYSTEMD ---



log "Configuring Transparent (Anon) Huge Pages  to be disabled..."
THP_SCRIPT_PATH="/usr/local/sbin/disable-thp.sh"
THP_SERVICE_PATH="/etc/systemd/system/disable-thp.service"

# Create the disable script
cat > "$THP_SCRIPT_PATH" << EOF
#!/bin/bash
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi
if [ -f /sys/kernel/mm/transparent_hugepage/defrag ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi
EOF

chmod +x "$THP_SCRIPT_PATH"
log "Created THP disable script at $THP_SCRIPT_PATH"

# Create the systemd service file
cat > "$THP_SERVICE_PATH" << EOF
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mysqld.service

[Service]
Type=oneshot
ExecStart=$THP_SCRIPT_PATH
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

log "Created systemd service at $THP_SERVICE_PATH"



# --- APPLY SETTINGS TO THE LIVE SYSTEM ---
log "Applying kernel settings and enabling new services..."
sysctl -p "$SYSCTL_CONF_FILE"
systemctl daemon-reload
systemctl enable disable-thp.service
systemctl start disable-thp.service

# --- FINAL INSTRUCTIONS ---
echo
echo "========================================================================"
echo "    >>> AUTOMATED SERVER TUNING COMPLETE <<<"
echo "========================================================================"
echo
echo "The script has performed the following actions:"
echo "1. Configured the kernel to reserve ${NUM_HUGEPAGES} Huge Pages."
echo "2. Created and enabled a systemd service to disable Transparent Huge Pages."
echo "3. Added 'large-pages=1' to your MariaDB configuration."
echo "4. Set 'opcache.huge_code_pages=1' in your PHP OPcache configuration."
echo
echo "!! IMPORTANT: PLEASE VERIFY BEFORE REBOOTING !!"
echo
echo "Please manually check the following files to ensure the directives were added correctly:"
echo "  - MariaDB Config: cat $MY_CNF (Look for 'large-pages=1' under [mysqld])"
echo "  - PHP OPcache Config: cat $OPCACHE_CONF_FILE (Look for 'opcache.huge_code_pages=1')"
echo
echo "Once you have verified the settings, a reboot is required to finalize the process."
echo "Run the command: sudo reboot"
echo
echo "After rebooting, you can verify Huge Pages status with:"
echo "  cat /proc/meminfo | grep Huge"
echo
echo "========================================================================"
# --- End of Script ---
