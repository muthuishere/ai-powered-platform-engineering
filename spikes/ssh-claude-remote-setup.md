# Passwordless SSH + `claude` (subscription) on the MacBook

Goal: from another machine on the same WiFi, SSH into this Mac and run `claude`
(subscription login) **without typing passwords**, and **without "broken pipe"
disconnects**.

This Mac (the SSH **server**):
- **Host:** `Muthukumarans-MacBook-Pro-2.local`
- **IP:** `192.168.29.202`
- **User:** `muthuishere`

---

## ✅ Already done on this Mac (server side)

| Step | Status | What was done |
|------|--------|---------------|
| SSH keypair generated | ✅ | `~/.ssh/id_ed25519_remote` (+ `.pub`), no passphrase |
| Public key installed | ✅ | Appended to `~/.ssh/authorized_keys` (perms 700/600) |
| Key auth verified | ✅ | Loopback test returned `KEY_AUTH_WORKS` |
| `PubkeyAuthentication` | ✅ | Default `yes` (macOS) — no change needed |
| Keychain auto-lock | ✅ | `security set-keychain-settings` → **no-timeout** (won't relock on idle/sleep) |
| `ukc` alias added | ✅ | In `~/.zshrc`: unlocks keychain on demand if ever needed |

---

## 🔧 To finish — run these (some need YOUR password once)

### 1. Client side: install the private key
On the machine you connect **from**:

```sh
nano ~/.ssh/id_ed25519_remote      # paste the private key block, save
chmod 600 ~/.ssh/id_ed25519_remote
```

Then add a shortcut — append to the client's `~/.ssh/config`:

```
Host macbook
  HostName 192.168.29.202
  User muthuishere
  IdentityFile ~/.ssh/id_ed25519_remote
  ServerAliveInterval 60
  ServerAliveCountMax 10
  TCPKeepAlive yes
```

> `ServerAlive*` = the **broken-pipe fix** from the client side. Sends a heartbeat
> every 60s so idle connections don't drop.

Now connect with just:

```sh
ssh macbook
```

### 2. Broken-pipe fix — server side (needs sudo, run on this Mac)
```sh
echo "ClientAliveInterval 60
ClientAliveCountMax 10" | sudo tee /etc/ssh/sshd_config.d/200-keepalive.conf

sudo launchctl kickstart -k system/com.openssh.sshd
```

### 3. Passwordless sudo (optional, run on this Mac)
So `sudo` never prompts:

```sh
echo "muthuishere ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/muthuishere-nopasswd
sudo chmod 440 /etc/sudoers.d/muthuishere-nopasswd
sudo visudo -c          # validate syntax
```

> ⚠️ Anyone with shell access as `muthuishere` gets root with no password.
> Fine for a personal LAN box; reconsider if this Mac is ever exposed.

### 4. Auto-login — INTENTIONALLY SKIPPED (security)
We are **not** enabling auto-login. It's too vulnerable: anyone with physical
access would boot straight into an unlocked session + keychain.

Trade-off: after a **reboot**, the login keychain stays locked until someone
logs into the desktop. So `claude` over SSH will say "not logged in" until you
unlock it once with `ukc` (see below). Since the keychain is set to no-timeout,
that's only **once per reboot**.

---

## ✅ Daily use after setup

Normal day (no reboot since last unlock):
```sh
ssh macbook        # no password (SSH key)
claude             # logged in
```

First connection **after a reboot** (keychain locked):
```sh
ssh macbook        # no password (SSH key)
ukc                # unlock keychain — enter Mac password ONCE
claude             # logged in; stays unlocked for all later sessions
```

---

## Quick troubleshooting

| Symptom | Fix |
|---------|-----|
| SSH still asks password | Private key not at `~/.ssh/id_ed25519_remote` on client, or wrong perms (`chmod 600`). Test: `ssh -v macbook` |
| `claude` "not logged in" | Run `ukc`; ensure Mac is GUI-logged-in (auto-login) |
| "broken pipe" / drops | Confirm step 1 (client `ServerAlive*`) **and** step 2 (server `ClientAlive*`) applied |
| `sudo` still prompts | Step 3 not applied or sudoers syntax error (`sudo visudo -c`) |
