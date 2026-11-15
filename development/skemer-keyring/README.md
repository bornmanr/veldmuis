# Skemer release keyring

Veldmuis vendors the public Skemer release key here so
`development/resolve-skemer-release.sh` can verify a Skemer release before it
pins `packages/veldmuis-skemer/PKGBUILD`.

Required files:

- `skemer-release.gpg` — binary keyring, copied from the Skemer repository's
  `packaging/keys/skemer-release.gpg`.
- `skemer-trusted` — primary fingerprint, copied from
  `packaging/keys/skemer-trusted`.

The private key is never stored here. The Skemer release workflow receives it
through the protected `release` environment in the Skemer repository.

Until these files exist, `Skemer Release Watch` skips its run and
`resolve-skemer-release.sh --update-package` refuses to pin a release.

See `packaging/keys/README.md` in the Skemer repository for key creation,
verification, and rotation.
