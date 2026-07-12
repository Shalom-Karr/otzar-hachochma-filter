# Changelog

## 1.0.0

- **Auto-update:** `create.ps1` and `setup.ps1` now check GitHub on startup and, if a newer
  `VERSION` exists on `main`, download it and re-run themselves (offline-safe; no `git`
  required on the target machine). Added `updater.ps1`, a `VERSION` file, and a `-NoUpdate`
  switch to opt out. Skipped for `setup.ps1 -ListOnly` / `-Undo`.
