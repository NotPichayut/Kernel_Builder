#!/usr/bin/env bash
# Apply the SUSFS patch and context fixes required by each kernel version.
#
# Required environment variables:
#   ANDROID_VERSION KERNEL_VERSION KSU_VARIANT OS_PATCH_LEVEL SUB_LEVEL
#   KERNEL_ROOT SUSFS4KSU KERNEL_PATCHES LEGACY_SUKISU_CONFIG
# Set the working directory to $KERNEL_ROOT before calling.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Applying SUSFS patch..."

SUSFS_PATCH="50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch"
cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ./common/
cp "$SUSFS4KSU"/kernel_patches/fs/* ./common/fs/
cp "$SUSFS4KSU"/kernel_patches/include/linux/* ./common/include/linux/

# Since cdf8711a + 5b83330b (2026-10-23), FinaSU upstream has integrated SUSFS natively
# into the tree. The official docs/builtin-integration.md explicitly says **not** to apply
# susfs4ksu's 10_enable_susfs_for_ksu.patch. That patch targets the upstream KernelSU manual
# hook model and moves compilation units such as hook/tp_marker.o out of Kbuild, while
# FinaSU's kprobe model still references those symbols; patching the driver would cause
# undefined symbols during vmlinux linking.
# FinaSU now matches SukiSU/BakaSU: no driver-side patch. The only difference is that
# FinaSU's native integration is newer, so validate its structure here (the kernel-side
# 50_add main patch's inline hooks depend on these entry points/symbols) and fail on drift
# rather than silently degrading.
verify_finasu_native_susfs() {
  local FINASU_KSU="$KERNEL_ROOT/KernelSU/kernel"
  local OPT SYM

  if [ ! -f "$FINASU_KSU/extension/susfs.c" ]; then
    echo "::error::FinaSU does not include native SUSFS integration (KernelSU/kernel/extension/susfs.c is missing)." >&2
    echo "::error::The checked-out FinaSU predates 5b83330b (2026-10-23), or the upstream structure has changed again." >&2
    echo "::error::The old 10_enable driver-side patch was deprecated by native upstream integration; verify that ksuCommit points to the latest Release." >&2
    exit 1
  fi

  # Kconfig includes the complete KSU_SUSFS menu (every CONFIG_KSU_SUSFS* option
  # written by "Add SUSFS configuration" must be defined, or olddefconfig silently drops it).
  for OPT in KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT \
             KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_ENABLE_LOG KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
             KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP; do
    grep -q "^config $OPT\$" "$FINASU_KSU/Kconfig" \
      || { echo "::error::FinaSU Kconfig is missing config $OPT (upstream structure may have changed)" >&2; exit 1; }
  done

  # extension/susfs.c provides all entry points called inline by the 50_add main
  # patch in fs/exec.c. Missing symbols cause undefined-symbol errors at vmlinux
  # link time, so validate them here in advance.
  for SYM in ksu_handle_execveat ksu_handle_execveat_sucompat ksu_handle_post_execveat_sucompat \
             ksu_setup_preinit_file ksu_preinit_handle_post_execveat; do
    grep -qE "^(int|void) $SYM\(" "$FINASU_KSU/extension/susfs.c" \
      || { echo "::error::FinaSU extension/susfs.c is missing global entry point: $SYM" >&2; exit 1; }
  done

  # Three-argument SUSFS implementation (the three-argument call in kernel/sys.c depends on this signature).
  grep -q '^int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid)$' "$FINASU_KSU/hook/setuid_hook.c" \
    || { echo "::error::FinaSU setuid_hook.c is missing three-argument ksu_handle_setresuid (upstream structure may have changed)" >&2; exit 1; }

  # my_* symbols are exported globally (the 6.6/6.12 main patch calls them inline from security/selinux/{hooks,selinuxfs}.c).
  for SYM in my_write_context my_write_access my_setprocattr; do
    grep -qE "^(ssize_t|int) $SYM\(" "$FINASU_KSU/feature/selinux_hide.c" \
      || { echo "::error::FinaSU selinux_hide.c does not export $SYM globally (the inline SUSFS SELinux hooks will fail to link)" >&2; exit 1; }
  done

  # susfs_init() is called natively by the driver init.
  grep -q 'susfs_init();' "$FINASU_KSU/core/init.c" \
    || { echo "::error::FinaSU init.c does not call susfs_init() (upstream structure may have changed)" >&2; exit 1; }

  echo "FinaSU native SUSFS integration validation passed"
}

case "$KSU_VARIANT" in
  "SukiSU"|"BakaSU")
    echo "SukiSU/BakaSU use built-in SUSFS support"
    ;;
  "FinaSU")
    echo "FinaSU uses native in-tree SUSFS integration (no driver-side patch, matching SukiSU/BakaSU)"
    verify_finasu_native_susfs
    ;;
esac

cd "$KERNEL_ROOT/common"
CURRENT_SUB="$SUB_LEVEL"
if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
  CURRENT_SUB=99999
fi

# Compatibility for 5.10.66–209, 5.15.74–144, and 6.1.25–68, which lack the VMA padding interface.
if grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
  && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
  echo "Target kernel does not provide VMA_PAD_START; using vma->vm_end for SUSFS OPEN_REDIRECT compatibility"
  sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
fi

adjust_legacy_fdinfo_context() {
  sed -i '/^[[:space:]]*\/\*$/,/^[[:space:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$/d' fs/notify/fdinfo.c
  perl -i -pe 's/\bmask,\s*mark->ignored_mask/inotify_mark_user_mask(mark)/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:%x/ignored_mask:0/g' fs/notify/fdinfo.c
}

restore_legacy_fdinfo_context() {
  perl -i -pe 's/^(\s+if \(inode\) \{)/$1\n\t\t\/\*\n\t\t * IN_ALL_EVENTS represents all of the mask bits\n\t\t * that we expose to userspace.  There is at\n\t\t * least one bit (FS_EVENT_ON_CHILD) which is\n\t\t * used only internally to the kernel.\n\t\t *\/\n\t\tu32 mask = mark->mask & IN_ALL_EVENTS;/m' fs/notify/fdinfo.c
  perl -i -pe 's/\binotify_mark_user_mask\(mark\)/mask, mark->ignored_mask/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:0/ignored_mask:%x/g' fs/notify/fdinfo.c
}

# Temporarily adjust old-kernel source context so the SUSFS main patch can apply.
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "Temporarily adjusting Android 12 5.10 base.c context"
    perl -i -pe 's/(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,/size_t this_len = min_t(size_t,/;' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "Temporarily adjusting Android 12 5.10 fdinfo.c context"
    adjust_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "Temporarily adjusting Android 13 5.15 namespace.c/open.c/fdinfo.c context"
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
      sed -i '/^#include <linux\/shmem_fs.h>$/a #include <linux/mnt_idmapping.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/open.c; then
      sed -i '/^#include <linux\/compat.h>$/a #include <linux/mnt_idmapping.h>' fs/open.c
    fi
    adjust_legacy_fdinfo_context
  fi
  # 5.15.220 (LTS) natively includes #include <trace/hooks/{mm,blk}.h>. After the
  # upstream rebase, the main patch uses these lines as context for the hunk that
  # inserts susfs_def.h. The old "remove then restore" adjustment would now cause
  # the entire hunk to be rejected, so do not remove them; normalize_trace_ctx.py
  # handles patch copies for versions where the context is missing.
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
    echo "Temporarily adjusting Android 14 6.1 sched.h context"
    sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "Temporarily adjusting Android 14 6.1 dma-buf.h context"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]]; then
    echo "Temporarily adjusting Android 14 6.1 namespace.c context"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "Temporarily adjusting Android 15 6.6 base.c context"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]] && ! grep -qF '#include <linux/zswap.h>' mm/memory.c; then
    echo "Temporarily adjusting Android 15 6.6 memory.c context"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
  fi
fi

# The first fs/exec.c hunk in the 6.12 main patch uses `#include <linux/dma-buf.h>`
# (immediately after ksm.h) as the context anchor for inserting susfs_def.h. This is
# the native form in GKI 6.12.58+, so the patch applies directly. Versions 6.12.23–38
# lack this dma-buf.h line, causing the entire hunk to be rejected; exec.c then lacks
# susfs_def.h, and susfs_is_current_proc_no_su() in do_execveat_common() is implicitly
# declared, stopping compilation under clang -Werror.
# Rewrite only the patch copy when the source lacks this context: remove the stale
# context line and recalculate the hunk counts. Do not modify the source (the old
# misaligned adjustment that removed dma-buf.h and later added it to the file header was removed).
normalize_exec_include_hunk() {
  python3 - "$SUSFS_PATCH" <<'PYEOF'
import re
import sys

path = sys.argv[1]
src = open("fs/exec.c", encoding="utf-8", errors="surrogateescape").read()
if "#include <linux/ksm.h>\n#include <linux/dma-buf.h>" in src:
    print("fs/exec.c has the native dma-buf.h anchor; the main patch applies directly, skipping normalization")
    raise SystemExit(0)

with open(path, encoding="utf-8", errors="surrogateescape") as f:
    lines = f.read().splitlines()

hdr = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')
out, i, dropped = [], 0, 0

while i < len(lines):
    line = lines[i]
    m = hdr.match(line)
    if not m:
        out.append(line)
        i += 1
        continue

    j = i + 1
    body = []
    while j < len(lines) and not lines[j].startswith(("@@", "diff --git")):
        body.append(lines[j])
        j += 1

    # Process only the hunk that inserts susfs_def.h and uses dma-buf.h as context.
    if any(l.strip() == "#include <linux/dma-buf.h>" for l in body) \
            and any("susfs_def.h" in l for l in body):
        kept = [l for l in body if l.strip() != "#include <linux/dma-buf.h>"]
        dropped += len(body) - len(kept)
        old = sum(1 for l in kept if l[:1] in (" ", "-"))
        new = sum(1 for l in kept if l[:1] in (" ", "+"))
        line = "@@ -%s,%d +%s,%d @@" % (m.group(1), old, m.group(3), new)
        body = kept

    out.append(line)
    out.extend(body)
    i = j

if dropped:
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("\n".join(out) + "\n")
    print("fs/exec.c patch context normalized (removed %d stale dma-buf context lines)" % dropped)
else:
    print("fs/exec.c patch context does not need normalization")
PYEOF
}

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  echo "Normalizing fs/exec.c header context in the Android 16 6.12 main patch"
  normalize_exec_include_hunk
fi

# Newer kernels add trace/hooks/fs.h after internal.h in super.c. The old SUSFS main
# patch inserts the extern declaration using thaw_super_locked as context, so the
# entire hunk is rejected. Since 2026-09-15, upstream has moved the declaration after
# unnamed_dev_ida, removing this context dependency. The ShirkNeko fork has not synced
# this change yet (its pinned older patch does not modify super.c), so temporarily
# adjust only the older patch.
SUPER_FS_H_REMOVED=""
if grep -q '^ static int thaw_super_locked' "$SUSFS_PATCH" \
  && grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "Temporarily adjusting super.c context"
  sed -i '/^#include <trace\/hooks\/fs.h>$/,+1d' fs/super.c
  SUPER_FS_H_REMOVED=1
fi

# After the upstream rebase to 5.15.211, the susfs_def.h insertion hunk uses trace/hooks
# headers as context. Sources for 5.15.74–194 lack these lines, so the whole hunk is
# rejected and compilation stops under clang -Werror due to implicit declarations of
# SUSFS_IS_INODE_*. Normalize the patch copy to match the actual source.
echo "Normalizing SUSFS header context"
python3 "$SCRIPT_DIR/normalize_trace_ctx.py" "$SUSFS_PATCH"

patch -p1 < "$SUSFS_PATCH" || true

# ==================== FinaSU New selinux_hide Model Adaptation ====================
# Starting with FinaSU v0.1.0-preview1, kernel/feature/selinux_hide.c uses tiann's new model:
#   fake_state is removed; backup_sepolicy + security_context_to_sid_with_policy(..., &orig_sid_p, &orig_rc_p) (8 args) is used;
#   this function also performs "dual-policy + global sidtab synchronization" internally (KernelSU #3877/#3873).
# In this model, switch SELinux code in the SUSFS main patch for <6.6 from &fake_state
# to backup_sepolicy + the 8-argument _with_policy call, and restore the permission-check
# order (df03912f). sidtab synchronization is built into upstream _with_policy, so no
# separate backport is needed.
NEW_MODEL=0
FINASU_SELINUX_HIDE="$KERNEL_ROOT/KernelSU/kernel/feature/selinux_hide.c"
if [ -f "$FINASU_SELINUX_HIDE" ] && ! grep -q 'fake_state' "$FINASU_SELINUX_HIDE"; then
  NEW_MODEL=1
fi
# Conditions:
#   The <6.6 (5.10/5.15/6.1) main patch inlines changes to selinuxfs call sites /
#   selinux_setprocattr and references &fake_state.
#   The >=6.6 (6.6/6.12) main patch uses backup_sepolicy + the kernel's own
#   my_security_context_to_sid and does not reference fake_state, so this branch is
#   unnecessary (neither grep matches, and it is skipped automatically).
# For <6.6, switch from fake_state to backup_sepolicy + the 8-argument _with_policy
# call; otherwise the new FinaSU model has no fake_state definition and ThinLTO fails
# to link with undefined symbol: fake_state.
if [ "$NEW_MODEL" = 1 ] && [ -f security/selinux/selinuxfs.c ] \
  && { grep -q 'static ssize_t my_write_context' security/selinux/selinuxfs.c \
       || grep -q '&fake_state' security/selinux/selinuxfs.c; }; then
  echo "Detected the new FinaSU selinux_hide model: switching SUSFS <6.6 SELinux code to backup_sepolicy + 8-argument _with_policy"
  python3 - <<'PYEOF'
import re as _re, sys as _sys

NEW_FS_EXTERNS = (
    "extern struct selinux_policy *backup_sepolicy;\n"
    "extern int security_context_to_sid_with_policy(struct selinux_policy *policy, const char *scontext, u32 scontext_len, u32 *sid, u32 def_sid, gfp_t gfp_flags, u32 *orig_sid_p, int *orig_rc_p);\n"
    "extern int security_sid_to_context_with_policy(struct selinux_policy *policy, u32 sid, char **scontext, u32 *scontext_len);\n"
    "extern void security_compute_av_user_with_policy(struct selinux_policy *policy, u32 ssid, u32 tsid, u16 tclass, struct av_decision *avd);\n"
)
NEW_HK_EXTERNS = (
    "extern struct selinux_policy *backup_sepolicy;\n"
    "extern int security_context_to_sid_with_policy(struct selinux_policy *policy, const char *scontext, u32 scontext_len, u32 *sid, u32 def_sid, gfp_t gfp_flags, u32 *orig_sid_p, int *orig_rc_p);\n"
)

def _sub(path, name, old, new):
    s = open(path, encoding="utf-8", errors="surrogateescape").read()
    n = s.count(old)
    if n != 1:
        print("::warning::%s: %s count=%d (expect 1)" % (path, name, n))
        return
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(old, new, 1))
    print("%s: %s OK" % (path, name))

fs = "security/selinux/selinuxfs.c"
_sub(fs, "extern", "extern struct selinux_state fake_state;\n", NEW_FS_EXTERNS)
_sub(fs, "ctx", "security_context_to_sid(&fake_state, buf, size, &sid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, buf, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "sid2ctx", "security_sid_to_context(&fake_state, sid, &canon, &len)",
     "security_sid_to_context_with_policy(backup_sepolicy, sid, &canon, &len)")
_sub(fs, "scon", "security_context_str_to_sid(&fake_state, scon, &ssid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, scon, strlen(scon), &ssid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "tcon", "security_context_str_to_sid(&fake_state, tcon, &tsid, GFP_KERNEL)",
     "security_context_to_sid_with_policy(backup_sepolicy, tcon, strlen(tcon), &tsid, SECSID_NULL, GFP_KERNEL, NULL, NULL)")
_sub(fs, "av", "security_compute_av_user(&fake_state, ssid, tsid, tclass, &avd)",
     "security_compute_av_user_with_policy(backup_sepolicy, ssid, tsid, tclass, &avd)")

hk = "security/selinux/hooks.c"
_sub(hk, "extern", "extern struct selinux_state fake_state;\n", NEW_HK_EXTERNS)

# <6.6 form: resolve(&fake_state, value) -> _with_policy (8 arguments)
#   The 6.1 main patch uses multi-line &sid; the 5.15 main patch uses single-line &tmp_sid. Normalize both.
_hs = open(hk, encoding="utf-8", errors="surrogateescape").read()
_hs, _n = _re.subn(r"security_context_to_sid\(&fake_state, value, size,\s*\n\s*&sid, GFP_KERNEL\)",
                   "security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)", _hs)
_hs, _n15 = _re.subn(r"security_context_to_sid\(&fake_state, value, size, &tmp_sid, GFP_KERNEL\)",
                     "security_context_to_sid_with_policy(backup_sepolicy, value, size, &tmp_sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)", _hs)
print("%s: setprocattr.ctx <6.6=%d/%d" % (hk, _n, _n15))
open(hk, "w", encoding="utf-8", errors="surrogateescape").write(_hs)

# >=6.6 form: update existing 6-argument _with_policy declarations/calls to 8 arguments (the new model signature).
#   The 6.6 main patch includes 6-argument extern declarations in security/selinux/{hooks,selinuxfs}.c.
#   Updating only the calls to 8 arguments causes "too many arguments to function call, expected 6, have 8".
#   Therefore, update the extern declarations and calls together to 8 arguments (the new FinaSU definition).
for _lab, _f in (("selinuxfs", fs), ("hooks", hk)):
    _s = open(_f, encoding="utf-8", errors="surrogateescape").read()
    # (?!, NULL, NULL) ensures idempotency: calls already changed to 8 arguments above for <6.6 are not modified again.
    _s, _n2 = _re.subn(r"(security_context_to_sid_with_policy\(backup_sepolicy,[^;]*?, GFP_KERNEL)\)(?!, NULL, NULL)", r"\1, NULL, NULL)", _s)
    _s, _nd = _re.subn(r"(security_context_to_sid_with_policy\(struct selinux_policy \*policy, const char \*scontext, u32 scontext_len,\s*\n\s*u32 \*sid, u32 def_sid, gfp_t gfp_flags)\);", r"\1, u32 *orig_sid_p, int *orig_rc_p);", _s)
    open(_f, "w", encoding="utf-8", errors="surrogateescape").write(_s)
    print("%s: _with_policy 8-arg normalize=%d decl=%d" % (_lab, _n2, _nd))

_hs = open(hk, encoding="utf-8", errors="surrogateescape").read()
# Two setprocattr forms in the main patch:
#   Old form (main patches before ~2026-08): defines my_setprocattr with an unconditional
#     SETCURRENT avc_has_perm check — requires rm_early removal + sequence reordering (df03912f).
#   Current form (main patches since 2026-10): inlines changes to selinux_setprocattr and
#     gates with should_check_current + fake_error — the permission order inherently
#     satisfies df03912f, and fake parsing is converted above by setprocattr.ctx to the
#     8-argument _with_policy call (with built-in sidtab synchronization); rm_early/seq
#     have no target code.
if "should_check_current" in _hs and "fake_error = security_context_to_sid_with_policy(backup_sepolicy, value, size, &tmp_sid, SECSID_NULL, GFP_KERNEL, NULL, NULL)" in _hs:
    print("%s: main patch uses the current gated form (should_check_current+fake_error); rm_early_setcurrent/seq do not apply, side-channel semantics are already covered" % hk)
else:
    # Remove the unconditional SETCURRENT check (df03912f), covering both <6.6 (&selinux_state) and >=6.6 (no state) forms.
    _removed = False
    for _rm in ("\terror = avc_has_perm(&selinux_state,\n\t\t\t\t     mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL);\n\n\tif (error)\n\t\treturn error;\n\n",
                "\terror = avc_has_perm(mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL);\n\n\tif (error)\n\t\treturn error;\n\n"):
        if _hs.count(_rm) == 1:
            _hs = _hs.replace(_rm, "", 1)
            _removed = True
            print("%s: rm_early_setcurrent OK" % hk)
            break
    if not _removed:
        print("::warning::%s: rm_early_setcurrent not matched" % hk)
    # Check SETCURRENT only when backup parsing fails.
    _seq_done = False
    for _old2, _new2, _lab in (
        ("\t\terror = security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error)\n\t\t\treturn error;\n",
         "\t\terror = security_context_to_sid_with_policy(backup_sepolicy, value, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error) {\n\t\t\tint perm_error = avc_has_perm(&selinux_state, mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n", "<6.6"),
        ("\t\terror = security_context_to_sid_with_policy(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error)\n\t\t\treturn error;\n",
         "\t\terror = security_context_to_sid_with_policy(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL, NULL, NULL);\n\t\tif (error) {\n\t\t\tint perm_error = avc_has_perm(mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n", ">=6.6")):
        if _hs.count(_old2) == 1:
            _hs = _hs.replace(_old2, _new2, 1)
            _seq_done = True
            print("%s: seq(%s) OK" % (hk, _lab))
            break
    if not _seq_done:
        print("::warning::%s: seq not matched" % hk)
open(hk, "w", encoding="utf-8", errors="surrogateescape").write(_hs)
for _f in (fs, hk):
    _s = open(_f, encoding="utf-8", errors="surrogateescape").read()
    if "fake_state" in _s:
        _sys.stderr.write("::error::%s still contains fake_state references\n" % _f)
        _sys.exit(1)
PYEOF
  # Informational output only; the 5.15 main patch does not contain perm_error
  # (permission-order reordering applies only to the my_write_context form), so grep
  # may not match. || true is required here or set -e will abort the entire patch step.
  grep -n 'backup_sepolicy' security/selinux/selinuxfs.c | head -3 || true
  grep -n 'perm_error' security/selinux/hooks.c | head -3 || true
fi

# ==================== Backport KernelSU SELinux Hide Side-Channel Fixes (Old fake_state Form) ====================
# Applies only when the SUSFS main patch uses the old form (defines my_write_context/
# my_write_access/my_setprocattr). Detection can use /sys/fs/selinux/{context,access}
# and setprocattr as oracles: compare SIDs between the fake policy (fake_state) and
# global selinux_state, as well as the permission-check order, to detect hiding.
# The SUSFS main patch implementations of my_write_context / my_write_access /
# my_setprocattr lack both protections; add them here following KernelSU:
#   - sidtab synchronization (KernelSU #3873): parse with the fake policy, then sync
#     into the global sidtab to eliminate SID differences.
#   - Permission-check order (KernelSU df03912f): check SETCURRENT only when backup parsing fails.
# The current main patch (since 2026-10) no longer defines these three functions.
# The gated inline form for <6.6 and the 8-argument _with_policy conversion in the
# NEW_MODEL branch (with built-in sidtab synchronization) provide equivalent
# side-channel fixes; see the else-branch explanation below.
if [ "${NEW_MODEL:-0}" != 1 ] && [ -f security/selinux/selinuxfs.c ] && grep -q 'static ssize_t my_write_context' security/selinux/selinuxfs.c \
  && [ -f security/selinux/hooks.c ] && grep -q 'static int my_setprocattr' security/selinux/hooks.c; then
  python3 - <<'PYEOF'
import re

def sed(path, name, pat, repl):
    src = open(path, encoding="utf-8", errors="surrogateescape").read()
    new, n = re.subn(pat, repl, src, count=1)
    if n == 0:
        print("::warning::%s: %s not matched (skip)" % (path, name))
        return
    open(path, "w", encoding="utf-8", errors="surrogateescape").write(new)
    print("%s: %s OK" % (path, name))

fs = "security/selinux/selinuxfs.c"
# my_write_context (<6.6 parses with fake_state; >=6.6 parses with backup_sepolicy's _with_policy).
sed(fs, "ctx(<6.6)", r"(\tlength = security_context_to_sid\(&fake_state, buf, size, &sid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(&selinux_state, buf, size, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "ctx(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, buf, size, &sid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(buf, size, &tmp_sid, GFP_KERNEL);\n\t}\n")
# my_write_access scon / tcon
sed(fs, "scon(<6.6)", r"(\tlength = security_context_str_to_sid\(&fake_state, scon, &ssid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_str_to_sid(&selinux_state, scon, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "scon(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, scon, strlen\(scon\), &ssid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(scon, strlen(scon), &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "tcon(<6.6)", r"(\tlength = security_context_str_to_sid\(&fake_state, tcon, &tsid, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_str_to_sid(&selinux_state, tcon, &tmp_sid, GFP_KERNEL);\n\t}\n")
sed(fs, "tcon(>=6.6)", r"(\tlength = security_context_to_sid_with_policy\(backup_sepolicy, tcon, strlen\(tcon\), &tsid, SECSID_NULL, GFP_KERNEL\);\n\tif \(length\)\n\t\tgoto out;\n)",
    "\\1\t{\n\t\tu32 tmp_sid;\n\t\t/* FINASU_SIDTAB_SYNC */\n\t\tsecurity_context_to_sid(tcon, strlen(tcon), &tmp_sid, GFP_KERNEL);\n\t}\n")

hk = "security/selinux/hooks.c"
# Remove the unconditional SETCURRENT check (<6.6 includes &selinux_state; >=6.6 does not).
sed(hk, "rm_early(<6.6)", r"\terror = avc_has_perm\(&selinux_state,\n\t\t\t\t     mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL\);\n\n\tif \(error\)\n\t\treturn error;\n\n", "")
sed(hk, "rm_early(>=6.6)", r"\terror = avc_has_perm\(mysid, mysid, SECCLASS_PROCESS,\n\t\t\t\t     PROCESS__SETCURRENT, NULL\);\n\n\tif \(error\)\n\t\treturn error;\n\n", "")
# Check SETCURRENT only when backup parsing fails, and synchronize the global sidtab.
sed(hk, "seq+sync(<6.6)", r"(\t\terror = security_context_to_sid\(&fake_state, value, size,\n\t\t\t\t\t\t&sid, GFP_KERNEL\);\n)\t\tif \(error\)\n\t\t\treturn error;\n",
    "\\1\t\tif (error) {\n\t\t\t    /* FINASU_SEQ: check SETCURRENT only when backup parsing fails (KernelSU df03912f) */\n\t\t\tint perm_error = avc_has_perm(&selinux_state, mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n\t\t{\n\t\t\tu32 tmp_sid;\n\t\t\t/* FINASU_SIDTAB_SYNC (KernelSU #3873) */\n\t\t\tsecurity_context_to_sid(&selinux_state, value, size, &tmp_sid, GFP_KERNEL);\n\t\t}\n")
sed(hk, "seq+sync(>=6.6)", r"(\t\terror = security_context_to_sid_with_policy\(backup_sepolicy, str, size, &sid, SECSID_NULL, GFP_KERNEL\);\n)\t\tif \(error\)\n\t\t\treturn error;\n",
    "\\1\t\tif (error) {\n\t\t\t    /* FINASU_SEQ: check SETCURRENT only when backup parsing fails (KernelSU df03912f) */\n\t\t\tint perm_error = avc_has_perm(mysid, mysid, SECCLASS_PROCESS, PROCESS__SETCURRENT, NULL);\n\t\t\treturn perm_error ?: error;\n\t\t}\n\t\t{\n\t\t\tu32 tmp_sid;\n\t\t\t/* FINASU_SIDTAB_SYNC (KernelSU #3873) */\n\t\t\tsecurity_context_to_sid(str, size, &tmp_sid, GFP_KERNEL);\n\t\t}\n")
PYEOF
  # Informational output only; grep may not match when part of the old form differs.
  # || true is required or pipefail will abort the entire patch step.
  grep -n 'FINASU_SIDTAB_SYNC' security/selinux/selinuxfs.c | head || true
  grep -n 'FINASU_SIDTAB_SYNC\|FINASU_SEQ' security/selinux/hooks.c | head || true
else
  # Determine the main patch form:
  #   The old form defines my_write_context/my_write_access/my_setprocattr; if any are
  #   missing, retain the warning because this is unexpected.
  #   The current form (main patches since 2026-10) no longer defines these functions:
  #   for <6.6 it inlines changes to selinux_setprocattr / selinuxfs call sites (gated by
  #   should_check_current+fake_error); for >=6.6 it uses backup_sepolicy +
  #   my_security_context_to_sid (provided by the kernel). The NEW_MODEL branch's
  #   8-argument _with_policy conversion and gate checks cover the sidtab synchronization
  #   (#3873) and permission ordering (df03912f), so no old-form backport is needed.
  if grep -qE 'static ssize_t my_write_(context|access)' security/selinux/selinuxfs.c 2>/dev/null \
    || grep -q 'static int my_setprocattr' security/selinux/hooks.c 2>/dev/null; then
    echo "::warning::SUSFS my_write_context/my_setprocattr not found; skipping SELinux side-channel backport"
  else
    echo "SUSFS main patch uses the current form (no my_write_context/my_setprocattr): side-channel fixes are covered by gate checks and built-in synchronization in the 8-argument _with_policy; no old-form backport is needed"
  fi
fi

# ==================== SUSFS Path-Hiding Fallback (Cross-Namespace / FUSE) ====================
# susfs_add_sus_path (non-loop) resolves paths with kern_path in the caller's
# namespace. The manager/ksud often cannot resolve FUSE paths such as
# /storage/emulated (-ENOENT), so the rule cannot be added and path hiding fails.
# Add a fallback: on resolution failure, automatically use the LOOP mechanism
# (the kernel workqueue resolves the path later in the init namespace and marks it).
if [ -f fs/susfs.c ] && grep -qF 'void susfs_add_sus_path(void __user **user_info)' fs/susfs.c \
  && ! grep -qF 'FINASU_SUS_PATH_LOOP_FALLBACK' fs/susfs.c; then
  python3 - <<'PYEOF'
p = "fs/susfs.c"
s = open(p, encoding="utf-8", errors="surrogateescape").read()
old1 = "void susfs_add_sus_path(void __user **user_info) {"
new1 = "void susfs_add_sus_path_loop(void __user **user_info);\n" + old1
if s.count(old1) != 1:
    print("::warning::fs/susfs.c: susfs_add_sus_path signature is not in the expected form; skipping")
else:
    s = s.replace(old1, new1, 1)
    old2 = ("\tif (copy_from_user(&info, (struct st_susfs_sus_path __user*)*user_info, sizeof(info))) {\n"
            "\t\tinfo.err = -EFAULT;\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n\n"
            "\tinfo.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);\n"
            "\tif (info.err) {\n"
            "\t\tSUSFS_LOGE(\"failed opening file '%s'\\n\", info.target_pathname);\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n")
    new2 = ("\tif (copy_from_user(&info, (struct st_susfs_sus_path __user*)*user_info, sizeof(info))) {\n"
            "\t\tinfo.err = -EFAULT;\n"
            "\t\tgoto out_copy_to_user;\n"
            "\t}\n\n"
            "\tinfo.err = kern_path(info.target_pathname, LOOKUP_FOLLOW, &path);\n"
            "\tif (info.err) {\n"
            "\t\tSUSFS_LOGE(\"failed opening '%s' in current ns, fallback to sus_path_loop\\n\", info.target_pathname);\n"
            "\t\t/* FINASU_SUS_PATH_LOOP_FALLBACK: if the path cannot be resolved in the caller's namespace\n"
            "\t\t   (common for FUSE paths such as /storage/emulated), fall back to LOOP so the kernel\n"
            "\t\t   workqueue can resolve it later in the init namespace and mark it again. */\n"
            "\t\tsusfs_add_sus_path_loop(user_info);\n"
            "\t\treturn;\n"
            "\t}\n")
    if s.count(old2) != 1:
        print("::warning::fs/susfs.c: susfs_add_sus_path code is not in the expected form; skipping fallback")
    else:
        open(p, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(old2, new2, 1))
        print("fs/susfs.c: added SUSFS path-hiding LOOP fallback")
PYEOF
  grep -n 'FINASU_SUS_PATH_LOOP_FALLBACK' fs/susfs.c | head
else
  echo "::warning::fs/susfs.c susfs_add_sus_path not found; skipping path-hiding fallback"
fi


# ---- Handle expected conflicts: remove .rej files for changes already upstream; manually add genuinely missing changes. ----

# 1) fs/unicode: ASB kernels already include upstream's "unicode: don't special case ignorable code
#    points" commit; the main patch hunks that remove ignore_init / regenerate utf8data are already satisfied.
if [[ -f fs/unicode/mkutf8data.c.rej ]] && ! grep -q 'ignore_init' fs/unicode/mkutf8data.c; then
  echo "fs/unicode .rej: upstream already contains the change; removing expected conflict file"
  rm -f fs/unicode/*.rej
fi

# 2) mm/rmap.c: 6.6.127+ already includes the TLB conversion for huge_pmd_unshare.
if [[ -f mm/rmap.c.rej ]] && grep -q 'tlb_gather_mmu_vma' mm/rmap.c; then
  echo "mm/rmap.c .rej: upstream already contains the change; removing expected conflict file"
  rm -f mm/rmap.c.rej
fi

# 3) fs/proc/task_mmu.c (6.12.69+): the show_smap refactor (vma_pages → vma_data_pages)
#    causes the SUS_MAP check hunk to be rejected due to context mismatch; this is a genuine omission, so add it manually.
if [[ -f fs/proc/task_mmu.c.rej ]] \
  && grep -qF 'static int show_smap(struct seq_file *m, void *v)' fs/proc/task_mmu.c; then
  SHOW_SMAP_BODY="$(sed -n '/^static int show_smap(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c)"
  if [[ -n "$SHOW_SMAP_BODY" ]] && ! grep -qF 'SUSFS_IS_INODE_SUS_MAP' <<< "$SHOW_SMAP_BODY"; then
    echo "Manually adding the SUS_MAP check to show_smap (6.12.69+ context drift)"
    perl -0pi -e 's/(static int show_smap\(struct seq_file \*m, void \*v\)\n\{\n\tstruct vm_area_struct \*vma = v;\n\tstruct mem_size_stats mss = \{\};\n)/$1\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tif (vma->vm_file) {\n\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\treturn 0;\n\t}\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n/' fs/proc/task_mmu.c
    if ! grep -qF 'SUSFS_IS_INODE_SUS_MAP' fs/proc/task_mmu.c; then
      echo "::error::Failed to manually patch the show_smap SUS_MAP check; inspect fs/proc/task_mmu.c"
      exit 1
    fi
  fi

  # In the same file, 6.12.69+ also rewrites show_smaps_rollup to use VMA_ITERATOR +
  # for_each_vma (removing the out_unlock branch), so both main-patch hunks that
  # depend on the old context are rejected. This does not affect compilation, but
  # SUS_MAP-marked VMAs would leak through /proc/<pid>/smaps_rollup. Skip the entire
  # VMA at the entry to the do loop and update last_vma_end, matching the semantics
  # of the main patch's bypass_orig_flow.
  if grep -qF 'bypass_orig_flow' fs/proc/task_mmu.c.rej \
    && ! sed -n '/^static int show_smaps_rollup(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
    echo "Manually adding SUS_MAP skip logic to show_smaps_rollup (6.12.69+ context drift)"
    python3 - <<'PYEOF'
p = "fs/proc/task_mmu.c"
s = open(p, encoding="utf-8", errors="surrogateescape").read()
start = s.find("static int show_smaps_rollup(struct seq_file *m, void *v)")
end = s.find("\n}\n", start)
if start < 0 or end < 0:
    print("::error::fs/proc/task_mmu.c: show_smaps_rollup not found")
    raise SystemExit(1)
body = s[start:end]
needle = "\tdo {\n\t\tsmap_gather_stats(vma, &mss, 0);\n"
insert = (
    "\tdo {\n"
    "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\t/* Skip the entire SUS_MAP-marked VMA to prevent leakage in rollup. */\n"
    "\t\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file))) {\n"
    "\t\t\tlast_vma_end = vma->vm_end;\n"
    "\t\t\tcontinue;\n"
    "\t\t}\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
    "\t\tsmap_gather_stats(vma, &mss, 0);\n"
)
if "SUSFS_IS_INODE_SUS_MAP" in body:
    print("show_smaps_rollup already contains the SUS_MAP check; skipping")
elif body.count(needle) != 1:
    print("::error::show_smaps_rollup loop entry is not in the expected form; skipping")
    raise SystemExit(1)
else:
    s = s[:start] + body.replace(needle, insert, 1) + s[end:]
    open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
    print("show_smaps_rollup: added SUS_MAP skip logic")
PYEOF
    if ! sed -n '/^static int show_smaps_rollup(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
      echo "::error::Failed to manually patch show_smaps_rollup SUS_MAP skip logic; inspect fs/proc/task_mmu.c"
      exit 1
    fi
  fi

  # All rejected hunks have been handled; remove .rej files to keep the Rejects artifact clean.
  TASK_MMU_UNRESOLVED=0
  if grep -qF 'bypass_orig_flow' fs/proc/task_mmu.c.rej \
    && ! sed -n '/^static int show_smaps_rollup(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
    TASK_MMU_UNRESOLVED=1
  fi
  if grep -qF 'static int show_smap(struct seq_file *m, void *v)' fs/proc/task_mmu.c.rej \
    && ! sed -n '/^static int show_smap(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c \
      | grep -qF 'SUSFS_IS_INODE_SUS_MAP'; then
    TASK_MMU_UNRESOLVED=1
  fi
  if [[ "$TASK_MMU_UNRESOLVED" -eq 0 ]]; then
    # Remove the file only if all rejected hunks are in the two handled functions,
    # so new upstream drift is not hidden.
    UNKNOWN_HUNK="$(grep '^@@' fs/proc/task_mmu.c.rej | grep -vE 'show_smap|show_smaps_rollup' || true)"
    if [[ -z "$UNKNOWN_HUNK" ]]; then
      echo "fs/proc/task_mmu.c: all rejected hunks have been handled; removing .rej"
      rm -f fs/proc/task_mmu.c.rej
    else
      echo "::warning title=task_mmu conflict::Unrecognized hunks remain; retaining .rej for investigation:"
      echo "$UNKNOWN_HUNK"
    fi
  fi
fi

# The upstream 5.10 main patch places the extern declaration for
# susfs_sus_kstat_spoof_vfs_statfs after its use in fs/statfs.c (before vfs_statfs),
# causing an implicit-declaration error under clang -Werror. Add this SUSFS
# declaration directly to the public header include/linux/susfs_def.h:
# this avoids depending on an anchor or line-number comparison in statfs.c; duplicate
# declarations are valid and will not conflict if upstream fixes this later.
# Note: FinaSU's setuid_hook.c / sucompat.c include susfs_def.h when only basic headers
# such as <linux/types.h> have been included. At that point struct kstatfs is not yet
# declared, and introducing a new struct tag in the prototype triggers
# clang -Werror,-Wvisibility (confirmed by upstream kernel build logs), so add a
# forward declaration of the struct as well.
SUSFS_DEF_H="$KERNEL_ROOT/common/include/linux/susfs_def.h"
if [[ -f fs/statfs.c ]] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c \
  && [[ -f "$SUSFS_DEF_H" ]] \
  && ! grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' "$SUSFS_DEF_H"; then
  echo "Adding the susfs_sus_kstat_spoof_vfs_statfs declaration to include/linux/susfs_def.h"
  sed -i '/^#endif \/\/ #ifndef KSU_SUSFS_DEF_H$/i struct inode;\nstruct kstatfs;\nextern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' "$SUSFS_DEF_H"
fi

# Upstream susfs.c calls security_sb_statfs directly without including linux/security.h.
# Other headers indirectly provide it on 5.15+, but not on 5.10, where clang -Werror
# reports an implicit declaration; add the include if it is missing.
if [[ -f fs/susfs.c ]] && grep -qF 'security_sb_statfs(' fs/susfs.c \
  && ! grep -qF '#include <linux/security.h>' fs/susfs.c; then
  echo "Adding the linux/security.h header to susfs.c"
  sed -i '0,/^#include <linux\/fs.h>$/s//#include <linux\/fs.h>\n#include <linux\/security.h>/' fs/susfs.c
fi

# Report conflict files produced by the SUSFS main patch before compilation.
SUSFS_REJ_COUNT=$(find . -name '*.rej' | wc -l)
if [ "$SUSFS_REJ_COUNT" -gt 0 ]; then
  echo "::warning title=SUSFS patch conflicts::The SUSFS main patch produced ${SUSFS_REJ_COUNT} .rej conflict files, which may cause a later build failure (see the Rejects artifact)"
  find . -name '*.rej' -print
fi

# Restore temporary source adjustments that were made only to match the patch.
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "Restoring temporary Android 12 5.10 base.c adjustment"
    sed -i 's/^size_t this_len = min_t(size_t, count, PAGE_SIZE);$/int this_len = min_t(int, count, PAGE_SIZE);/' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "Restoring temporary Android 12 5.10 fdinfo.c adjustment"
    restore_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "Restoring temporary Android 13 5.15 adjustment"
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/namespace.c
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/open.c
    restore_legacy_fdinfo_context
    sed -i 's|i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|g' fs/susfs.c
    sed -i 's|i_uid_into_mnt(i_user_ns(inode), inode).val|i_uid_into_mnt(\&init_user_ns, inode).val|g' fs/susfs.c
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "Restoring Android 13 5.15 LTS header context"
    if ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
      sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
      sed -i '/^#include <linux\/pkeys.h>$/a #include <trace/hooks/mm.h>' fs/proc/task_mmu.c
    fi
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]]; then
    sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]]; then
    echo "Restoring temporary Android 14 6.1 base.c adjustment"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]] && ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "Restoring temporary Android 14 6.1 namespace.c adjustment"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]]; then
    echo "Restoring temporary Android 15 6.6 base.c adjustment"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]]; then
    echo "Restoring temporary Android 15 6.6 memory.c adjustment"
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
  fi
fi

if [[ -n "$SUPER_FS_H_REMOVED" ]] \
  && ! grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "Restoring temporary super.c adjustment"
  sed -i '/^#include "internal.h"$/a #include <trace/hooks/fs.h>' fs/super.c
fi

fix_missing_vm_flags_clear() {
  if [[ "$OS_PATCH_LEVEL" == "2024-11" ]] && grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' ./mm/mmap.c; then
    sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' ./mm/mmap.c
  fi
}

fix_task_mmu_show_pad() {
  local max_sub="$1"
  local excluded_patch_level="${2:-}"

  # Only pinned older SUSFS patches introduce goto show_pad; the latest patch no longer contains this code.
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le "$max_sub" ]] \
    && { [[ -z "$excluded_patch_level" ]] || [[ "$OS_PATCH_LEVEL" != "$excluded_patch_level" ]]; }; then
    sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c
  fi
}

# Android 12 - 5.10 fixes.
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  # Fix for the 2024-11 branch: mmap.c calls vm_flags_clear(), but mm.h on that branch does not provide the helper.
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 209
fi

# Android 13 - 5.15 fixes.
  if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  # Fix for the 2024-11 branch: mmap.c calls vm_flags_clear(), but mm.h on that branch does not provide the helper.
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 148 "2024-05"
fi

# Android 14 - 6.1 fixes.
if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  fix_task_mmu_show_pad 75 "2024-05"
fi

# Android 15 - 6.6 fixes.
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  # Fix for older SukiSU 6.6.50–6.6.58: after SUSFS is applied, task_mmu.c uses vma, but the old source lacks the corresponding declaration.
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -ge 50 && "$CURRENT_SUB" -le 58 ]] \
    && grep -qF 'vma = find_vma(mm, start_vaddr);' ./fs/proc/task_mmu.c; then
    TASK_MMU_PATCH="$KERNEL_PATCHES/wild/archived/susfs_fix_patches/v2.1.0/a15-6.6/task_mmu.c.patch"
    if [ ! -f "$TASK_MMU_PATCH" ]; then
      echo "::error::Patch not found: $TASK_MMU_PATCH"
      exit 1
    fi
    cp "$TASK_MMU_PATCH" ./
    if patch -p1 --dry-run < task_mmu.c.patch >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < task_mmu.c.patch
      echo "Applied the archived task_mmu.c fix patch for Android 15 6.6.50–6.6.58"
    else
      echo "The archived Android 15 6.6.50–6.6.58 task_mmu.c fix patch is already applied or the current context does not match; skipping"
    fi
  fi
fi

# Android 16 - 6.12 fixes.
if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  # Pinned older SukiSU versions duplicate the setresuid hook definition on 6.12.
  SETUID_HOOK="$KERNEL_ROOT/common/drivers/kernelsu/setuid_hook.c"
  if [[ -n "$LEGACY_SUKISU_CONFIG" && -f "$SETUID_HOOK" ]] \
    && grep -qF 'defined(CONFIG_KSU_MANUAL_HOOK))' "$SETUID_HOOK"; then
    sed -i 's/defined(CONFIG_KSU_MANUAL_HOOK))/!defined(CONFIG_KSU_SUSFS) \&\& defined(CONFIG_KSU_MANUAL_HOOK))/' "$SETUID_HOOK"
    echo "Fixed duplicate definition in setuid_hook.c"
  fi
fi

# Guard: if context drift causes the main patch to omit susfs_def.h again, report a
# readable error here instead of waiting for a series of SUSFS_IS_INODE_* implicit
# declaration errors while compiling fs/proc/task_mmu.c.
for SUSFS_SRC in fs/proc/task_mmu.c fs/namespace.c; do
  [[ -f "$SUSFS_SRC" ]] || continue
  if grep -qE 'SUSFS_IS_INODE_|CL_COPY_MNT_NS' "$SUSFS_SRC" \
    && ! grep -qF '#include <linux/susfs_def.h>' "$SUSFS_SRC"; then
    echo "::error::$SUSFS_SRC uses SUSFS macros but is missing linux/susfs_def.h; the main patch hunk was not applied"
    exit 1
  fi
done
