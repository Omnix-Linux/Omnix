# Desktop naming policy

Use these names in installer menus, desktop metadata, documentation, examples,
website copy, and demos:

| Desktop | Display name | Prose |
|---|---|---|
| Hyprland with Omarchy | **Hyprland - Omarchy** | **Omarchy** |
| KDE Plasma with Atrium | **KDE Plasma - Atrium** | **KDE Plasma - Atrium** |

Append `(stable)` or `(latest)` when distinguishing the Omarchy variants.
Autarchy is retired as a product name. Do not use it in labels, headings, or prose.

## Compatibility identifiers

Existing identifiers are compatibility details, not display names. Keep them
working until a separately tested migration replaces them:

- Installer IDs: `autarchy-stable`, `autarchy-latest`, `atrium`.
- Flake sources: `github:Omnix-Linux/Autarchy`, `github:Omnix-Linux/Atrium`.
- Existing module filenames, systemd unit names, first-run state markers, and
  `org.omnix.atrium.desktop`.

Do not rename a source URL unless its destination exists. Do not rename the
first-run state marker without a migration: reseeding an existing desktop can
change a user's theme. Public interfaces should display the desktop name rather
than these internal identifiers.

Run `python3 tests/test_flavor_names.py` after changing registry labels or
installer selection. It verifies display names and existing unattended IDs.
