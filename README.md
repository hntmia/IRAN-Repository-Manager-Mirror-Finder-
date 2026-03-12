# IRAN-Repository-Manager-Mirror-Finder-
[!فارسی(https://github.com/hntmia/IRAN-Repository-Manager-Mirror-Finder-/blob/main/README-FA.md)

A universal script to find and apply the fastest local repository mirror for Linux distributions in Iran and bypassing filtering to keep yourself update

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/hntmia/IRAN-Repository-Manager-Mirror-Finder-/blob/main/LICENSE)
[![Bash](https://img.shields.io/badge/Shell-Bash-green)](https://github.com/hntmia/IRAN-Repository-Manager-Mirror-Finder-/blob/iran-repo.manager.sh)

A powerful and universal script to find, rank, and apply the fastest local repository mirror for Linux distributions (Ubuntu, Debian, Fedora, CentOS, Arch, etc.) in Iran.

---

## Features

- **Universal** – Works on any Linux distribution with `bash`, `curl`, and `awk`.
- **Automatic detection** – Identifies your distribution, version, and codename.
- **Multi-path testing** – Tries several standard repository paths (e.g., for Fedora, CentOS, Ubuntu) to ensure the mirror is accessible.
- **Speed & latency measurement** – Downloads a small file to measure latency (ms) and optionally a larger file (first 2MB) to measure download speed (KB/s).
- **Smart ranking** – Combines latency and speed into a score (60% latency + 40% speed); lower score is better.
- **Last-modified date** – Shows the last update date of each mirror (if the server provides the header).
- **Interactive menu** – Scan, auto-select, manual choose, list mirrors, manage blacklist, and restore from backup.
- **Skip with Enter** – During scanning, press Enter to skip the current mirror.
- **Automatic backup** – Before any change, a full backup of your repository configuration is saved to `~/backup_repo/` with timestamp.
- **Restore** – Easily revert to any previous backup.
- **Blacklist** – Mark problematic mirrors so they are skipped in future scans.
- **Signed-By support (Ubuntu)** – Writes `signed-by` option in `sources.list` to avoid warnings after `apt modernize-sources`.
- **Cleanup** – Optionally clears `/etc/apt/sources.list.d/` before applying a new mirror on Debian/Ubuntu.
- **Command-line mode** – Use `scan`, `list`, or `auto` for non‑interactive usage.

---

## Requirements

- `bash` 4+
- `curl`
- `awk` (usually pre‑installed)
- `sudo` privileges for applying changes
- Optional: `dnf` (for speed test on RPM-based), `apt` (for speed test on Debian-based) – but the script works without them.

---

## Installation

1. Clone the repository or download the script and `mirrors.list.sample`:
   ```bash
   git clone https://github.com/yourusername/iran-repo-manager.git
   cd iran-repo-manager
   ```
2. Make the script executable:
   ```bash
   chmod +x iran-repo-manager.sh
   ```
3. Edit `mirrors.list` to include your preferred mirror base URLs.
Use placeholders: `$distro`, `$version`, `$codename`, `$basearch`.
Example:
   ```bash
     http://mirror.arvancloud.ir/$distro
     http://mirror.iranserver.com/$distro
     https://mirror.aminidc.com/$distro
     http://repo.iut.ac.ir/repo/$distro
   ```
## Usage

Run the script without arguments to enter the interactive menu:
   ```bash
    ./iran-repo-manager.sh
   ```
You will see:
   ```bash
    ======================================
    ||     >>> IR REPO MANAGER <<<      ||
    ||         Script by SiaMia         ||
    ======================================

     Detected: ubuntu 24.04 (noble)

     1) Scan and auto-select best mirror
     2) Scan and choose manually
     3) List all mirrors
     4) Manage blacklist
     5) Restore from backup
     6) Exit
   ```
## Interactive Options

  1.  Scan and auto-select – Scans all mirrors, ranks them, and automatically applies the best one (after confirmation).

  2.  Scan and choose manually – After scanning, you see a ranked list and can pick a mirror by number.

  3.  List all mirrors – Shows the raw list from `mirrors.list` with placeholders.

  4.  Manage blacklist – View and clear the blacklist (stored in `~/.cache/iran-repo-manager/blacklist`).

  5.  Restore from backup – Lists all backups in `~/backup_repo/` and lets you restore any of them.

  6.  Exit – Quits the script.

## Command-line Modes

    ./iran-repo-manager.sh scan #– Scan mirrors and show ranking (no changes).

    ./iran-repo-manager.sh list #– List all expanded mirror URLs.

    ./iran-repo-manager.sh auto #– Scan and apply the best mirror automatically (non‑interactive).

## How It Works

  1.  Detection – Reads `/etc/os-release` to get ID, VERSION_ID, and VERSION_CODENAME.

  2.  Mirror expansion – Replaces placeholders (`$distro`, `$version`, `$codename`, `$basearch`) with actual values.

  3.  Accessibility test – For each mirror, tries a series of common repository paths (e.g., `/dists/<codename>/InRelease` for Debian, `/linux/releases/<version>/Everything/x86_64/os/repodata/repomd.xml` for Fedora) until one succeeds.

  4.  Latency measurement – Records the total time (`time_total`) of a HEAD request to the found file, converted to milliseconds.

  5.  Speed measurement – Attempts to download the first 2MB of a larger file (`Packages.gz`, `primary.xml.gz`, etc.). If that fails, falls back to the small file.

  6.  Score calculation – `score = (latency × 0.6) + (100000 / speed × 0.4)`. If speed is zero, it is treated as 1 KB/s.

  7.  Last-modified – If the server provides a `Last-Modified` header, it is converted to epoch and displayed as `YYYY-MM-DD`.

  8.  Ranking – Mirrors are sorted by score (ascending); best first.

  9.  Backup – Before applying any mirror, the current repository configuration is saved under `~/backup_repo/backup-<timestamp>/`.

  10.  Application – Depending on the distribution:

        Debian/Ubuntu: Writes a `sources.list` with `signed-by` option (pointing to the distribution’s keyring) and runs `apt-get update`. If `apt modernize-sources` is available, it is executed.

        Fedora/RHEL/CentOS/Alma/Rocky: Modifies `.repo` files: disables `metalink`/`mirrorlist` and sets baseurl. Then runs `dnf clean all` and `dnf makecache`.

        Arch: Replaces `/etc/pacman.d/mirrorlist` and runs `pacman -Sy`.

Mirror List Format

The file mirrors.list should contain one base URL per line. Lines starting with # are ignored.

You can use the following placeholders:

    $distro #– distribution name (e.g., ubuntu, fedora)

    $version #– version number (e.g., 24.04, 40)

    $codename #– codename (e.g., noble, plucky) – falls back to $version if not available

    $basearch #– architecture (default x86_64)

Example:
    ```bash
      http://mirror.arvancloud.ir/$distro
      https://mirror.iranserver.com/$distro
      http://repo.iut.ac.ir/repo/$distro
    ```
## Backup and Restore

- Backups are stored in `~/backup_repo/backup-<timestamp>/`.
    
- Each backup contains copies of:
    
    - `/etc/apt/sources.list` and `/etc/apt/sources.list.d/` (Debian/Ubuntu)
        
    - `/etc/yum.repos.d/` (RPM-based)
        
    - `/etc/pacman.d/mirrorlist` (Arch)
        
- To restore, choose option **5** in the interactive menu. You will see a list of available backups; select the one you want. A fresh backup of your current configuration is made before restoring, just in case.
## Troubleshooting

- **All mirrors show `FAIL (unreachable)`**
    
    - Check your internet connection.
        
    - Verify that the URLs in `mirrors.list` are correct and accessible (test with `curl -I <url>`).
        
    - Some mirrors may not support the `HEAD` method; the script also tries `GET` with `--range`, but if the server is very strict, it may fail.
        
- **Mirror is accessible but shows speed `0 KB/s`**
    
    - The server may not allow range requests or the large file may not exist. The script falls back to the small file, but if that file is very small, the calculated speed may be zero.
        
- **`apt update` fails after applying a mirror**
    
    - The mirror might be incomplete or not yet synced. Choose a different mirror or try again later.
        
    - If you see warnings about `Signed-By`, the script already adds the `signed-by` option; however, on very old Ubuntu versions, you may need to manually install the keyring.
        
- **`dnf makecache` fails**
    
    - The baseurl pattern might be incorrect for your Fedora version. The script tries to derive the correct path from the successful test path, but sometimes you need to adjust the pattern manually.
        
    - Check the generated `.repo` files under `/etc/yum.repos.d/` and fix the `baseurl` if necessary.
        
- **Blacklist not working**
    
    - The blacklist file is located at `~/.cache/iran-repo-manager/blacklist`. You can edit it manually or use option **4** to clear it.
        

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request or open an Issue for bugs, feature requests, or improvements.

---

## License

This project is licensed under the MIT License – see the [LICENSE](https://LICENSE) file for details.

## P.S
    I Just Test it on `FEDORA` & `UBUNTU` so please let me know if there is any issue.

