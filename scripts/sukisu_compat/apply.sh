#!/usr/bin/env bash
# SukiSU kernel source API compatibility patches (for both SukiSU-Ultra builtin and main branches).
#
# Background:
#   1) The builtin branch's kernel/hook/lsm_hook.c still registers LSM hooks using
#      the old security_add_hooks(hooks, count, "ksu") signature. Kernels 6.8+
#      require (hooks, count, const struct lsm_id *), causing -Wincompatible-pointer-types
#      (-Werror) during android16-6.12 GKI builds.
#   2) The builtin app startup path calls disable_seccomp() for the manager/authorized
#      apps, so the manager home page shows "Disabled" for "Seccomp Status". Align it
#      with the main branch/BakaSU filter mode (retain the seccomp filter and allow
#      reboot through the action cache).
#
# Adaptations already fixed upstream and removed from this repository (verified against builtin 5ef32ad / main 31255c4):
#   - Missing arch.h: builtin now includes kernel/arch.h (byte-for-byte identical to this repository's old copy).
#   - Missing EVENT_SERVICES / duplicate rules.c declaration: fixed upstream alongside the UAPI 6 sync.
#   - pkg_observer track_throne(TRACK_THRONE_FORCE_SYNCHRONOUS): reverted to false.
#   - KSU_IOCTL_KPM typo / missing KSU_IOCTL_MANAGER declaration in supercall.h:
#     upstream merged KPM / MANAGER and others into KSU_IOCTL_EXTENSION; the old constants no longer exist.
#   - Bare return / pkg scope in throne_tracker's crown_manager: fixed upstream.
#   - netlink_kernel_cfg.cb_mutex (removed in Linux 6.11): upstream now probes the target
#     netlink.h at build time and defines KSU_NETLINK_CFG_HAS_CB_MUTEX; super_access.c
#     guards the member with #ifdef (main: kernel/Kbuild / builtin: kernel/Makefile).
#
# All fixes are guarded by content checks, automatically skipped once fixed upstream, and are idempotent.
#
# Usage: apply.sh [KernelSU directory] (the caller's working directory must be $KERNEL_ROOT).

set -eo pipefail

KSU_DIR="${1:-KernelSU}"

fail() {
  if [ "$SKIP_INCOMPATIBLE" = "true" ]; then
    echo "::warning title=SukiSU compatibility patch skipped::$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "> ⏭️ **SukiSU API compatibility patch** automatically skipped: $1 (build not interrupted)" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  echo "::error::$1"
  exit 1
}

[ -d "$KSU_DIR" ] || fail "KernelSU directory not found: $KSU_DIR"

COMPAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LSM_FILE="$KSU_DIR/kernel/hook/lsm_hook.c"
if [ -f "$LSM_FILE" ] && grep -q 'security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");' "$LSM_FILE"; then
  if grep -q 'ksu_lsm_id' "$LSM_FILE"; then
    echo "lsm_hook.c already contains lsm_id compatibility code; skipping"
  else
    echo "Applying lsm_id compatibility patch (new 6.8+ security_add_hooks signature)..."
    patch -p1 --forward -d "$KSU_DIR" < "$COMPAT_DIR/sukisu-lsm-id-6.8.patch" \
      || fail "Failed to apply lsm_id compatibility patch (SukiSU upstream code may have changed)"
    grep -q 'struct lsm_id ksu_lsm_id' "$LSM_FILE" \
      || fail "lsm_id compatibility patch validation failed"
    echo "lsm_hook.c: switched to struct lsm_id registration for 6.8+"
  fi
else
  echo "lsm_hook.c does not exist or does not need the lsm_id compatibility patch; skipping"
fi

# ---- Seccomp filter mode (builtin branch) ----
# Background: on the builtin branch, the app startup path (zygote setresuid hook)
# directly calls disable_seccomp() for the manager and authorized apps, clearing
# the manager process's seccomp filter. The manager home page then shows "Disabled"
# for "Seccomp Status". The main branch / BakaSU retains the filter ("Filter mode")
# and allows reboot only through the seccomp action cache (backported to GKI 5.10+).
# Processing: rewrite six disable_seccomp() call sites in lsm_hook.c to use the
# cache-allow form, distribute infra/seccomp_cache.c/h, and include it in the unity
# build in ksu.c (renamed to ksu_main.c after the upstream refactor). Retain the
# filter for >=5.10; keep the original disable_seccomp() behavior for <5.10
# (the action cache is unavailable).
# Guard: run only when the builtin handle_zygote_setresuid is found; skip the main
# branch automatically. Skip idempotently once fixed upstream.
if [ -f "$LSM_FILE" ] && grep -q 'handle_zygote_setresuid' "$LSM_FILE"; then
  if grep -q 'ksu_seccomp_allow_cache' "$LSM_FILE"; then
    echo "lsm_hook.c already contains seccomp filter mode logic; skipping"
  else
    echo "Applying seccomp filter mode patch (aligning with main branch/BakaSU: retain seccomp filters for manager and authorized apps)..."
    [ -d "$KSU_DIR/kernel/infra" ] || fail "$KSU_DIR/kernel/infra directory not found; SukiSU builtin structure may have changed"
    cp "$COMPAT_DIR/seccomp_cache.h" "$KSU_DIR/kernel/infra/seccomp_cache.h" \
      || fail "Failed to distribute seccomp_cache.h"
    cp "$COMPAT_DIR/seccomp_cache.c" "$KSU_DIR/kernel/infra/seccomp_cache.c" \
      || fail "Failed to distribute seccomp_cache.c"
    python3 "$COMPAT_DIR/seccomp_filter_mode.py" "$KSU_DIR" \
      || fail "Failed to apply seccomp filter mode patch (SukiSU builtin upstream code may have changed)"
    grep -q 'ksu_seccomp_allow_cache' "$LSM_FILE" \
      || fail "seccomp filter mode patch validation failed (lsm_hook.c)"
    # The unity-build source was renamed upstream (kernel/ksu.c -> kernel/ksu_main.c);
    # validate using its actual path.
    KSU_AGG=""
    for cand in kernel/ksu.c kernel/ksu_main.c; do
      if [ -f "$KSU_DIR/$cand" ]; then
        KSU_AGG="$KSU_DIR/$cand"
        break
      fi
    done
    if [ -z "$KSU_AGG" ] || ! grep -q '#include "infra/seccomp_cache.c"' "$KSU_AGG"; then
      fail "seccomp filter mode patch validation failed (unity-build source ksu.c/ksu_main.c)"
    fi
    grep -q '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)' "$KSU_DIR/kernel/infra/seccomp_cache.c" \
      || fail "seccomp_cache.c version guard validation failed"
    echo "Seccomp filter mode enabled: the manager home page will show \"Filter mode\" for Seccomp Status"
  fi
else
  echo "lsm_hook.c has no builtin setresuid path (filter mode is built into the main branch); skipping seccomp filter mode patch"
fi

# ---- clang fall-through annotation ----
# builtin policy/allowlist.c uses comment-style fall-through annotations; bazel GKI
# builds fail with -Werror,-Wimplicit-fallthrough. Replace them with the kernel's
# fallthrough macro (expands to __attribute__((__fallthrough__))); skip after upstream fixes.
if grep -rqF '/* fall through */' "$KSU_DIR/kernel" 2>/dev/null; then
  echo "Fixing comment-style fall-through in SukiSU source (bazel -Werror compatibility)..."
  python3 - "$KSU_DIR" <<'PYEOF'
import pathlib
import sys

root = pathlib.Path(sys.argv[1]) / "kernel"
for path in sorted(root.rglob("*.c")):
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    if "/* fall through */" not in text:
        continue
    path.write_text(
        text.replace("/* fall through */", "fallthrough;"),
        encoding="utf-8",
        errors="surrogateescape",
    )
    print(f"  {path}")
PYEOF
  if grep -rqF '/* fall through */' "$KSU_DIR/kernel" 2>/dev/null; then
    fail "fall-through annotations remain after replacement"
  fi
  echo "fall-through annotation replacement complete"
else
  echo "No comment-style fall-through annotations in SukiSU source; skipping"
fi

echo "SukiSU API compatibility patches complete"
