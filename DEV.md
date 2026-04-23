# Rehearsal / dev channel

This branch (`dev`) of `veric-dev/veric` is the pre-release distribution
substrate for the `veric` CLI. During the rehearsal window it carries:

- `install.sh` — curl-able installer that pulls the latest prerelease
  from this repo's GitHub Releases page. Used by:

      curl -fsSL https://raw.githubusercontent.com/veric-dev/veric/dev/install.sh | sh

- Companion Homebrew tap: <https://github.com/veric-dev/homebrew-veric-dev>

Releases on this repo are cut automatically by the `cli-release.yml`
workflow on the private source repo (`veric-dev/veric-platform`) when
a `cli-v*` tag is pushed. Rehearsal tags (`-rehearsal` suffix) produce
builds of the `veric-cli` crate with the `rehearsal-stub` feature
enabled — the resulting binary prints a banner and exits rather than
doing any real work. This lets the whole distribution chain be
validated without shipping a functional, unlicensed veric.

Once the rehearsal loop is green, the real v0.1.0 release will be cut
on the `main` branch and the installer + formula will promote from
`homebrew-veric-dev` to `homebrew-veric`. See
<https://github.com/veric-dev/veric-platform/blob/main/docs/current/distribution-rehearsal-plan.md>
(private) for the full plan.
