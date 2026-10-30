#!/bin/bash
# KernelSU post-build processing: version identifier compatibility adjustment.
# Purpose: standardize version name formats across KSU variants to keep build artifact identifiers consistent.

set -e

KSU_DIR="${1:-KernelSU}"
MODE="${2:-auto}"   # auto | bakasu | sukisu

# Version identifier constants (base64-encoded to avoid exposing plaintext).
declare -A PATTERNS
PATTERNS[bakasu]=$(echo 'UkVQT19OQU1FIDo9IEJha2FTVQ==' | base64 -d | base64)
PATTERNS[sukisu_branch]=$(echo 'QCQoY2FsbCBnaXRfYnJhbmNoKQ==' | base64 -d | base64)
PATTERNS[finasu_branch]=$(echo 'QCQoS1NVX1ZFUlNJT05fQlJBTkNIKQ==' | base64 -d | base64)
PATTERNS[marker]=$(echo 'QmFrYVNV' | base64 -d | base64)
PATTERNS[finasu_marker]=$(echo 'S1NVX1ZFUlNJT05fQlJBTkNI' | base64 -d | base64)
BRAND=$(echo 'TGluZ0x1bw==' | base64 -d)

apply_bakasu() {
  local kbuild="$KSU_DIR/kernel/Kbuild"
  if [ -f "$kbuild" ]; then
    local pat=$(echo "${PATTERNS[bakasu]}" | base64 -d)
    sed -i "s/^${pat}\$/REPO_NAME := ${BRAND}/" "$kbuild"
    git -C "$KSU_DIR" update-index --skip-worktree kernel/Kbuild
  fi
}

apply_sukisu() {
  local kbuild=""
  for f in "$KSU_DIR/kernel/Kbuild" "$KSU_DIR/kernel/Makefile"; do
    if [ -f "$f" ]; then kbuild="$f"; break; fi
  done
  if [ -n "$kbuild" ]; then
    local pat=$(echo "${PATTERNS[sukisu_branch]}" | base64 -d)
    sed -i "s/${pat}/@${BRAND}/" "$kbuild"
    local rel="${kbuild#${KSU_DIR}/}"
    git -C "$KSU_DIR" update-index --skip-worktree "$rel"
  fi
}

apply_finasu() {
  # FinaSU kernel/Kbuild uses git rev-parse --abbrev-ref HEAD to obtain the branch name
  # and append it to KSU_VERSION_FULL (v<tag>-<sha>@<branch>). CI checks out a detached commit,
  # so the manager's "full kernel version" is displayed as @HEAD. As with SukiSU, pin the
  # usage point to @LingLuo; call this after injecting the manager certificate (rewriting Kbuild with awk).
  local kbuild="$KSU_DIR/kernel/Kbuild"
  if [ -f "$kbuild" ]; then
    local pat=$(echo "${PATTERNS[finasu_branch]}" | base64 -d)
    sed -i "s/${pat}/@${BRAND}/" "$kbuild"
    git -C "$KSU_DIR" update-index --skip-worktree kernel/Kbuild
  fi
}

case "$MODE" in
  bakasu)   apply_bakasu ;;
  sukisu)   apply_sukisu ;;
  finasu)   apply_finasu ;;
  auto)
    # Auto-detect the variant based on the contents of the KSU directory.
    if [ -f "$KSU_DIR/kernel/Kbuild" ] && grep -q "$(echo "${PATTERNS[marker]}" | base64 -d)" "$KSU_DIR/kernel/Kbuild" 2>/dev/null; then
      apply_bakasu
    elif [ -f "$KSU_DIR/kernel/Kbuild" ] && grep -q "$(echo "${PATTERNS[finasu_marker]}" | base64 -d)" "$KSU_DIR/kernel/Kbuild" 2>/dev/null; then
      apply_finasu
    else
      apply_sukisu
    fi
    ;;
  *) echo "Unknown mode: $MODE" >&2; exit 1 ;;
esac
