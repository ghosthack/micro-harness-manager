# Packaging and releases

`scripts/package.sh` builds a self-contained app image with jpackage, smoke-tests it,
and wraps it in the platform's installer:

```sh
scripts/package.sh all 1.2.3          # app image + installer for this OS
scripts/package.sh app-image 1.2.3    # just the app image
scripts/package.sh installer 1.2.3    # installer from an existing app image
```

Output goes to `target/jpackage/release`:

| Platform | Files |
|---|---|
| macOS (arm64) | `micro-harness-manager-X.Y.Z-macos-arm64.dmg` |
| Windows (x64) | `…-windows-x64.exe` installer and `…-windows-x64.zip` portable |
| Linux (x64) | `…-linux-x64.deb` and `…-linux-x64.tar.gz` portable |

Every platform also gets `…-licenses.zip`: the project's license, its dependencies'
licenses and the bundled Java runtime's legal files.

The image holds two launchers: the app, and `microhm-mux`, the daemon CLI. The app
starts the session daemon through `microhm-mux`. The bundled runtime keeps
`bin/java`, because on macOS every session starts through a small JVM that takes the
controlling terminal.

The app's launcher also names a JDK AOT cache, which roughly halves the time to a
visible window: `-XX:AOTCache=$HOME/.micro-harness-manager/aot/microhm-VERSION.aot`
(`$USERPROFILE` on Windows; the launcher expands the variable, and `-Xlog:aot=off` keeps
the JVM quiet while the file is missing). The app makes the file itself, in the background,
about ten seconds after its first launch of each version: a second JVM records a start of
the app without showing a window, then assembles the cache (about 40 MB), starts the app
once more with it (the same window-less run), and only then moves it into place. A cache
the JVM cannot start with would keep the app from opening at all, so one that fails that
check is discarded: the app then tries a cache without AOT-linked classes (JDK 26.0.2
cannot start with linked ones), and when that fails too, marks the version and stops
trying. Older versions' caches are deleted. Nothing is shipped in the download. Settings →
Performance… shows whether this launch used it.

`scripts/smoke-package.sh` checks a built image: the launchers, license files and
runtime modules, the app's `--package-smoke` (look and feel, resources, JSON and the
HTTP stack the MCP server uses, and the AOT cache path the launcher expanded), and a
real session through the packaged daemon.
`scripts/smoke-windows-installer.ps1` installs, optionally upgrades, runs and
uninstalls the Windows installer.

The installers' icons come from `packaging/icons`; see [icons/README.md](icons/README.md)
for how they are made and the earlier designs.

Versions are numeric `X.Y.Z` with `X >= 1` (jpackage rejects a leading 0). Local
builds default to 1.0.0; the Maven version comes from `-Drevision`.

## Releasing

`.github/workflows/release.yml` runs on a pushed `vX.Y.Z` tag, or by hand:

1. Dry run: Actions → Release → Run workflow on `main` with `publish=false`. It tests on
   all three platforms, then packages, signs and smoke-tests each one, and keeps the
   packages as workflow artifacts for 7 days.
2. Release: tag the reviewed commit and push the tag:
   `git tag v1.2.3 && git push origin v1.2.3`. The same jobs run, then a GitHub
   Release with every package and `SHA256SUMS` is published. An existing version is
   never replaced.

## Signing

Signing runs in two protected GitHub environments.

**`release`** (macOS): `MACOS_CERTIFICATE_BASE64` (a Developer ID Application `.p12`,
base64), `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGNING_IDENTITY` (the full
`Developer ID Application: …` name), `MACOS_NOTARY_APPLE_ID`, `MACOS_NOTARY_PASSWORD`
(an app-specific password) and `MACOS_NOTARY_TEAM_ID`. Without the certificate the DMG
is built unsigned; without the notary secrets it is signed but not notarized.

**`release-signing`** (Windows, Azure Artifact Signing over GitHub OIDC; no keys in
GitHub): secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` and
variables `ARTIFACT_SIGNING_ENDPOINT`, `ARTIFACT_SIGNING_ACCOUNT`,
`ARTIFACT_SIGNING_PROFILE`. The Azure app registration needs a federated credential
for this repository's environment. The repository uses immutable OIDC subjects, so the
subject is:

```sh
gh api repos/ghosthack/micro-harness-manager/actions/oidc/customization/sub \
  --jq '.sub_claim_prefix + ":environment:release-signing"'
```

with issuer `https://token.actions.githubusercontent.com` and audience
`api://AzureADTokenExchange`.

Never commit certificates, passwords or Azure identifiers. Set secrets with
`gh secret set NAME --env ENV` at its prompt, or pipe a file into it.
