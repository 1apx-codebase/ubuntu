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

1. Create an SSH key and print the public key:

   ```bash
   ssh-keygen -t ed25519 -N "" -C "virgil.aviles@proton.me (k8-control)" -f ~/.ssh/id_ed25519
   cat ~/.ssh/id_ed25519.pub
   ```

2. Add the public key on GitHub at **Settings → SSH and GPG keys → New SSH key** (title `k8-control`, type Authentication Key).
   If you can't copy from the terminal, write the key to a file and fetch it from another computer with `scp vaviles@192.168.1.170:github-ssh-key.txt .`.
   Delete the file once the key is added.

   ```bash
   cp ~/.ssh/id_ed25519.pub ~/github-ssh-key.txt
   ```

3. Check that GitHub accepts the key. The first connection adds github.com to `~/.ssh/known_hosts`.

   ```bash
   ssh -o StrictHostKeyChecking=accept-new -T git@github.com
   # Hi 1apx-codebase! You've successfully authenticated, but GitHub does not provide shell access.
   ```

4. Create an **empty, private** repo named `ubuntu` under `1apx-codebase` on github.com. Leave out the README, `.gitignore` and license so the first push doesn't conflict.

5. Set up the local repo and push it:

   ```bash
   cd ~/codebase/github/ubuntu
   git init -b main
   git config user.name "Virgil Aviles"
   git config user.email "virgil.aviles@proton.me"
   git add README.md apply-changes.sh revert-changes.sh
   git commit -m "Document k8-control Ubuntu post-install changes"
   git remote add origin git@github.com:1apx-codebase/ubuntu.git
   git ls-remote origin          # fails with "Repository not found" if the repo doesn't exist yet
   git push -u origin main
   ```

### Push later changes

```bash
cd ~/codebase/github/ubuntu
git add -A
git commit -m "Describe the change"
git push
```

### Check the setup

```bash
git remote -v                     # origin points at git@github.com:1apx-codebase/ubuntu.git
git status -sb                    # "## main...origin/main" means you're in sync
ssh -T git@github.com             # confirms the key still works
```

To confirm the repo is private, check whether it's visible without logging in. A `404` means private, and `200` means public.

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://github.com/1apx-codebase/ubuntu
```

The GitHub CLI (`gh`) is installed on this machine but not logged in. The SSH setup above doesn't need it.

