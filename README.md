<div align="center">
  <img src="./.github/assets/icon.png" alt="Morphed" width="72">
  <img src="./.github/assets/icon1.png" alt="Morphed" width="72">
  <h1>Morphed</h1>
  <p><strong>Automated arm64-v8a APK builds for YouTube, YouTube Music, Reddit, TikTok, and X.</strong></p>
</div>

<p align="center">
  <a href="https://github.com/Psyquix/Morphed/releases/latest"><img src="https://img.shields.io/github/v/release/Psyquix/Morphed?label=latest&style=flat-square" alt="Latest release"></a>
  <a href="https://github.com/Psyquix/Morphed/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/Psyquix/Morphed/ci.yml?label=CI&style=flat-square" alt="CI"></a>
  <a href="https://github.com/Psyquix/Morphed/releases"><img src="https://img.shields.io/github/downloads/Psyquix/Morphed/total?label=downloads&style=flat-square" alt="Downloads"></a>
</p>

Morphed is a personal APK builder. It watches the patch sources and app versions used by this repository, builds the matching APKs on GitHub Actions, and publishes them to [Releases](https://github.com/Psyquix/Morphed/releases).

- **Architecture:** `arm64-v8a` only
- **Format:** APK only
- **Patch channels:** stable and beta
- **App variants:** stable and experimental, where available
- **Builds:** fully automated, with Manual CI available for on-demand runs

## 📥 Download

Download the latest APKs from **[Releases](https://github.com/Psyquix/Morphed/releases)**.

Each release contains separate files for the app variants that were built. Experimental builds appear only when the patch source and the installed app version are compatible.

## 📱 Supported apps

| App | Patch source | Stable | Experimental |
|---|---|---|---|
| YouTube | [MorpheApp/morphe-patches](https://github.com/MorpheApp/morphe-patches) | ✅ | ✅ |
| YouTube Music | [MorpheApp/morphe-patches](https://github.com/MorpheApp/morphe-patches) | ✅ | ✅ |
| Reddit | [MorpheApp/morphe-patches](https://github.com/MorpheApp/morphe-patches) | ✅ | ✅ |
| TikTok | [SysAdminDoc/hushfeed](https://github.com/SysAdminDoc/hushfeed) | ✅ | — |
| X (Twitter) | [crimera/piko](https://github.com/crimera/piko) | ✅ | — |

TikTok and X do not currently have a compatible experimental app version. Their stable builds are still produced.

## ⚙️ How it works

1. The scheduled **CI** workflow checks the configured patch sources and app versions.
2. When a new patch release or supported app version appears, it starts a **Build** run.
3. The build workflow fetches this repository's configuration from the `data` branch, downloads the stock APK, applies the patches, signs the result, and uploads the APK to a GitHub Release.
4. **Manual CI** can be started at any time from the Actions tab with `configs/config.manual.toml` or one of the generated build pools.

### Branches

| Branch | Contents |
|---|---|
| `main` | Builder code, workflows, scripts, documentation |
| `data` | App configuration and CI state |
| `website` | Release manifests and cumulative archives |
| `update` | Module changelog and update files |

`configs/` and `state/` are intentionally not tracked on `main`; they are materialized from `data` by the workflows.

## 🛠️ Configuration

App definitions live on the `data` branch in `configs/patches/*.toml`. `configs/config.manual.toml` is a standalone configuration used by Manual CI.

```bash
git switch main
bash .github/scripts/fetch_data_branch.sh

# edit configs/patches/*.toml and/or configs/config.manual.toml

python3 .github/scripts/compile_patch_configs.py
bash .github/scripts/push_data_configs.sh "feat(configs): update app configuration"
```

`fetch_data_branch.sh` overwrites the local `configs/` directory, so publish your edits before fetching again. `push_data_configs.sh` adds or updates TOML files; it does not delete files. Remove a whole patch source on the `data` branch explicitly if you want it gone.

The full key reference is in [CONFIG.md](CONFIG.md), and the builder internals are documented under [docs/](docs/).

## 🙏 Credits

- Builder architecture based on [nullcpy/rvb](https://github.com/nullcpy/rvb) and its upstream contributors.
- Patches by [MorpheApp](https://github.com/MorpheApp/morphe-patches), [SysAdminDoc/hushfeed](https://github.com/SysAdminDoc/hushfeed), and [crimera/piko](https://github.com/crimera/piko).
- Thanks to the ReVanced project and the wider Android modding community for the tools and documentation that make builds like this possible.

## ⚠️ Disclaimer

These are unofficial builds. This repository is not affiliated with Google, Reddit, TikTok, X, MorpheApp, hushfeed, Piko, or ReVanced. Use the builds at your own risk; patched apps can break, and modifying an app may violate its terms of service. Only build and install apps you have the right to modify.
