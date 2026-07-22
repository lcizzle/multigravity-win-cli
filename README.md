![Multigravity](assets/multigravity-logo.jpg)

# Multigravity Win CLI (Redux)

**Run multiple Antigravity IDE profiles simultaneously — each with its own accounts, extensions, and settings. For real this time.**

No more logging in and out. Launch as many profiles as you need, all at once.

[![GitHub repository](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/lcizzle/multigravity-win-cli)
[![GitHub profile](https://img.shields.io/badge/GitHub-Profile-lightgrey?logo=github)](https://github.com/lcizzle)
[![GitHub stars](https://img.shields.io/github/stars/lcizzle/multigravity-win-cli?style=social)](https://github.com/lcizzle/multigravity-win-cli/stargazers)
[![Platform](https://img.shields.io/badge/platform-Windows-lightgrey)](#install)

---

## Install

**Windows** — open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/lcizzle/multigravity-win-cli/refs/heads/main/install.ps1 | iex
```

---

## Quick Start

```powershell
# Create profiles
multigravity new work
multigravity new personal

# Launch a profile
multigravity work

# Pass arguments straight through to Antigravity
multigravity work .
multigravity work path/to/project
multigravity work --new-window
```

Each profile gets an automatic clickable launcher:

| Platform | Location |
|----------|----------|
| Windows  | Start Menu → Programs |

---

## Commands

### Profile Management

| Command | Description |
|---------|-------------|
| `multigravity new <name>` | Create a new full profile |
| `multigravity new <name> --shared` | Create a lightweight profile (shared extensions & settings, isolated accounts) |
| `multigravity new <name> --from <template>` | Create a profile from a saved template |
| `multigravity <name>` | Launch a profile |
| `multigravity list` | List all profiles |
| `multigravity status` | Show running state, type, last used, and size per profile |
| `multigravity clone <src> <dest>` | Copy an existing profile |
| `multigravity rename <old> <new>` | Rename a profile |
| `multigravity delete <name>` | Delete a profile and all its data |

### Templates

| Command | Description |
|---------|-------------|
| `multigravity template save <profile> <name>` | Save a profile as a reusable template |
| `multigravity template list` | List saved templates |
| `multigravity template delete <name>` | Remove a template |

### Backup & Transfer

| Command | Description |
|---------|-------------|
| `multigravity export <name> [path]` | Archive a profile to `.zip`  |
| `multigravity import <archive> [name]` | Restore a profile from an archive |

### Utilities

| Command | Description |
|---------|-------------|
| `multigravity stats` | Show disk usage per profile |
| `multigravity doctor` | Diagnose your environment |
| `multigravity update` | Update Multigravity to the latest version |
| `multigravity completion` | Set up shell tab-completion |
| `multigravity help` | Show help |

---

## Shared Profiles

Full profiles are fully isolated — separate extensions, settings, and accounts. That's the default.

**Shared profiles** go lighter: they symlink extensions and settings from your main Antigravity install, isolating only the account/auth layer. Useful when you need a second account but don't want to duplicate gigabytes of extensions.

```powershell
multigravity new client-x --shared
```

---

## Templates

Save a configured profile as a template, then spin up new profiles from it instantly:

```powershell
# Save your ideal setup as a template
multigravity template save work base

# Create new profiles from it
multigravity new project-a --from base
multigravity new project-b --from base

# See what templates you have
multigravity template list
```

---

## Shell Completion

Enable tab-completion for commands and profile names:

```powershell
multigravity completion
```

Follow the instructions to add it to your  PowerShell `$PROFILE`.

---

## Uninstall

**Windows**

```powershell
irm https://raw.githubusercontent.com/lcizzle/multigravity-win-cli/main/uninstall.ps1 | iex
```

You'll be asked whether to remove your profile data — nothing is deleted without confirmation.

---

## Profile Name Rules

Letters, numbers, and hyphens only. Must start with a letter or number.

```
✅  work   client-a   test1
❌  -name  my_profile
```

---