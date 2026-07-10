# Hardening the Otzar Hachochma Kiosk — Physical & Boot Security

`setup.ps1` locks down the **software** (the `Otzar Hachochma` account can only run Otzar,
LibreOffice, and the PDF browser). But anyone with **physical access and the ability to
reboot** could try to get around it — booting Safe Mode, the Windows Recovery Environment
(WinRE), or a USB stick. No account-level lockdown can stop that by itself. These steps close
that hole. **Do all of this on the administrator account (`khaly`), in an elevated PowerShell.**

Work top to bottom. #1 is quick; #2 (BitLocker) is the most important; #3 is in the firmware.

---

## 1. Disable the recovery environment + lock the boot menu

This removes the "Troubleshoot → Advanced options → Safe Mode / Command Prompt" path that a
user could reach with Shift+Restart, and stops the boot menu from appearing.

```powershell
reagentc /disable
bcdedit /set "{bootmgr}" displaybootmenu no
bcdedit /set "{current}" bootstatuspolicy ignoreallfailures
bcdedit /set "{current}" recoveryenabled no
bcdedit /set "{current}" bootmenupolicy Standard
```

- `reagentc /disable` — turns off WinRE (no recovery entry point).
- `displaybootmenu no` — no boot menu at startup.
- `bootstatuspolicy ignoreallfailures` — no "Windows didn't start correctly" recovery prompt
  after a bad boot (which would otherwise drop into recovery).
- `recoveryenabled no` — no automatic recovery.
- `bootmenupolicy Standard` — keeps F8 "Advanced Boot Options" **off** (Legacy would enable it).

**To reverse later:**
```powershell
reagentc /enable
bcdedit /deletevalue "{bootmgr}" displaybootmenu
bcdedit /set "{current}" recoveryenabled yes
```

---

## 2. Enable BitLocker (the big one)

BitLocker encrypts the disk. After this, booting Safe Mode / WinRE / a USB stick to tamper with
the account requires the **48-digit recovery key** — without it the drive is unreadable. This is
the single strongest protection.

**BACK UP THE RECOVERY KEY BEFORE YOU START** — if you lose it and something goes wrong, the
data is gone. Print it or store it somewhere safe (not on this PC).

```powershell
# 1) Confirm the machine has a TPM (needed for smooth, password-free boot)
Get-Tpm      # TpmPresent / TpmReady should be True

# 2) Turn on BitLocker for C: with a TPM protector
Enable-BitLocker -MountPoint "C:" -EncryptionMethod XtsAes256 -UsedSpaceOnly -TpmProtector

# 3) Add a recovery-key protector
Add-BitLockerKeyProtector -MountPoint "C:" -RecoveryPasswordProtector

# 4) SHOW THE RECOVERY KEY - write it down / save it off the machine
(Get-BitLockerVolume -MountPoint "C:").KeyProtector |
    Where-Object KeyProtectorType -eq 'RecoveryPassword' |
    Select-Object KeyProtectorId, RecoveryPassword
```

- Encryption starts in the background; the PC stays usable.
- With a TPM, it boots straight to Windows (no daily password); the recovery key is only asked
  for if the disk/firmware is tampered with — exactly what we want.
- If `Get-Tpm` shows no TPM, BitLocker will ask for a startup password on every boot instead —
  ask before going that route.

---

## 3. BIOS / UEFI settings (in firmware — reboot into BIOS to set)

Software can't stop someone from changing the boot device in firmware. Set these once:

1. **Set a BIOS/UEFI supervisor (admin) password** — stops changing firmware settings.
2. **Disable USB boot / removable boot**, or set the **boot order to the internal disk only** —
   stops booting another OS off a USB stick.
3. **Enable Secure Boot** — blocks unsigned/rogue boot loaders.

(Enter BIOS with the key shown at power-on — usually Del, F2, F10, or F12.)

---

## Recovery / "break glass"

Keep these somewhere safe so **you** are never locked out:

- The **`khaly` admin password**.
- The **BitLocker recovery key** (from step 2).
- The **BIOS password** (step 3).

With those, you can always get back in, un-harden (`reagentc /enable`, suspend BitLocker with
`Suspend-BitLocker -MountPoint C:`), or run `uninstall.ps1`.

---

## Order of operations for a fresh kiosk

1. `create.ps1` → log into Otzar with `1234` → sign out
2. `setup.ps1` → reboot → verify the kiosk works
3. This doc: **#1** (disable recovery), **#2** (BitLocker + save the key), **#3** (BIOS lock)
4. Done — software + physical lockdown complete.
