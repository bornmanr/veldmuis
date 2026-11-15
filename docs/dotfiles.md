# Restoring Dotfiles

`veldmuis-dotfiles` is an optional package that provides `chezmoi` and a small
helper for cloning a personal dotfiles repository into a new Veldmuis account.
It is generic: no repository is embedded, and nothing is applied until the user
runs the helper.

The package is not part of the default install. Install it with:

```text
sudo pacman -S veldmuis-dotfiles
```

or select **Dotfiles restore** in the installer's Extras step.

## What It Manages

Only portable user configuration. Typical contents:

- Shell and environment files (`~/.bashrc`, `~/.config/fish`, and similar).
- Git configuration.
- Editor, terminal, and agent configuration.
- KDE and GTK user configuration.
- User scripts in `~/.local/bin`.
- systemd user units in `~/.config/systemd/user`.

It does not manage packages, secrets, application profiles (browsers, Steam,
chat clients, game launchers), or user data. Keep those in a package manifest,
an encrypted secret backup, and a normal data backup.

## Usage

```text
veldmuis-dotfiles init git@github.com:you/dotfiles.git
```

`init` accepts a full git URL, `owner/repo`, or a GitHub username. A username
resolves to `https://github.com/<user>/dotfiles.git`.

The helper checks that the repository is readable, clones it with
`chezmoi init`, prints `chezmoi status` and `chezmoi diff`, and applies only
after confirmation. Applying may run scripts from the repository, so review the
diff first.

For a private repository, authenticate before running `init`:

- SSH: create a key, add the public half to GitHub, and make sure ssh-agent has
  it.
- HTTPS: run `gh auth login` and `gh auth setup-git`.

After initialization:

```text
veldmuis-dotfiles diff
veldmuis-dotfiles apply
veldmuis-dotfiles status
veldmuis-dotfiles update
```

`update` pulls the latest repository changes and applies them. If you change a
managed file later, record it with `chezmoi add <path>` so the repository keeps
the new state.

## Desktop Entry

The package installs a **Restore Dotfiles** entry in the application menu. It
opens a terminal and runs `veldmuis-dotfiles init`. It does not run at login.

## Restoring A Machine

1. Install Veldmuis and create the user.
2. Install `veldmuis-dotfiles`.
3. Authenticate for the dotfiles repository.
4. Run `veldmuis-dotfiles init <repository>`.
5. Restore packages, secrets, and user data separately.
