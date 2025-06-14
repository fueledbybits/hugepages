Automated Huge Pages Configuration for aaPanel Servers
Overview

This repository contains a shell script (setup_hugepages.sh) designed to automate the configuration of Linux Huge Pages on a production web server running aaPanel.

The primary goal is to improve the performance and stability of MariaDB/MySQL and PHP OPcache by allowing them to use a dedicated, pre-allocated pool of memory. This is a standard optimization for high-performance servers, and this script automates the complex calculation and configuration steps.
Target Environment

This script is specifically designed and tested for a server environment with the following components:

    Control Panel: aaPanel

    Operating System: Red Hat-based Linux (AlmaLinux 8/9, Rocky Linux 8/9, etc.)

    Web Server: OpenLiteSpeed (as installed by aaPanel)

    PHP: Any version installed via the aaPanel OpenLiteSpeed manager (e.g., lsphp83).

    Database: MariaDB or MySQL installed via aaPanel.

What the Script Does

The script performs the following actions automatically:

    Reads Configurations: It intelligently finds your my.cnf file and the php.ini for the specific PHP version you target.

    Calculates Memory Requirements: It reads your configured innodb_buffer_pool_size (for the database) and your opcache.memory_consumption + opcache.jit_buffer_size (for PHP).

    Determines Huge Page Count: It calculates the total number of 2MB Huge Pages needed to cover both your database and PHP cache, adding a small safety overhead.

    Configures the Kernel: It creates a configuration file at /etc/sysctl.d/98-hugepages.conf to instruct the Linux kernel to reserve this pool of Huge Pages on every boot.

    Configures MariaDB: It checks your /etc/my.cnf and automatically adds the large-pages=1 directive under the [mysqld] section, telling the database to use the reserved Huge Pages.

    Configures PHP: It checks your target php.ini file and automatically adds opcache.huge_code_pages=1 under the [opcache] section, telling OPcache to use the reserved Huge Pages.

Instructions for Use
Step 1: Download the Script

Log in to your server via SSH as the root user or a user with sudo privileges. Download the script to your current directory.

wget -O setup_hugepages.sh [URL_TO_RAW_SCRIPT_IN_YOUR_GITHUB_REPO]

(Note: Replace the URL with the actual raw link from your GitHub repository.)
Step 2: Make the Script Executable

Give the script the necessary permissions to be run as a program.

chmod +x setup_hugepages.sh

Step 3: Run the Script

Execute the script with sudo. You must provide the target PHP version (using the name from the /usr/local/lsws/ directory) as an argument.

Example for PHP 8.3:

sudo ./setup_hugepages.sh php83

Example for PHP 8.1:

sudo ./setup_hugepages.sh php81

If you forget the argument, the script will show you a list of the PHP versions it has detected.
Step 4: Final Verification and Reboot (CRITICAL)

The script will automatically configure your system files. However, it is a best practice to manually verify these changes before the final, required reboot.

    Check MariaDB Config:

    cat /etc/my.cnf

    Ensure large-pages=1 is present under the [mysqld] section.

    Check PHP Config (using your target version):

    cat /usr/local/lsws/lsphp83/etc/php.ini

    Ensure opcache.huge_code_pages=1 is present under the [opcache] section.

    Reboot the Server: A reboot is required for the kernel to properly allocate the reserved memory.

    sudo reboot

After the reboot, your server will be running with the high-performance Huge Pages configuration fully enabled for both your database and PHP.