<h1>Automated Huge Pages Configuration for aaPanel Servers</h1>


<h3> Overview </h3>

This repository contains a shell script (hugepages.sh) designed to automate the configuration of Linux Huge Pages on a production web server running aaPanel.

The primary goal is to improve the performance and stability of MariaDB/MySQL and PHP OPcache by allowing them to use a dedicated, pre-allocated pool of memory. This is a standard optimization for high-performance servers, and this script automates the complex calculation and configuration steps. The script also disables THP Transparent Hugepages (AnonHugePages) for better memory management and performance.


<h3>Target Environment</h3>

 <b>This script is specifically designed and tested for a server environment with the following components:</b>

    Control Panel: aaPanel

    Operating System: Red Hat-based Linux (AlmaLinux 8/9, Rocky Linux 8/9, etc.)

    Web Server: OpenLiteSpeed (as installed by aaPanel)

    PHP: Any version installed via the aaPanel OpenLiteSpeed manager (e.g., lsphp83).

    Database: MariaDB or MySQL installed via aaPanel.

<h3>What the Script Does</h3>

The script performs the following actions automatically:

    Reads Configurations: It intelligently finds your my.cnf file and the php.ini for the specific PHP version you target.

    Calculates Memory Requirements: It reads your configured innodb_buffer_pool_size (for the database) and your opcache.memory_consumption + opcache.jit_buffer_size (for PHP).

        https://dev.mysql.com/doc/refman/8.4/en/large-page-support.html

    Determines Huge Page Count: It calculates the total number of 2MB Huge Pages needed to cover both your database and PHP cache, adding a small safety overhead. 

    Configures the Kernel: It creates a configuration file at /etc/sysctl.d/98-hugepages.conf to instruct the Linux kernel to reserve this pool of Huge Pages on every boot.

    Configures MariaDB: It checks your /etc/my.cnf and automatically adds the large-pages=1 directive under the [mysqld] section, telling the database to use the reserved Huge Pages.

    Configures PHP: It checks your target php.ini file and automatically adds opcache.huge_code_pages=1 under the [opcache] section, telling OPcache to use the reserved Huge Pages.

    Disables THP Transparent Hugepages (AnonHugePages). Creates a systemd service (disable-thp.service) to disable THP during boot.

<h3>Instructions for Use</h3

<b>Step 1: Download the Script</b>


    wget -O hugepages.sh [URL_TO_RAW_SCRIPT_IN_YOUR_GITHUB_REPO]
    
(Note: Replace the URL with the actual raw link from your GitHub repository.)


<b>Step 2: Make the Script Executable</b>

    chmod +x hugepages.sh


<b>Step 3: Run the Script</b>

Example for PHP 8.3:

    sudo ./hugepages.sh php83

Example for PHP 8.1:

    sudo ./setup_hugepages.sh php81

If you forget the argument, the script will show you a list of the PHP versions it has detected.


<b>Step 4: Final Verification and Reboot (CRITICAL)</b>

The script will automatically configure your system files. However, it is a best practice to manually verify these changes before the final, required reboot.

    Check MariaDB Config:

    cat /etc/my.cnf

    Ensure large-pages=1 is present under the [mysqld] section. Add if not present.

    Check PHP Config (using your target version):

    cat /usr/local/lsws/lsphp83/etc/php.ini

    Ensure opcache.huge_code_pages=1 is present under the [opcache] section. Add if not present.

    Reboot the Server: A reboot is required for the kernel to properly allocate the reserved memory.

    sudo reboot

    fter rebooting, you can verify Huge and Anon H Pages status with:
        echo "  cat /proc/meminfo | grep Huge"

After the reboot, your server will be running with the high-performance Huge Pages configuration fully enabled for both your database and PHP.

If InnoDB cannot use hugePages, it falls back to use of traditional memory and writes a warning to the error log: 
    "Warning: Using conventional memory pool". 


<h3> Important Disclaimer: Understanding Memory Reservation </h3>

Enabling Huge Pages is a powerful performance optimization, but it fundamentally changes how your server's memory is managed. It is crucial to understand this trade-off.

    Permanent Reservation: When you enable Huge Pages using this script, you are instructing the Linux kernel to permanently reserve a large, contiguous block of RAM at boot time. For example, if the script calculates a need for 8.5 GB, that memory is immediately set aside for this specific purpose.

    Not Available for General Use: This reserved memory is no longer available to the operating system for general use. It cannot be used for:

        The OS disk cache (which normally speeds up file access).

        Other applications that are not specifically configured to use Huge Pages.

        Temporarily accommodating memory spikes from other services.

    The Trade-Off: You are intentionally sacrificing a portion of your server's memory flexibility in exchange for a significant performance and stability gain for your most critical applications (MariaDB and PHP OPcache). By giving them this exclusive, non-fragmented pool of RAM, you ensure they run with maximum efficiency and are protected from the system-level memory pressure that can cause latency spikes.

This is a standard and highly recommended practice for dedicated, high-performance database and application servers where the performance of MariaDB and PHP is the top priority.