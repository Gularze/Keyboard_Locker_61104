# Changelog

## 0.1alpha - unreleased

- **Feature**: major script rewrite to allow for custom passwords, including capitals and special characters
- **Feature**: added a context menu item to the tray icon to lock and unlock without using the keyboard
- **Feature**: optionally disable the built-in touchpad together with the keyboard (external mice remain usable); requires administrator rights and auto-detects the touchpad device
- changed the keyboard shortcut from Ctrl+Alt+L to Ctrl+Alt+K
- refactored parts of the code for maintainability
- **Fix**: updated keyboard hooks to fix "password input not working in Windows 10"
- **Fix**: improved loading of tray icons to fix "script crashes when run from the task bar"
