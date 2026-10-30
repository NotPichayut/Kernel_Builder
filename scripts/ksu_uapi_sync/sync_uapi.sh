#!/usr/bin/env bash
# Dynamically synchronize the kernel UAPI on the SukiSU builtin branch with the official main-branch manager.
#
# Background:
#   The builtin branch (builtin + SUSFS product line) and the official main branch
#   are independent. The official manager APK is always built from main. When
#   main's uapi/supercall.h raises KERNEL_SU_UAPI_VERSION (for example, commit
#   3b60791 raised the UAPI to 6 and added KSU_IOCTL_LOOKUP_SYMBOLS /
#   KSU_GET_INFO_FLAG_PREINIT), the kernel UAPI checked out on builtin falls behind
#   the manager. The manager sets requiresNewKernel = true and displays "Kernel
#   update required" on its home page (Natives.kt: managerUAPIVersion > kernelUAPIVersion).
#
# This script dynamically backports missing declarations from the official main
# uapi/supercall.h to the builtin header: UAPI constants, KSU_GET_INFO_FLAG_* bits,
# new ioctl constants, and struct ksu_lookup_symbols_cmd. It raises the UAPI version
# to match main. Supporting kernel-side functionality (the LOOKUP_SYMBOLS handler
# and symbol_resolver) is injected by build.yml afterward in a separate
# content-detection step.
#
# Backports are guarded by content checks: existing code is skipped, making reruns
# idempotent. The changes are also skipped automatically once builtin syncs its UAPI upstream.
#
# Usage: sync_uapi.sh [KernelSU directory] (the caller's working directory must be
# $KERNEL_ROOT, and raw.githubusercontent.com for the official repository must be accessible).

set -eo pipefail

KSU_DIR="${1:-KernelSU}"

fail() {
  if [ "$SKIP_INCOMPATIBLE" = "true" ]; then
    echo "::warning title=SukiSU UAPI sync skipped::$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "> ⏭️ **SukiSU UAPI sync** automatically skipped: $1 (build not interrupted)" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  echo "::error::$1"
  exit 1
}

[ -d "$KSU_DIR" ] || fail "KernelSU directory not found: $KSU_DIR"

COMPAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# builtin branch: kernel/include/uapi/supercall.h; main branch: uapi/supercall.h.
UAPI_FILE=""
for f in "$KSU_DIR/kernel/include/uapi/supercall.h" "$KSU_DIR/uapi/supercall.h"; do
  if [ -f "$f" ]; then
    UAPI_FILE="$f"
    break
  fi
done
[ -n "$UAPI_FILE" ] || fail "supercall.h not found; the SukiSU source layout may have changed"

read_uapi() {
  grep -ohE 'KERNEL_SU_UAPI_VERSION[^0-9]*[0-9]+' "$1" | grep -oE '[0-9]+' | tail -n 1
}

# Fetch supercall.h from official main (web layout; UAPI definitions are published as static const).
MAIN_URL="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/uapi/supercall.h"
MAIN_FILE=$(mktemp)
MAIN_JSON=""
for ATTEMPT in 1 2 3; do
  if curl -sL --fail --max-time 60 -o "$MAIN_FILE" "$MAIN_URL" && [ -s "$MAIN_FILE" ]; then
    break
  fi
  echo "Failed to fetch official main supercall.h; retrying ($ATTEMPT/3)..."
  sleep 5
done
[ -s "$MAIN_FILE" ] || fail "Could not fetch official main uapi/supercall.h; aborting UAPI sync"

MAIN_UAPI=$(read_uapi "$MAIN_FILE")
CUR_UAPI=$(read_uapi "$UAPI_FILE")
echo "Official main UAPI version: ${MAIN_UAPI:-unknown}, current checked-out builtin UAPI version: ${CUR_UAPI:-unknown}"
[ -n "$MAIN_UAPI" ] || fail "Could not parse KERNEL_SU_UAPI_VERSION from official main supercall.h"

if [ "${CUR_UAPI:-0}" -ge "$MAIN_UAPI" ]; then
  echo "Checked-out builtin UAPI >= official main ($CUR_UAPI >= $MAIN_UAPI); no sync needed, skipping"
  rm -f "$MAIN_FILE"
  exit 0
fi

python3 - "$UAPI_FILE" "$MAIN_FILE" <<'PYEOF'
import sys, re

uapi_path, main_path = sys.argv[1], sys.argv[2]
uapi = open(uapi_path, encoding="utf-8", errors="surrogateescape").read()
main = open(main_path, encoding="utf-8", errors="surrogateescape").read()

def read_num(text, name):
    m = re.search(re.escape(name) + r"[^0-9]*(\d+)", text)
    return int(m.group(1)) if m else None

main_ver = read_num(main, "KERNEL_SU_UAPI_VERSION")
cur_ver = read_num(uapi, "KERNEL_SU_UAPI_VERSION")
if not main_ver:
    print("::error::KERNEL_SU_UAPI_VERSION is missing from official main supercall.h")
    sys.exit(1)

changed = []

# 1) Backport missing constants to builtin using the official values (including the
#    raised KERNEL_SU_UAPI_VERSION, EVENT_*, KSU_GET_INFO_FLAG_*, new ioctl constants,
#    KSU_LOOKUP_SYMBOLS_MAX, and others). Use the DECLARE macro already present in
#    builtin (which expands to an enum outside BINDGEN), producing compile-time
#    constants that the static dispatch table in dispatch.c can reference; main's
#    static const form causes "initializer element is not a compile-time constant"
#    in builtin's static initializer context.
#    Backport constants individually instead of replacing the whole file: the builtin
#    header has independently evolved content (DECLARE macros, __user annotations in
#    ksu_kpm_cmd, etc.) that would otherwise be overwritten.
def parse_decls(text):
    decls = {}
    for m in re.finditer(r"^static const (\w[\w\s\*]*?)\b(\w+)\s*=\s*([^;\n]+);", text, re.M):
        decls.setdefault(m.group(2), (m.group(1), m.group(3)))
    return decls

main_decls = parse_decls(main)
has_declare = "#define DECLARE" in uapi

# 2) Backport struct definitions missing from builtin (such as ksu_lookup_symbols_cmd /
#    ksu_set_spoof_version_cmd). Structs must precede the _IOW constant declarations
#    that reference them, and the insertion point must be inside the include guard
#    (supercall.h is included multiple times by ksu.c / dynamic_manager.c, so content
#    after the final #endif would be defined repeatedly on every include).
struct_re = re.compile(r"^struct (\w+) \{(?:[^{}])*?\};", re.M | re.S)
main_structs = []
for m in struct_re.finditer(main):
    main_structs.append((m.group(1), m.group(0)))

missing_structs = [(n, t) for n, t in main_structs if not re.search(r"struct\s+" + re.escape(n) + r"\s*\{", uapi)]
missing_decls = {n: v for n, v in main_decls.items() if not re.search(r"\b" + re.escape(n) + r"\b", uapi)}

# Use a consistent insertion point: after the flag block (inside the guard, after
# DECLARE macros, and before structs/constants are used).
anchor = re.search(r"(DECLARE\(__u32, KSU_GET_INFO_FLAG_PR_BUILD[^\n]*\n|static const __u32 KSU_GET_INFO_FLAG_PR_BUILD[^\n]*\n)", uapi)
if not anchor:
    anchor = re.search(r"(DECLARE\(__u32, KERNEL_SU_UAPI_VERSION[^\n]*\n|static const __u32 KERNEL_SU_UAPI_VERSION[^\n]*\n)", uapi)
if not anchor:
    print("::error::Missing constants/struct insertion anchor in builtin supercall.h (UAPI/FLAG block)")
    sys.exit(1)
pos = anchor.end()

block = "\n// synced from SukiSU-Ultra main uapi/supercall.h (dynamic UAPI sync)\n"
# Insert structs first (the _IOW constants with the same names in the insertion block reference them).
for sname, text in missing_structs:
    block += text + "\n"
    changed.append("struct " + sname)
for name, (ctype, value) in missing_decls.items():
    if has_declare:
        block += "DECLARE(%s, %s, %s);\n" % (ctype, name, value)
    else:
        block += "static const %s %s = %s;\n" % (ctype, name, value)
    changed.append(name)
if missing_decls:
    block += "\n"

uapi = uapi[:pos] + block + uapi[pos:]

# 3) Raise the UAPI version to the official value.
if cur_ver is not None and cur_ver < main_ver:
    uapi = re.sub(
        r"((?:DECLARE\(__u32, KERNEL_SU_UAPI_VERSION|static const __u32 KERNEL_SU_UAPI_VERSION)[^\n]*?)\b%d\b" % cur_ver,
        r"\g<1>%d" % main_ver,
        uapi, count=1)
    changed.append("KERNEL_SU_UAPI_VERSION %d -> %d" % (cur_ver, main_ver))

if not changed:
    print("supercall.h: no backport needed (UAPI version and constants are already present)")
else:
    open(uapi_path, "w", encoding="utf-8", errors="surrogateescape").write(uapi)
    for c in changed:
        print("supercall.h: backported %s" % c)
PYEOF

# ---------------- Inject Supporting Kernel-Side Functionality (LOOKUP_SYMBOLS / symbol_resolver) ----------------
# With UAPI >= 6, the manager probes KSU_IOCTL_LOOKUP_SYMBOLS (used to bind symbols
# for hot-loaded modules). This functionality depends on infra/symbol_resolver from
# the main branch, which is missing from the builtin checkout. Inject it with content
# checks: distribute the resolver source, add kernel includes, and wire up do_lookup_symbols.
if grep -q 'KSU_IOCTL_LOOKUP_SYMBOLS' "$UAPI_FILE" 2>/dev/null; then
  RESOLVER_C="$KSU_DIR/kernel/infra/symbol_resolver.c"
  RESOLVER_H="$KSU_DIR/kernel/infra/symbol_resolver.h"
  if [ ! -f "$RESOLVER_C" ] || ! grep -q 'ksu_lookup_kernel_symbols' "$RESOLVER_C" 2>/dev/null; then
    echo "Injecting infra/symbol_resolver (main-branch UAPI 6 bulk symbol lookup)..."
    cp "$COMPAT_DIR/symbol_resolver.h" "$RESOLVER_H" || fail "Failed to distribute symbol_resolver.h"
    cp "$COMPAT_DIR/symbol_resolver.c" "$RESOLVER_C" || fail "Failed to distribute symbol_resolver.c"
    grep -q 'ksu_lookup_kernel_symbols' "$RESOLVER_C" || fail "symbol_resolver.c validation failed after distribution"
  else
    echo "infra/symbol_resolver already exists; skipping distribution"
  fi

  # builtin compiles ksu.c as a unity build (kernel_includes.h aggregates kernel
  # headers); the bsearch/sort/kallsyms headers required by the resolver are not
  # included there, so add them as needed.
  KINC="$KSU_DIR/kernel/kernel_includes.h"
  if [ -f "$KINC" ] && [ -f "$RESOLVER_C" ]; then
    for HDR in bsearch sort kallsyms; do
      if grep -q "ksu_lookup_kernel_symbols" "$RESOLVER_C" && ! grep -q "include <linux/$HDR.h>" "$KINC"; then
        sed -i "s|^#include <linux/kernel.h>|#include <linux/kernel.h>\n#include <linux/$HDR.h>|" "$KINC" \
          || fail "Failed to add <linux/$HDR.h> to kernel_includes.h"
        grep -q "include <linux/$HDR.h>" "$KINC" || fail "kernel_includes.h <linux/$HDR.h> validation failed"
        echo "kernel_includes.h: added <linux/$HDR.h>"
      fi
    done
  fi

  # Wire up the include, handler, and ioctl table entry (builtin dispatch.c has no
  # include section; it is built as a unity build).
  DISPATCH="$KSU_DIR/kernel/supercall/dispatch.c"
  if [ -f "$DISPATCH" ] && [ -f "$RESOLVER_C" ]; then
    if ! grep -q 'do_lookup_symbols' "$DISPATCH"; then
      echo "Wiring up supercall/dispatch.c: do_lookup_symbols handler..."
      python3 - "$DISPATCH" "$UAPI_FILE" <<'PYEOF2'
import sys, re

path = sys.argv[1]
s = open(path, encoding="utf-8", errors="surrogateescape").read()

# 1) Include the resolver (in a unity build, place it before the source declarations).
if '#include "infra/symbol_resolver.h"' not in s and '#include "infra/symbol_resolver.c"' not in s:
    # dispatch.c has no include section; use extern declarations instead.
    s = ("extern int ksu_lookup_kernel_symbols(const char *const *names, unsigned long *addrs, u32 count);\n\n" + s)

# 2) do_lookup_symbols handler: insert before the do_disable_escape_to_root definition.
handler = '''/*
 * Batch resolve kernel image symbols (exported or not) for userspace
 * module symbol binding, ported from SukiSU-Ultra main (UAPI 6).
 */
static int do_lookup_symbols(void __user *arg)
{
    struct ksu_lookup_symbols_cmd cmd;
    const u64 __user *unames;
    u64 __user *uaddrs;
    char **names;
    unsigned long *addrs;
    int ret = 0;
    u32 i;

    if (copy_from_user(&cmd, arg, sizeof(cmd)))
        return -EFAULT;

    if (cmd.flags) {
        pr_err("lookup_symbols: unsupported flags 0x%x\\n", cmd.flags);
        return -EINVAL;
    }
    if (!cmd.count || cmd.count > KSU_LOOKUP_SYMBOLS_MAX)
        return -EINVAL;

    names = kvcalloc(cmd.count, sizeof(*names), GFP_KERNEL);
    addrs = kvcalloc(cmd.count, sizeof(*addrs), GFP_KERNEL);
    if (!names || !addrs) {
        ret = -ENOMEM;
        goto out;
    }

    unames = (const u64 __user *)(uintptr_t)cmd.names;
    uaddrs = (u64 __user *)(uintptr_t)cmd.addrs;
    for (i = 0; i < cmd.count; i++) {
        u64 uname;
        char *name;

        if (get_user(uname, unames + i)) {
            ret = -EFAULT;
            goto out;
        }
        name = strndup_user((const char __user *)(uintptr_t)uname, KSYM_NAME_LEN);
        if (IS_ERR(name)) {
            // An overlong name cannot be a kernel symbol: report it missing.
            if (PTR_ERR(name) == -EINVAL)
                continue;
            ret = PTR_ERR(name);
            goto out;
        }
        if (!*name) {
            kfree(name);
            continue;
        }
        names[i] = name;
    }

    ret = ksu_lookup_kernel_symbols((const char *const *)names, addrs, cmd.count);
    if (ret < 0)
        goto out;

    for (i = 0; i < cmd.count; i++) {
        if (put_user((u64)addrs[i], uaddrs + i)) {
            ret = -EFAULT;
            goto out;
        }
    }

out:
    if (names) {
        for (i = 0; i < cmd.count; i++)
            kfree(names[i]);
    }
    kvfree(names);
    kvfree(addrs);
    return ret;
}

'''
anchor = "static int do_disable_escape_to_root(void __user *arg)"
if anchor not in s:
    print("::error::dispatch.c is missing the do_disable_escape_to_root anchor; cannot insert do_lookup_symbols")
    sys.exit(1)
s = s.replace(anchor, handler + anchor, 1)

# 3) ioctl table entry: insert after DISABLE_ESCAPE_TO_ROOT, where LOOKUP_SYMBOLS is available.
entry = '''    {
        .cmd = KSU_IOCTL_LOOKUP_SYMBOLS,
        .name = "LOOKUP_SYMBOLS",
        .handler = do_lookup_symbols,
        .perm_check = only_root
    },
'''
anchor2 = re.search(r"\.cmd = KSU_IOCTL_DISABLE_ESCAPE_TO_ROOT,(?:.*\n)*?    \},\n", s)
if not anchor2:
    print("::error::dispatch.c dispatch table is missing the DISABLE_ESCAPE_TO_ROOT anchor")
    sys.exit(1)
s = s[:anchor2.end()] + entry + s[anchor2.end():]

open(path, "w", encoding="utf-8", errors="surrogateescape").write(s)
print("dispatch.c: wired up do_lookup_symbols handler + LOOKUP_SYMBOLS table entry")
PYEOF2
      grep -q 'do_lookup_symbols' "$DISPATCH" || fail "dispatch.c validation failed after wiring"
    else
      echo "dispatch.c already contains do_lookup_symbols; skipping wiring"
    fi

    # builtin compiles ksu.c as a unity build (all .c files are aggregated into ksu.o
    # via #include), so the resolver source must be #included in ksu.c or linking
    # will fail with undefined symbols.
    KSU_C="$KSU_DIR/kernel/ksu.c"
    if [ -f "$KSU_C" ] && ! grep -q '#include "infra/symbol_resolver.c"' "$KSU_C"; then
      sed -i 's|^#include "infra/event_queue.c"|#include "infra/event_queue.c"\n#include "infra/symbol_resolver.c"|' "$KSU_C" \
        || fail "Failed to include symbol_resolver.c in ksu.c"
      grep -q '#include "infra/symbol_resolver.c"' "$KSU_C" || fail "ksu.c symbol_resolver.c include validation failed"
      echo "ksu.c: #include infra/symbol_resolver.c added (unity build)"
    elif [ -f "$KSU_C" ]; then
      echo "ksu.c already includes symbol_resolver.c; skipping"
    fi

    # Initialization wiring: initialize the resolver's function-pointer table in kernelsu_init.
    if ! grep -q 'ksu_init_symbol_resolver' "$KSU_C" 2>/dev/null; then
      python3 - "$KSU_C" <<'PYEOF3'
import sys, re
path = sys.argv[1]
s = open(path, encoding="utf-8", errors="surrogateescape").read()
if "ksu_init_symbol_resolver();" not in s:
    anchor = "    ksu_supercalls_init();"
    if anchor in s:
        s = s.replace(anchor, anchor + "\n\n    ksu_init_symbol_resolver();", 1)
        open(path, "w", encoding="utf-8", errors="surrogateescape").write(s)
        print("ksu.c: added ksu_init_symbol_resolver() to kernelsu_init")
    else:
        print("::warning::ksu.c is missing the ksu_supercalls_init anchor; resolver initialization was not wired (LOOKUP_SYMBOLS will fall back to an uninitialized walker)")
else:
    print("ksu.c already contains the ksu_init_symbol_resolver() call; skipping")
PYEOF3
    else
      echo "ksu.c already contains the ksu_init_symbol_resolver() call; skipping"
    fi
  fi
else
  echo "UAPI < 6 has no LOOKUP_SYMBOLS; skipping kernel-side functionality injection"
fi

FINAL_UAPI=$(read_uapi "$UAPI_FILE")
[ "${FINAL_UAPI:-0}" -eq "$MAIN_UAPI" ] || fail "UAPI version validation failed (expected $MAIN_UAPI, got ${FINAL_UAPI:-unknown})"
echo "UAPI sync complete: checked-out builtin UAPI $CUR_UAPI -> $FINAL_UAPI (official main $MAIN_UAPI)"
rm -f "$MAIN_FILE"
