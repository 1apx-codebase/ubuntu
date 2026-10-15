# k8-control: Ubuntu post-install changes

Changes made to the host `k8-control` (Ubuntu 26.04.1 LTS) after installation, on 2026-10-15.

| # | Change | File |
|---|--------|------|
| 1 | Passwordless sudo for `vaviles` | `/etc/sudoers.d/vaviles-nopasswd` (root:root, `0440`) |
| 2 | Static IP `192.168.1.170/24` on `ens18`, gateway `192.168.1.1` (was DHCP, `192.168.1.223`) | `/etc/netplan/00-installer-config.yaml` (`0600`) |
| 3 | DNS servers `192.168.1.1`, `8.8.8.8` | same netplan file |

Backups on the host:

- `/root/00-installer-config.yaml.bak-dhcp` is the original DHCP config.
- `/root/00-installer-config.yaml.bak-static-dns1` is the static config with router-only DNS, from before change 3.

Notes:

- Sudo applies the last matching rule. `vaviles` is still in the `sudo` group, so `sudo -l -U vaviles` lists both `(ALL : ALL) ALL` and `NOPASSWD: ALL`, and no password is asked for.
- Before the change, `192.168.1.170` was confirmed unused (no ping reply, no ARP entry). Reserve it on the router, or exclude it from the DHCP pool, so no other device gets it.
- IPv6 still uses DHCPv6.

## Apply all changes

Script: [`apply-changes.sh`](apply-changes.sh). Run it with `sudo ./apply-changes.sh`.

Run as root from the **console**, not over SSH, because the IP address changes.
If you have to use SSH, change `netplan apply` in the script to `netplan try`, which rolls back after 120 seconds unless you confirm.
Edit the variables at the top to use the script on another machine.
To change DNS later, edit `nameservers.addresses` in the netplan file (servers are tried in order), then run `netplan generate && netplan apply`.

## Revert all changes

Script: [`revert-changes.sh`](revert-changes.sh). Run it with `sudo ./revert-changes.sh`.

This removes the sudo rule and restores the original DHCP config.

## GitHub access

This repo is pushed from k8-control to the private repo [`1apx-codebase/ubuntu`](https://github.com/1apx-codebase/ubuntu) over SSH.
Run every command as `vaviles`, not root, so the key and repo stay owned by that user.

| Item | Value |
|------|-------|
| Local repo | `/home/vaviles/codebase/github/ubuntu` |
| Remote | `origin` → `git@github.com:1apx-codebase/ubuntu.git` |
| Branch | `main`, tracking `origin/main` |
| SSH key | `~/.ssh/id_ed25519` (ed25519, no passphrase), added to the `1apx-codebase` GitHub account |
| Key fingerprint | `SHA256:KvkjMyF+FAECb2T15hknyvUzrue/6Hrq3KNxAjiQbo8` |
| Commit identity | Set for this repo only: `Virgil Aviles <virgil.aviles@proton.me>` |

### One-time setup

Script: [`setup-github.sh`](setup-github.sh). Run it as `vaviles` with `./setup-github.sh`, not with sudo.

It's safe to re-run, because each step is skipped if it's already done. The script:

1. Creates `~/.ssh/id_ed25519` if it doesn't exist.
2. Checks that GitHub accepts the key. If it doesn't, the script prints the public key, saves a copy to `~/github-ssh-key.txt` (with an `scp` command to fetch it from another computer) and waits until you've added it on GitHub. It deletes the copy afterwards.
3. Sets up the local repo and the commit name and email for this repo.
4. Points `origin` at `git@github.com:1apx-codebase/ubuntu.git`.
5. Checks the GitHub repo exists. If it doesn't, the script waits while you create it as an empty, private repo.
6. Pushes `main`, then reports whether the repo is private.

Two steps happen on github.com: adding the key under **Settings → SSH and GPG keys**, and creating the repo. To use a different account, repo, name or email, edit the variables at the top of the script.

### Push later changes

```bash
cd ~/codebase/github/ubuntu
git add -A
git commit -m "Describe the change"
git push
```

The GitHub CLI (`gh`) is installed on this machine but not logged in. The SSH setup doesn't need it.

