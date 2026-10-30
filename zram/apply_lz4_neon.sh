#!/bin/bash
# ================================================================
# apply_lz4_neon.sh
# Add conditional compilation for ARM64 NEON acceleration to LZ4 decompression calls.
# Replaces the four version-specific patch files with regular-expression matching instead of fixed line numbers.
#
# Usage: run from the kernel source root (common/).
#   bash /path/to/apply_lz4_neon.sh
# ================================================================
set -euo pipefail

PATCHED=0
SKIPPED=0
FAILED=0

# Check whether the file is already patched.
already_patched() {
  grep -q "LZ4_arm64_decompress_safe" "$1" 2>/dev/null
}

# ---- 1. crypto/lz4.c and crypto/lz4hc.c ----
# Common pattern: int out_len = LZ4_decompress_safe(src, dst, slen, *dlen);
for file in crypto/lz4.c crypto/lz4hc.c; do
  if [ ! -f "$file" ]; then
    echo "Skipped (not found): $file"; ((SKIPPED++)) || true; continue
  fi
  if already_patched "$file"; then
    echo "Skipped (already patched): $file"; ((SKIPPED++)) || true; continue
  fi

  perl -i -pe '
    if (/int out_len = LZ4_decompress_safe\(src, dst, slen, \*dlen\);/) {
      $_ = "\tint out_len;\n\n"
         . "#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n"
         . "\tout_len = LZ4_arm64_decompress_safe(src, dst, slen, *dlen, false);\n"
         . "#else\n"
         . "\tout_len = LZ4_decompress_safe(src, dst, slen, *dlen);\n"
         . "#endif\n";
    }
  ' "$file"

  if already_patched "$file"; then
    echo "Patched: $file"; ((PATCHED++)) || true
  else
    echo "::error::Patch failed: $file"; ((FAILED++)) || true
  fi
done

# ---- 2. fs/f2fs/compress.c ----
# Replace LZ4_decompress_safe(dic->cbuf->cdata, ...) with a conditional-compilation version.
file="fs/f2fs/compress.c"
if [ ! -f "$file" ]; then
  echo "Skipped (not found): $file"; ((SKIPPED++)) || true
elif already_patched "$file"; then
  echo "Skipped (already patched): $file"; ((SKIPPED++)) || true
else
  perl -i -0777 -pe '
    s{(\t)ret = LZ4_decompress_safe\(dic->cbuf->cdata, dic->rbuf,\s*\n\s*dic->clen, dic->rlen\);}
     {#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n${1}ret = LZ4_arm64_decompress_safe(dic->cbuf->cdata, dic->rbuf,\n\t\t\t\t\t\tdic->clen, dic->rlen, false);\n#else\n${1}ret = LZ4_decompress_safe(dic->cbuf->cdata, dic->rbuf,\n\t\t\t\t\t\tdic->clen, dic->rlen, false);\n#endif}
  ' "$file"

  if already_patched "$file"; then
    echo "Patched: $file"; ((PATCHED++)) || true
  else
    echo "::error::Patch failed: $file"; ((FAILED++)) || true
  fi
fi

# ---- 3. fs/incfs/data_mgmt.c (present only in some kernel versions) ----
file="fs/incfs/data_mgmt.c"
if [ ! -f "$file" ]; then
  echo "Skipped (not found): $file"; ((SKIPPED++)) || true
elif already_patched "$file"; then
  echo "Skipped (already patched): $file"; ((SKIPPED++)) || true
else
  perl -i -0777 -pe '
    s{(\t+)result = LZ4_decompress_safe\(src\.data, dst\.data, src\.len,\s*\n\s*dst\.len\);}
     {#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n${1}result = LZ4_arm64_decompress_safe(src.data, dst.data, src.len, dst.len, false);\n#else\n${1}result = LZ4_decompress_safe(src.data, dst.data, src.len, dst.len);\n#endif}
  ' "$file"

  if already_patched "$file"; then
    echo "Patched: $file"; ((PATCHED++)) || true
  else
    echo "::error::Patch failed: $file"; ((FAILED++)) || true
  fi
fi

echo ""
echo "=== LZ4 NEON patch complete: ${PATCHED} patched, ${SKIPPED} skipped, ${FAILED} failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
