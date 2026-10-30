<div align="center">

# GKI KernelSU SUSFS

**Automated GKI Kernel Builds | SukiSU / BakaSU / FinaSU + SUSFS Integration**

[![Release](https://img.shields.io/github/v/release/LingLuo17/AnyKernel3?label=Release&style=flat-square&logo=github&logoColor=white&color=2ea44f)](https://github.com/LingLuo17/AnyKernel3/releases)
[![Coolapk](https://img.shields.io/badge/Follow-Coolapk-3DDC84?style=flat-square&logo=android&logoColor=white)](http://www.coolapk.com/u/38407386)
[<img src="https://img.shields.io/badge/Join-QQ%20Group-blue?style=flat-square&logo=github&logoColor=white">](https://qm.qq.com/q/PZIFvlcbqU)
[![SukiSU](https://img.shields.io/badge/SukiSU-Supported-5AA300?style=flat-square)](https://sukisu.org/)
[![BakaSU](https://img.shields.io/badge/BakaSU-Supported-5AA300?style=flat-square)](https://bakasu.org/)
[![FinaSU](https://img.shields.io/badge/FinaSU-Supported-5AA300?style=flat-square)](https://github.com/LyraVoid/FinaSU)
[![SUSFS](https://img.shields.io/badge/SUSFS-Integrated-E67E22?style=flat-square)](https://gitlab.com/simonpunk/susfs4ksu)

**English** | [English translation](#english-translated)

</div>

## 📖 Introduction

Built upon [AnyKernel3](https://github.com/osm0sis/AnyKernel3), this repository uses GitHub Actions to automatically compile Android GKI kernels. It integrates multiple KernelSU variants and SUSFS kernel-level spoofing solutions, along with practical patches such as ZRAM and BBG.

- The build workflows are adapted from [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) and [Wild Kernels](https://github.com/WildKernels/GKI_KernelSU_SUSFS)
- Flashing rule: ***It can be flashed as long as the kernel version matches.***

## 📦 Supported Kernel Versions

| Android | Kernel Version | Manual Workflow |
|:---:|:---:|:---:|
| 12 | 5.10 | `kernel-a12-5-10.yml` |
| 13 | 5.15 | `kernel-a13-5-15.yml` |
| 14 | 6.1 | `kernel-a14-6-1.yml` |
| 15 | 6.6 | `kernel-a15-6-6.yml` |
| 16 | 6.12 | `kernel-a16-6-12.yml` |
| Custom | Any | `kernel-custom.yml` |

## ✨ Features

| Feature | Description |
|:---|:---|
| 🔐 KernelSU Variants | Supports SukiSU / BakaSU / FinaSU variants, selectable at build time |
| 🔀 Build Channel | Release: latest **stable** upstream Release (tag commit + same-version manager), falls back to the newest official default-branch build when the upstream only ships pre-releases; Latest: pins the default-branch HEAD and picks the newest manager build matching that version |
| 🙈 SUSFS | Kernel-level hiding working with KSU to complete environment spoofing |
| 💾 ZRAM LZ4 | ZRAM Compression Algorithm Patch |
| 🛡️ BBG (Baseband Guard) | BBG patch to protect the baseband partitions from accidental wipe |
| 🌐 Network enhancement | Optional network stack upgrade: BBRv3 backport where available (defaults to BBR v1 otherwise), full IPSet types up to 65534 sets, fq/fq_codel/cake qdisc, connmark, IPv6 NAT/masquerade, TTL/HopLimit match, WireGuard, CIFS |
| ⚡ KPM | Optional KPM feature / build-time patching |
| 🔔 Re-Kernel | Optional Re-Kernel driver integration |
| 🩹 CVE-2026-43499 | Optional automatic application of the rtmutex fix |
| 📱 OnePlus Snapdragon 8 Elite / Gen5 Support | Optional: Add support for OnePlus Snapdragon 8 Elite / Gen5 processor |
| 🐳 Droidspaces | Optional container support with NTSync kernel compatibility patch |
| 🧩 Skip Incompatible | Optional: auto-skip incompatible or unusable features (except SUSFS and OnePlus 8 Elite/Gen5 support) instead of failing the build |

## 🚀 Usage

1. **Fork this repository** (or use it directly)
2. Go to the **Actions** page and pick the workflow for your kernel version
3. Click **Run workflow** and fill in the parameters as needed:
   - `android_version` / `kernel_version` / `sub_level` / `os_patch_level`
   - `ksu_variant`: KernelSU variant (SukiSU / BakaSU / FinaSU)
   - `build_channel`: build channel
     - `Stable (Release)`: manager APK taken from the latest **stable** upstream Release (`prerelease=false`) and the kernel pinned to that release tag commit, so manager and kernel versions match exactly; when the upstream only ships rc/pre-releases (e.g. BakaSU), the newest official default-branch build is used and pinned instead
     - `Latest (HEAD)`: kernel pinned to the default-branch HEAD, and the manager is the newest build whose version matches HEAD (any branch; SukiSU / BakaSU use official CI builds, FinaSU uses the latest Release), so kernel and manager never drift apart
     - Both channels print the selected channel, pinned commit and manager version in the logs and the run summary
   - Feature switches: `enable_susfs`, `use_zram`, `use_bbg`, `use_net_enhance`, `use_kpm`, `skip_incompatible`, etc.
4. Once the build finishes, download the **Artifacts** from the run page:
   - `AnyKernel3.zip` — flashable zip (recommended; flash via custom Recovery or KSU)
   - `boot.img` / `boot-gz.img` / `boot-lz4.img` — boot images for each compression format

> 💡 Artifacts are uploaded as Actions Artifacts by default and are not auto-published as Releases. Failed runs additionally upload build logs (`Build-Logs`) and patch conflict records (`Rejects`) for troubleshooting.

## 🔧 Custom Commit Configuration

The [`config/config`](config/config) file lets you pin specific commits for SUSFS and SukiSU.

**What is a commit?**

A commit is a hash string representing the state of a repository at a certain point in time. For example, setting SukiSU to `4b8644515fe6d87a109129e590ccd9d33a855dca` means the kernel will be built with the SukiSU version from January 30.

**Why pin a commit?**

- Roll back to a stable version when upstream updates introduce bugs or compatibility issues
- Manually specify a compatible version when SUSFS and SukiSU are out of sync and the build fails

**How to get a commit hash?**

- SUSFS: [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) (GitLab → Repository → Commits)
- SukiSU: [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra/commits) (GitHub commit history page)

## 🛠️ Recommended After Installation
### 🔧 Xposed Modules
| Module | Description |
|:---:|:---|
| **FuseFixer** | [Unicode zero-width character fix module](https://github.com/5ec1cff/FuseFixer) |

## 🙏 Acknowledgments

- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3)
- [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) / [WildKernels/GKI_KernelSU_SUSFS](https://github.com/WildKernels/GKI_KernelSU_SUSFS)
- [SukiSU](https://sukisu.org/) / [BakaSU](https://bakasu.org/) / [FinaSU](https://github.com/LyraVoid/FinaSU)
- [SUSFS](https://gitlab.com/simonpunk/susfs4ksu)

<div align="center">

## ⚠️ Disclaimer

</div>

- Flashing this kernel will not void your warranty, but there is always a risk of bricking your device. Please make sure to:
- 💾 Back up your data
- 🧠 Understand the risks before proceeding

- Please make sure to back up the original boot image of this system in advance.

- If flashing AnyKernel3 causes your device to enter an infinite boot loop or fail to boot, enter BootLoader and flash the original boot image back.

- I take no responsibility for any issues caused by flashing this kernel.

<div align="center">
  
# **🚨 Proceed at your own risk!**

</div>

---

<div align="center">

<a id="english-translated"></a>

# GKI KernelSU SUSFS

**Automated GKI Kernel Builds | SukiSU / BakaSU / FinaSU + SUSFS Integration**

[English](#gki-kernelsu-susfs) | **English translation**

</div>

## 📖 Introduction

Built upon [AnyKernel3](https://github.com/osm0sis/AnyKernel3), this repository uses GitHub Actions to automatically compile **Android GKI kernels**. It integrates multiple KernelSU variants and SUSFS kernel-level hiding, along with practical patches such as ZRAM and BBG.

- Build workflows adapted from [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) and [Wild Kernels](https://github.com/WildKernels/GKI_KernelSU_SUSFS)
- Flashing rule: ***The kernel can be flashed as long as its version matches.***

## 📦 Supported Kernel Versions

| Android | Kernel Version | Manual Workflow |
|:---:|:---:|:---:|
| 12 | 5.10 | `kernel-a12-5-10.yml` |
| 13 | 5.15 | `kernel-a13-5-15.yml` |
| 14 | 6.1 | `kernel-a14-6-1.yml` |
| 15 | 6.6 | `kernel-a15-6-6.yml` |
| 16 | 6.12 | `kernel-a16-6-12.yml` |
| Custom | Any | `kernel-custom.yml` |

## ✨ Features

| Feature | Description |
|:---|:---|
| 🔐 KernelSU Variants | Supports SukiSU / BakaSU / FinaSU variants, selectable at build time |
| 🔀 Build Channel | Stable: latest **stable** upstream Release (tag commit + matching manager), falling back to the newest official default-branch build if the upstream only has pre-releases; Latest: pins the default-branch HEAD and selects the newest build matching its version |
| 🙈 SUSFS | Kernel-level hiding that works with KSU to spoof the environment |
| 💾 ZRAM LZ4 | ZRAM compression algorithm patch |
| 🛡️ BBG (Baseband Guard) | BBG patch to protect baseband partitions from accidental erasure |
| 🌐 Network Enhancement | Optional network stack enhancements: BBRv3 backport where available (falls back to BBR v1 otherwise) + all IPSet types (up to 65534 sets) + fq/fq_codel/cake qdiscs + connmark + IPv6 NAT/masquerading + TTL/HopLimit matching + WireGuard + CIFS |
| ⚡ KPM | Optional KPM feature / build-time patching |
| 🔔 Re-Kernel | Optional Re-Kernel driver integration |
| 🩹 CVE-2026-43499 | Optional automatic application of the rtmutex fix patch |
| 📱 OnePlus Snapdragon 8 Elite / Gen5 Support | Optional support for OnePlus Snapdragon 8 Elite / Gen5 processors |
| 🐳 Droidspaces | Optional container support and NTSync kernel compatibility patch |
| 🧩 Skip Incompatible Features | Optional: automatically skip incompatible or unavailable features without failing the build (except SUSFS and OnePlus Snapdragon 8 Elite / Gen5 support, whose failures still stop the build) |

## 🚀 Usage

1. **Fork this repository** (or use it directly)
2. Go to the **Actions** page and select the workflow for your kernel version
3. Click **Run workflow** and fill in the parameters as needed:
   - `android_version` / `kernel_version` / `sub_level` / `os_patch_level`
   - `ksu_variant`: KernelSU variant (SukiSU / BakaSU / FinaSU)
   - `build_channel`: build channel
     - `Stable (Release)`: uses the manager APK from the latest **stable** upstream Release (`prerelease=false`) and checks out the same commit as that Release tag for the kernel, ensuring the versions match exactly; if the upstream only has rc/pre-releases (such as BakaSU), it uses and pins the newest build uploaded from the official default branch instead
     - `Latest (HEAD)`: pins the kernel to the default-branch HEAD and selects the newest manager build matching its version (any branch; official CI builds for SukiSU / BakaSU, latest Release for FinaSU), keeping the kernel and manager versions aligned
     - Logs and the run summary (Summary) for both channels show the selected channel, commit, and manager version
   - Feature switches: `enable_susfs`, `use_zram`, `use_bbg`, `use_net_enhance`, `use_kpm`, `skip_incompatible`, etc.
4. When the build completes, download the **Artifacts** from the run page:
   - `AnyKernel3.zip` — flashable package (recommended; flash using a custom Recovery or KSU)
   - `boot.img` / `boot-gz.img` / `boot-lz4.img` — boot images for each compression format

> 💡 Artifacts are uploaded as Actions Artifacts by default and are not automatically published as a Release. Failed runs also upload build logs (`Build-Logs`) and patch conflict records (`Rejects`) for troubleshooting.

## 🔧 Custom Commit Configuration

Use the [`config/config`](config/config) file to specify particular commits for SUSFS and SukiSU.

**What is a commit?**

A commit is a hash string representing the state of a repository at a particular point in time. For example, setting SukiSU to `4b8644515fe6d87a109129e590ccd9d33a855dca` builds the kernel with the SukiSU version from January 30.

**Why pin a commit?**

- Roll back to a stable version when upstream updates introduce bugs or compatibility issues.
- Manually select compatible versions when SUSFS and SukiSU are out of sync and the build fails.

**How do I get a commit hash?**

- SUSFS: [susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) (GitLab → Repository → Commits)
- SukiSU: [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra/commits) (GitHub commit history)

## 🛠️ Recommended After Installation
### 🔧 Xposed Modules

| Module | Description |
|:---:|:---|
| **FuseFixer** | [Unicode zero-width character fix module](https://github.com/5ec1cff/FuseFixer) |

## 🙏 Acknowledgments

- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3)
- [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) / [WildKernels/GKI_KernelSU_SUSFS](https://github.com/WildKernels/GKI_KernelSU_SUSFS)
- [SukiSU](https://sukisu.org/) / [BakaSU](https://bakasu.org/) / [FinaSU](https://github.com/LyraVoid/FinaSU)
- [SUSFS](https://gitlab.com/simonpunk/susfs4ksu)

<div align="center">

## ⚠️ Disclaimer

</div>

- Flashing this kernel will not void your warranty, but there is always a risk of bricking your device. Please make sure to:
- 💾 Back up your data
- 🧠 Understand the risks before proceeding

- Back up the original boot image for your system in advance.

- If flashing AnyKernel3 causes your device to enter an infinite boot loop or fail to boot, enter the bootloader and flash the original boot image.

- I take no responsibility for any issues caused by flashing this kernel.

<div align="center">
  
# **🚨 Proceed at your own risk!**

</div>
