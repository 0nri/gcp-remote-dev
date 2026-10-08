# Connecting from Termius on iOS

This guide sets up [Termius](https://termius.com/) on iPhone/iPad to reach the remote dev VM. You can use it to check on a long-running build, or to start and resume an `agy` session from your phone.

The VM is the same one every other client uses (VS Code, Mac terminal, …). Only the client setup below is specific to Termius.

## Requirements

- **The VM must be provisioned with `ACCESS_MODE="public"`** (or `./provision.sh --access=public`).
  > IAP mode is **not supported** from iOS. IAP tunnelling needs `gcloud compute start-iap-tunnel` on the client, and iOS has no `gcloud`.
- The VM's static IP, which `provision.sh` prints. You can also look it up:
  ```bash
  gcloud compute addresses describe <VM_NAME>-ip --region=<REGION> --format='value(address)'
  ```
- Access to the Mac (or other machine) where you run `provision.sh`, to authorize the phone's key.

## 1. Generate a key on the phone

Generate the key **inside Termius** so the private key never leaves the device. Don't copy a private key over from your Mac.

1. Tap `<` to open **Vaults**, then **Keychain**.
2. Tap **`+`**, then **Generate Key**.
3. Choose a key type:
   - **Biometric key** (recommended): stored in the Secure Enclave, can't be exported, and each use needs Face ID / Touch ID.
   - **Ed25519**: set a passphrase, and optionally turn on *Save passphrase*.
4. Label it (e.g. `iphone-remote-dev`) and **Save**.
5. Open the key and copy its **public key** (the line that starts with `ssh-ed25519` or `ecdsa-sha2-nistp256`).

## 2. Authorize the key on the VM

Get the public key to your Mac (AirDrop, Notes, email; it isn't secret). Then:

```bash
echo 'ssh-ed25519 AAAA... iphone-remote-dev' >> authorized_keys   # SSH_KEYS_FILE
./provision.sh --update-keys
```

The VM's guest agent syncs the change within seconds; no restart is needed. To **revoke** the phone later, delete its line and run `--update-keys` again.

## 3. Verify the VM's host key (one time)

Termius asks you to trust the server's fingerprint on first connect. Get the real fingerprints from your Mac so you can check that you're not being intercepted:

```bash
gcloud compute instances get-guest-attributes <VM_NAME> \
  --zone=<ZONE> --query-path=hostkeys/ --format='value(key,value)' |
  while read -r type key; do echo "$type $key" | ssh-keygen -lf -; done
```

## 4. Add the host in Termius

1. On the **Hosts** screen, tap **`+`** → **New Host**.
2. Fill in:
   | Field | Value |
   |---|---|
   | Label | `remote-dev` |
   | Address | the static IP |
   | Port | `22` |
   | Username | your `VM_USER` |
   | Key | the key from step 1 (under *SSH ID, Key, Certificate, FIDO2*) |
3. Turn on **SSH Agent Forwarding** if you want git-over-SSH with the phone's keys (only works without Mosh; see step 7).
4. Turn on **Use Mosh**. Keep the default command:
   `mosh-server new -s -l LANG=en_US.UTF-8`
   The VM opens UDP **60000–60010** for Mosh, and mosh-server picks a free port in that range on its own.
5. **Save**, then tap the host to connect. Check that the fingerprint matches step 3.

## 5. First login

If this is the VM's first login from any client, run the one-time user setup:

```bash
bash ~/setup-user.sh
exec zsh
```

## 6. Keep sessions alive: tmux + agy

Mosh survives the phone locking or switching from Wi-Fi to cellular. tmux goes further: the session survives you disconnecting completely, and you can pick up the same session from another device.

```bash
tmux new -A -s main      # attach to "main", creating it if needed
agy                      # start the Antigravity CLI inside tmux
```

Detach with `Ctrl-b d`. Later, from the phone or the Mac, `tmux new -A -s main` puts you back into the same running `agy` session.

## 7. Git from the phone

- **Over plain SSH (Mosh off):** agent forwarding passes Termius's key to the VM. That key must also be added to GitHub for `git push` over SSH to work.
- **Over Mosh:** agent forwarding is **not** available. Mosh only uses SSH to start the session, and that connection then closes. Use HTTPS auth instead:
  ```bash
  gh auth login --web
  ```

## 8. Prompt glyphs (Powerlevel10k)

The shell prompt uses Nerd Font icons. If Termius shows boxes or `?` characters:

1. In Termius settings, check whether the terminal font list includes a Nerd Font, and pick it if so.
2. Otherwise, run `p10k configure` on the VM and choose a style without icons. This changes the prompt for **all** clients. Alternatively, keep the current prompt and ignore the stray glyphs on mobile.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Permission denied (publickey)` | The phone's key isn't authorized. Check it's in `authorized_keys` on the Mac, then run `./provision.sh --update-keys`. |
| `Too many authentication failures` | The server allows 3 attempts. Make sure the host uses only the one key from step 1. |
| Mosh hangs on "Connecting…" | Either UDP 60000–60010 is blocked on your current network, or old sessions are holding all the ports. Turn off Mosh, connect over SSH, and run `pkill -u $USER mosh-server`. Abandoned sessions also exit on their own after 24h without contact. |
| `mosh-server needs a UTF-8 native locale` | Check that `locale -a \| grep -i en_US.utf8` returns a result. If not, run `sudo locale-gen en_US.UTF-8`. |
| Was working, now times out | Make sure the VM is running (`gcloud compute instances list`). The static IP doesn't change across stop/start. You may also have been banned by fail2ban after 5 failed logins (the ban lasts 1h). |
