# Otzar Hachochma Filter

Turns a Windows 11 Pro PC into a locked-down **Otzar Hachochma kiosk**: it creates a
passwordless standard user that can run **only Otzar Hachochma** (and receive incoming
**AnyDesk** support), with everything else blocked. Your administrator account is untouched.

## What it does

- Creates a **standard** user **`Otzar Hachochma`** with **no password**.
- Blocks every other program for that user (browsers, cmd/PowerShell, Task Manager,
  Settings, File Explorer, etc.) via NTFS execute-deny — the method that reliably works on Pro.
- Removes Store apps (Store, Calculator, Solitaire, Xbox, Paint, Photos, Media Player, etc.).
- Disables **Bluetooth**, Wi-Fi/network management, airplane mode, Start web-search, Win+key
  shortcuts, and the **Change Password** / **Task Manager** items on Ctrl+Alt+Del.
- Keeps **printing** working (print-only: the user can't add/remove/manage printers).
- Installs **LibreOffice** (free Word/Excel/PowerPoint) and **SumatraPDF** (PDF viewer) via
  winget and allow-lists them (printing works from both).
- Replaces the desktop with a **custom bottom launcher bar** — buttons for **Otzar Hachochma**,
  **LibreOffice**, and **PDF Viewer**. Otzar auto-launches and reopens itself ~5s after being
  closed. No Start menu / Windows taskbar / desktop icons.
- Pre-sets the `OTZARAPP` / `OTZARAPPCD` environment variables so Otzar never triggers its
  elevated `ovarsfix.bat` (no UAC prompt at boot).

## Requirements

- Windows 11 **Pro**.
- An **administrator** account to run this from (this is your management / escape-hatch account).
- Otzar Hachochma already **installed** on the machine (app under `C:\otzarApp`, launcher/
  desktop shortcut resolvable), and its book drive present as `D:\`.
- **AnyDesk** installed with **unattended access** configured (so you can remote in) — optional
  but recommended, since the kiosk has no other remote path.

## How to run (on the admin account)

1. Sign in to your **administrator** account.
2. Copy this whole folder to the PC (e.g. `Downloads`).
3. Open **PowerShell as Administrator** (right-click Start -> "Terminal (Admin)" / "PowerShell (Admin)").
4. Go to the folder and allow the scripts to run for this session:
   ```powershell
   cd "$env:USERPROFILE\Downloads\Otzar Hachochma Filter"
   Set-ExecutionPolicy -Scope Process Bypass -Force
   ```
5. **Preview** what will be blocked (optional, changes nothing):
   ```powershell
   .\setup.ps1 -ListOnly
   ```
6. **First run** — creates the account + applies the machine-wide lockdown:
   ```powershell
   .\setup.ps1
   ```
7. **Log into the `Otzar Hachochma` account once** (it has no password). This builds its
   user profile and lets Otzar do its first-run setup. Then **sign out**.
8. Back on the admin account, **run it again** to apply the kiosk shell + per-user policies:
   ```powershell
   .\setup.ps1
   ```
9. **Reboot.** Sign into `Otzar Hachochma` — it should boot straight into Otzar, fullscreen,
   with nothing else reachable.

> The two-step (run -> log in once -> run again) is needed because the per-user policies and
> kiosk shell live in the account's profile, which doesn't exist until its first logon.

## Escape hatch (how you, the admin, get back in)

From the kiosk: **`Ctrl+Alt+Del` -> Switch user -> sign into your admin account.**
That always works (it's handled by Windows, not the kiosk shell). AnyDesk incoming also
works as a remote path.

## Uninstall

From the same folder, in an elevated PowerShell:
```powershell
.\uninstall.ps1                  # undo the lockdown, KEEP the account + its data
.\uninstall.ps1 -RemoveAccount   # undo the lockdown AND delete the account
```
Reboot afterward.

## Customizing

`setup.ps1` has parameters at the top if paths differ on your machine:

| Parameter        | Default                                             | Purpose |
|------------------|-----------------------------------------------------|---------|
| `-OtzarUser`     | `Otzar Hachochma`                                   | Kiosk account name |
| `-OtzarData`     | `C:\OtzarApp`                                        | Otzar's profile/cache (needs user write) |
| `-OtzarAppVar`   | `C:\otzarApp\otzarLocal`                             | `OTZARAPP` value |
| `-OtzarAppCdVar` | `C:\otzarApp\otzarLocal\launcher\bin\x64\app`        | `OTZARAPPCD` value |
| `-ShellLnk`      | `...\Otzar Hachochma\Desktop\Otzar Hachochma.lnk`   | Shortcut used to find the Otzar exe |
| `-AllowFolders`  | `D:\`                                                | Folder(s) allowed to run (the Otzar drive) |

Example: `.\setup.ps1 -AllowFolders "E:\"` if the Otzar drive is `E:`.

## Notes

- **AnyDesk**: the user can't *open* AnyDesk, but the AnyDesk **service** keeps accepting
  incoming connections (it runs as SYSTEM), so your remote support still works.
- **`cmd.exe` is intentionally allowed** — Otzar (an Electron app) spawns it at startup. The
  user still has no way to launch a command prompt (no shell UI, no Run, no Task Manager).
- Only the `Otzar Hachochma` account is affected. Your admin account is completely normal.

## License

Licensed under the **PolyForm Noncommercial License 1.0.0** (see `LICENSE`).
You may **use, modify, and share** these scripts for any **noncommercial** purpose
(personal use, a shul/nonprofit, education, research). **Commercial use — including
selling them or bundling them into a paid product or service — is not permitted.**
