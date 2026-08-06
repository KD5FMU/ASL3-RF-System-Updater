<p align="center">
  <img
    src="images/asl3-rf-system-updater-banner.png"
    alt="AllStar RF System Updater"
    width="100%"
  />
</p>

<p align="center">
  <strong>
    RF-controlled system updates for AllStarLink 3 nodes running Debian 12 or Debian 13
  </strong>
</p>

<p align="center">
  Check for updates, hear the available update count over RF, and approve or cancel the upgrade using DTMF commands.
</p>

# ASL3-RF-System-Updater
A safe, RF-controlled system updater for AllStarLink 3 nodes running Debian 12 or Debian 13. Check for available updates, hear the update count through TTS, and approve or cancel the upgrade using separate DTMF commands.
<br>
- [Installation](#installation)
<br>
# ASL3 RF System Updater

A safe, interactive, RF-controlled system updater for **AllStarLink 3 nodes running Debian 12 or Debian 13**.

This project allows an AllStarLink operator to check for available Debian and ASL3 package updates using a DTMF command sent over RF. The node announces the number of available updates using text-to-speech and waits for a separate DTMF command to approve or cancel the upgrade.

No monitor, keyboard, SSH connection, or web browser is required during normal operation.

## Features

* Checks Debian and AllStarLink repositories for available updates.
* Announces update status over the node using ASL3 text-to-speech.
* Announces the total number of available package upgrades.
* Requires a separate DTMF confirmation before installing anything.
* Uses three independent DTMF commands to prevent command-prefix conflicts.
* Allows the operator to approve or cancel the upgrade entirely over RF.
* Uses a configurable confirmation timeout.
* Prevents multiple update processes from running simultaneously.
* Rejects expired or invalid upgrade requests.
* Keeps a detailed activity and error log.
* Announces whether the upgrade completed successfully.
* Announces whether a system reboot is required.
* Creates a backup of `/etc/asterisk/rpt.conf` before changing it.
* Automatically restores the backup if Asterisk fails to restart.
* Includes a complete uninstaller.
* Uses narrowly restricted `sudo` permissions rather than giving Asterisk unrestricted root access.

## Supported Systems

This installer is intended for:

* AllStarLink 3
* Debian 12 Bookworm
* Debian 13 Trixie
* Asterisk with `app_rpt`
* Nodes using `/etc/asterisk/rpt.conf`
* Systems with the standard `asterisk` service account

This project is not intended for HamVoIP or older ASL installations that do not use the ASL3 Debian package structure.

## Default DTMF Commands

The installer suggests the following default commands:

```text
*894  Check for available updates
*895  Approve and install updates
*896  Cancel the pending upgrade
```

The commands can be changed during installation.

Each command must be independent. One command cannot be the beginning or prefix of another command.

For example, this configuration must not be used:

```text
894
894A
894B
```

In `app_rpt`, the command `894` may execute as soon as those three digits are received. Asterisk may therefore run the check command before the final `A` or `B` is entered.

The corrected design uses separate commands:

```text
894
895
896
```

## How the RF Update Process Works

### Step 1: Check for updates

The operator sends the check command over RF:

```text
*894
```

The node announces:

> Updating the system information now.

The updater then runs:

```bash
apt-get update
```

This refreshes the package information from the configured Debian, AllStarLink, and other package repositories.

The updater then performs a simulated upgrade to count the packages that would be installed:

```bash
apt-get --simulate upgrade
```

No packages are installed during this stage.

### Step 2: Hear the update count

When updates are available, the node announces something similar to:

> There are 10 updates available. To proceed, enter D T M F star 895. To cancel, enter D T M F star 896. You have 120 seconds to respond.

If no upgrades are available, the node announces:

> The system is already up to date. No upgrades are available.

No pending approval request is created when the system is already current.

### Step 3: Approve the upgrade

To approve the upgrade, the operator sends:

```text
*895
```

The updater verifies that:

* An update request is pending.
* The request contains valid information.
* The confirmation period has not expired.
* Another update process is not already running.

If everything is valid, the node announces:

> Approval received. Installing 10 available updates now.

The updater then runs:

```bash
apt-get upgrade -y
```

### Step 4: Receive the completion announcement

When the upgrade finishes successfully, the node announces one of the following messages.

When no reboot is required:

> The system upgrade completed successfully. No reboot is currently required.

When Debian reports that a reboot is required:

> The system upgrade completed successfully. A reboot is required.

If the upgrade encounters an error, the node announces:

> The system upgrade encountered an error. Please examine the update log.

### Cancelling the upgrade

During the confirmation period, the operator can send:

```text
*896
```

The node announces:

> Upgrade halted. No updates were installed.

The pending approval request is removed, and the upgrade does not run.

### Expired approval requests

The default confirmation period is 120 seconds.

If the approval command is entered after the timeout has expired, the node announces:

> The upgrade confirmation time has expired. Please check for updates again.

A new update check must then be started with the check command.

## Installation

### Step 1: Open a terminal on the node

Connect to the ASL3 node using SSH or open a local terminal.

Change to the directory containing the installer.

For example:

```bash
cd ~
```

### Step 2: Download the installer

Download:

```text
sudo wget https://raw.githubusercontent.com/KD5FMU/ASL3-RF-System-Updater/refs/heads/main/install-asl3-rf-system-updater-v2.sh
```

You may download it directly from the GitHub repository or copy it to the ASL3 node using SCP, SFTP, a USB drive, or another file-transfer method.

### Step 3: Make the installer executable

Run:

```bash
sudo chmod +x install-asl3-rf-system-updater-v2.sh
```

### Step 4: Run the installer

Run:

```bash
sudo ./install-asl3-rf-system-updater-v2.sh
```

The installer must run as root because it installs system files, creates restricted sudo permissions, modifies `rpt.conf`, and restarts Asterisk.

### Step 5: Enter the node number

The installer scans `/etc/asterisk/rpt.conf` and displays detected node stanzas when possible.

It then asks:

```text
Node number for RF announcements:
```

Enter the node number that should transmit the TTS announcements.

Example:

```text
577883
```

### Step 6: Select the DTMF commands

The installer asks for three separate commands.

Example:

```text
DTMF command to CHECK for updates [894]:
DTMF command to APPROVE upgrade [895]:
DTMF command to CANCEL upgrade [896]:
```

Press Enter to accept the defaults, or enter different numeric commands.

The installer validates the commands before continuing.

It verifies that:

* Each command contains only numeric digits.
* Each command is between 2 and 8 digits long.
* No two commands are identical.
* No command is the prefix of another command.
* The selected commands are not already assigned in the active functions stanza.

### Step 7: Select the confirmation timeout

The installer asks:

```text
Confirmation timeout in seconds [120]:
```

Press Enter to use 120 seconds.

The allowed range is:

```text
30 to 900 seconds
```

### Step 8: Review the settings

The installer displays the selected configuration.

Example:

```text
RF commands:
  *894  Check for updates
  *895  Approve and install
  *896  Cancel
  Timeout: 120 seconds
```

Enter `Y` or press Enter to continue.

### Step 9: Allow the installation to finish

The installer installs the required packages and configuration.

At completion, it displays the commands, timeout, log location, and uninstaller command.

## What the Installer Changes

The installer performs the following operations.

### Installs required packages

The installer refreshes the package lists and installs:

```text
asl3-tts
util-linux
sudo
python3
```

These packages provide:

* ASL3 text-to-speech support
* File locking through `flock`
* Restricted privilege elevation through `sudo`
* Installer file-processing support

### Creates the configuration file

The installer creates:

```text
/etc/asl3-rf-updater.conf
```

This file stores:

* Node number
* Check DTMF command
* Approval DTMF command
* Cancellation DTMF command
* Confirmation timeout
* Runtime state directory
* Log-file location

Example:

```bash
NODE_NUMBER="577883"
CHECK_DTMF="894"
APPROVE_DTMF="895"
CANCEL_DTMF="896"
CONFIRM_TIMEOUT="120"
STATE_DIR="/run/asl3-rf-updater"
LOGFILE="/var/log/asl3-rf-updater.log"
```

### Creates the protected update programs

The installer creates:

```text
/usr/local/lib/asl3-rf-updater/check-updates-root
/usr/local/lib/asl3-rf-updater/approve-updates-root
/usr/local/lib/asl3-rf-updater/cancel-updates-root
```

These programs perform the privileged package-management operations.

They are owned by root and are not intended to be modified or run directly by the Asterisk service account.

### Creates Asterisk-callable wrapper scripts

The installer creates:

```text
/usr/local/sbin/asl3-rf-update-check
/usr/local/sbin/asl3-rf-update-approve
/usr/local/sbin/asl3-rf-update-cancel
```

These wrappers are called by the `cmd` entries in `rpt.conf`.

Each wrapper launches only its matching protected program using noninteractive `sudo`.

### Creates restricted sudo permissions

The installer creates:

```text
/etc/sudoers.d/asl3-rf-updater
```

This file permits the `asterisk` account to run only the three updater programs.

It does not give the `asterisk` account unrestricted root access.

The allowed programs are:

```text
/usr/local/lib/asl3-rf-updater/check-updates-root
/usr/local/lib/asl3-rf-updater/approve-updates-root
/usr/local/lib/asl3-rf-updater/cancel-updates-root
```

The installer validates the sudoers file using:

```bash
visudo -cf
```

### Modifies rpt.conf

The installer determines which functions stanza is assigned to the selected node.

It then adds entries similar to:

```ini
; ASL3 RF system updater
894=cmd,/usr/local/sbin/asl3-rf-update-check
895=cmd,/usr/local/sbin/asl3-rf-update-approve
896=cmd,/usr/local/sbin/asl3-rf-update-cancel
```

The leading `*` is not entered in the function number inside `rpt.conf`. The operator uses the normal function prefix when sending the command over RF.

For example:

```text
rpt.conf entry: 894
RF entry:        *894
```

### Backs up rpt.conf

Before changing the file, the installer creates a timestamped backup similar to:

```text
/etc/asterisk/rpt.conf.asl3-rf-updater.20260722-083000
```

The original ownership and permissions are preserved.

### Restarts Asterisk

After installation, the installer runs:

```bash
systemctl restart asterisk
```

It then verifies that Asterisk returned to the active state.

If Asterisk fails to restart after the configuration change, the installer attempts to restore the saved `rpt.conf` backup.

### Creates the log file

The installer creates:

```text
/var/log/asl3-rf-updater.log
```

The log records activity while the updater runs.

It includes:

* Update-check start times
* Package repository output
* Number of available upgrades
* Pending confirmation creation
* Approval attempts
* Cancellation attempts
* Expired confirmation requests
* Upgrade results
* Reboot requirements
* TTS errors
* APT errors

View the entire log:

```bash
sudo cat /var/log/asl3-rf-updater.log
```

View the last 50 lines:

```bash
sudo tail -n 50 /var/log/asl3-rf-updater.log
```

Watch the log live:

```bash
sudo tail -f /var/log/asl3-rf-updater.log
```

## Runtime Files

The updater uses:

```text
/run/asl3-rf-updater/
```

A pending confirmation request is stored temporarily as:

```text
/run/asl3-rf-updater/pending
```

The file contains:

* The time the request was created
* The number of available upgrades

Because `/run` is temporary system storage, stale runtime state does not survive a reboot.

The updater also uses a lock file to prevent simultaneous package-management operations.

## Safety Features

### Separate DTMF commands

The check, approval, and cancellation commands are completely independent.

This prevents `app_rpt` from executing a shorter command while the operator is still entering a longer command.

### Confirmation timeout

An upgrade cannot be approved indefinitely after the original check.

The pending request expires after the configured timeout.

### One-time approval

The pending request is removed before the upgrade begins.

This prevents the same request from being approved more than once.

### Process locking

The updater uses `flock` to prevent two update processes from running at the same time.

### Restricted root access

Asterisk is authorized to run only the three protected updater programs.

It is not granted general passwordless root access.

### Configuration backup

The installer backs up `rpt.conf` before modifying it.

### Asterisk restart verification

The installer checks that Asterisk is active after restarting it.

### Noninteractive package upgrade

The upgrade runs with:

```bash
DEBIAN_FRONTEND=noninteractive
```

This prevents the RF-controlled update from stopping at a normal interactive package prompt.

Operators should still review the log after an upgrade, especially when major Debian or ASL3 changes are installed.

## Testing After Installation

### Test the update check

Send over RF:

```text
*894
```

You should hear:

> Updating the system information now.

After the package check completes, you should hear either the available-update count or a message indicating that the system is already current.

### Test cancellation

When updates are available, send:

```text
*896
```

You should hear:

> Upgrade halted. No updates were installed.

### Test approval

Run the check again:

```text
*894
```

After hearing the update count, send:

```text
*895
```

You should hear an approval announcement followed by a completion or error announcement.

### Verify the log

Run:

```bash
sudo tail -n 100 /var/log/asl3-rf-updater.log
```

A successful approval section begins with:

```text
Upgrade approval received:
```

A successful upgrade ends with a message similar to:

```text
Upgrade completed successfully.
```

## Troubleshooting

### The check command runs again when approving

This normally indicates overlapping DTMF commands.

Do not configure commands such as:

```text
894
894A
894B
```

Use independent commands such as:

```text
894
895
896
```

### The node says no upgrade request is pending

Possible causes include:

* The approval command was entered before running the check command.
* No updates were available.
* The pending request was cancelled.
* The confirmation period expired.
* The node rebooted after the check.
* The runtime pending file was removed.

Run the check command again and approve within the configured timeout.

### TTS announcements do not play

Confirm that `asl-tts` is installed:

```bash
command -v asl-tts
```

Test TTS manually, replacing the node number:

```bash
sudo -u asterisk asl-tts -n 577883 -t "Testing the RF system updater"
```

Also examine:

```bash
sudo tail -n 100 /var/log/asl3-rf-updater.log
```

### A DTMF command does nothing

Confirm the installed entries:

```bash
grep -A5 -B2 "ASL3 RF system updater" /etc/asterisk/rpt.conf
```

Confirm Asterisk is running:

```bash
systemctl status asterisk
```

Confirm the wrappers exist:

```bash
ls -l /usr/local/sbin/asl3-rf-update-*
```

### The upgrade failed

Examine the updater log:

```bash
sudo tail -n 200 /var/log/asl3-rf-updater.log
```

You may also run the normal Debian commands manually through SSH:

```bash
sudo apt-get update
sudo apt-get upgrade
```

This may reveal an unusual package or configuration issue that requires direct operator attention.

## Uninstallation

Run:

```bash
sudo /usr/local/sbin/uninstall-asl3-rf-updater
```

The uninstaller:

* Removes the three updater DTMF entries from `rpt.conf`
* Removes the Asterisk wrapper scripts
* Removes the protected updater programs
* Removes the updater configuration
* Removes the restricted sudoers file
* Removes temporary runtime state
* Restarts Asterisk
* Removes itself after completion

The log is intentionally retained at:

```text
/var/log/asl3-rf-updater.log
```

Remove the retained log manually when desired:

```bash
sudo rm -f /var/log/asl3-rf-updater.log
```

## Installed File Summary

```text
/etc/asl3-rf-updater.conf
/etc/sudoers.d/asl3-rf-updater
/usr/local/lib/asl3-rf-updater/check-updates-root
/usr/local/lib/asl3-rf-updater/approve-updates-root
/usr/local/lib/asl3-rf-updater/cancel-updates-root
/usr/local/sbin/asl3-rf-update-check
/usr/local/sbin/asl3-rf-update-approve
/usr/local/sbin/asl3-rf-update-cancel
/usr/local/sbin/uninstall-asl3-rf-updater
/var/log/asl3-rf-updater.log
/run/asl3-rf-updater/
```

## Important Operational Notes

This updater runs a standard Debian package upgrade:

```bash
apt-get upgrade -y
```

It does not automatically run:

```bash
apt-get full-upgrade
apt-get dist-upgrade
apt autoremove
```

This is intentional. A normal upgrade is the more conservative choice for an unattended RF-controlled maintenance command.

Operators should periodically connect by SSH to review:

* Held packages
* Obsolete packages
* Repository warnings
* Configuration-file notices
* Available distribution upgrades
* Disk-space usage
* Services that failed after upgrading

An RF updater is convenient, but it should not completely replace normal system administration and log review.

## License

GPL-3.0

## Author

Created for the AllStarLink and amateur-radio community by:

**Freddie Mac — KD5FMU**
**Ham Radio Crusader**

Ham On Y’all!
