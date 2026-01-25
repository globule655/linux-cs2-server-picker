# CS2 Server Picker for Linux

A lightweight bash script to block CS2 server relay locations on Linux using iptables. This is the Linux equivalent of the Windows [CS2 Server Picker application](https://github.com/FN-FAL113/cs2-server-picker).

## Features

- Interactive terminal-based checklist for selecting server locations to block
- **Latency measurement** - Automatically pings servers and displays color-coded latency (green ≤22ms, orange ≤35ms, red >35ms)
- Fetches live server data from Steam API
- Non-persistent iptables rules (cleared on reboot)
- Differential updates: only adds/removes changed rules between runs
- Latency cache to avoid re-measuring on every run
- View currently blocked servers
- Easy cleanup and removal

## Requirements

- Linux with iptables support
- Root/sudo access
- Required packages:
  - `curl` - for fetching Steam API data
  - `jq` - for JSON parsing
  - `iptables` - for firewall rules
  - `ping` - for latency measurements (usually pre-installed)

### Installation of dependencies

**Debian/Ubuntu:**
```bash
sudo apt install curl jq iptables
```

**Fedora/RHEL/CentOS:**
```bash
sudo dnf install curl jq iptables
```

**Arch Linux:**
```bash
sudo pacman -S curl jq iptables
```

## Usage

1. Download the script:
```bash
curl -O https://raw.githubusercontent.com/FN-FAL113/cs2-server-picker/main/cs2-server-picker.sh
chmod +x cs2-server-picker.sh
```

2. Run with sudo:
```bash
sudo ./cs2-server-picker.sh
```

3. From the main menu, choose option 1 to select servers to block

4. On first run, the script will measure latency to all server locations (this may take a minute)

5. In the checklist:
   - Each location shows its ping latency (color-coded: green=good, orange=medium, red=high)
   - Type a number (1, 2, 3...) to toggle that location
   - Type `a` to select all locations
   - Type `n` to deselect all locations
   - Type `d` when done to apply changes

## How It Works

The script:
1. Fetches server relay data from Steam's API
2. Measures latency (ping) to each server location and caches the results
3. Creates a custom iptables chain called `CS2_SERVER_BLOCK`
4. Adds DROP rules for selected server relay IP addresses
5. Tracks state between runs to only modify what changed
6. Rules are non-persistent and will be cleared on reboot

## Menu Options

1. **Block/Unblock servers** - Interactive selection of server locations with latency display
2. **Show currently blocked servers** - List all currently blocked IPs with their locations
3. **Refresh latency measurements** - Re-measure ping to all server locations
4. **Clear all blocks** - Remove all blocking rules but keep the chain
5. **Remove chain and exit** - Completely remove the iptables chain
6. **Exit** - Exit the script (keeps rules active)

## Important Notes

- **Requires root privileges** to modify iptables rules
- **Non-persistent** - All rules are cleared on system reboot
- **Outbound blocking only** - Blocks outbound connections to server relays
- Blocking too many servers may cause connection timeouts
- This does not modify game files and is VAC-safe

## Persistence (Optional)

If you want rules to persist across reboots, you can:

**Debian/Ubuntu:**
```bash
sudo apt install iptables-persistent
sudo netfilter-persistent save
```

**RHEL/CentOS/Fedora:**
```bash
sudo service iptables save
```

## Troubleshooting

**"Must be run as root" error:**
- Run the script with `sudo`

**"Missing required dependencies" error:**
- Install curl, jq, and iptables as shown above

**Not being routed to desired servers:**
- Due to Steam Datagram relay routing, results may vary by location
- Try blocking only high-ping servers to test if routing works
- Some ISP routing issues are outside the script's control

**Rules not applying:**
- Check if iptables service is running: `sudo systemctl status iptables`
- Verify rules with: `sudo iptables -L CS2_SERVER_BLOCK -n -v`

## Uninstallation

To completely remove all traces:
```bash
sudo ./cs2-server-picker.sh
# Choose option 4 from the menu
```

Or manually:
```bash
sudo iptables -D OUTPUT -j CS2_SERVER_BLOCK
sudo iptables -F CS2_SERVER_BLOCK
sudo iptables -X CS2_SERVER_BLOCK
sudo rm -f /tmp/cs2_blocked_servers.txt /tmp/cs2_servers.json /tmp/cs2_latencies.cache
```

## Compatibility

Tested on:
- Ubuntu 20.04+
- Debian 11+
- Fedora 36+
- Arch Linux

Should work on any Linux distribution with bash, iptables, curl, and jq.

## FAQ

**Will I get banned?**
- No, this script only modifies local firewall rules and does not touch game files

**Why sudo/root access?**
- iptables requires root privileges to modify firewall rules

**Can I use this with nftables?**
- This script uses iptables. For nftables, you'd need to adapt the rules

**Does this work for Deadlock?**
- Likely yes, as CS2 and Deadlock use the same server relays

## Contributing

Pull requests welcome! This is a community project to help CS2 players on Linux.

## License

Same as the original CS2 Server Picker project - see LICENSE file.

## Credits

Linux port inspired by the original [CS2 Server Picker](https://github.com/FN-FAL113/cs2-server-picker) by FN-FAL113
