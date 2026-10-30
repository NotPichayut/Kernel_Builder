"""Incrementally update GKI kernel version data.

Read existing JSON data, fetch only missing months, and update LTS versions.
"""

import json
import os
import time

from gki_fetch import (
    TARGETS,
    make_date_range, get_end_date,
    fetch_makefile, fetch_lts, parse_version, json_path,
)


def update_target(android_ver: str, kernel_ver: str,
                  date_start: str, date_end: str | None,
                  dep_cutoff: str) -> bool:
    """Incrementally update one target and return whether any data changed."""
    path = json_path(android_ver, kernel_ver)
    end = get_end_date(date_end)
    changed = False

    # Read existing data.
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        entries = data.get("entries", [])
    else:
        data = {
            "android_version": android_ver,
            "kernel_version": kernel_ver,
            "lts": None,
            "entries": [],
        }
        entries = []

    # Determine the date range to fetch.
    # Scan from date_start, skip dates already present, and automatically fill in previously missing months.
    existing_dates = {e["date"] for e in entries}
    all_dates = make_date_range(date_start, end)
    new_dates = [d for d in all_dates if d not in existing_dates]

    if not new_dates:
        print("  No new months to fetch")
    else:
        print(f"  Fetching {len(new_dates)} new month(s): {new_dates[0]} ~ {new_dates[-1]}")
        for date in new_dates:
            label = f"{android_ver}-{kernel_ver}-{date}"
            print(f"    [{label}] ", end="", flush=True)

            text = fetch_makefile(android_ver, kernel_ver, date, dep_cutoff)
            if text is None:
                print("not found, skip")
                continue

            ver = parse_version(text)
            if ver is None:
                print("parse failed, skip")
                continue

            version, patchlevel, sublevel = ver
            detail = f"{version}.{patchlevel}.{sublevel}"
            entries.append({"date": date, "kernel": detail})
            changed = True
            print(f"-> {detail}")
            time.sleep(0.3)

    # Sort by date.
    entries.sort(key=lambda e: e["date"])

    # Update LTS.
    lts_label = f"{android_ver}-{kernel_ver}-lts"
    print(f"  [{lts_label}] ", end="", flush=True)
    lts_text = fetch_lts(android_ver, kernel_ver)
    if lts_text is None:
        print("not found, skip")
    else:
        ver = parse_version(lts_text)
        if ver is None:
            print("parse failed, skip")
        else:
            version, patchlevel, sublevel = ver
            lts_value = f"{version}.{patchlevel}.{sublevel}"
            old_lts = data.get("lts")
            if old_lts != lts_value:
                changed = True
                print(f"-> {lts_value} (was {old_lts})")
            else:
                print(f"-> {lts_value} (unchanged)")
            data["lts"] = lts_value

    # Save.
    data["entries"] = entries
    if changed:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        print(f"  => Saved {len(entries)} entries to {path}")
    else:
        print("  => No changes")

    return changed


def main():
    any_changed = False
    for (android_ver, kernel_ver), (date_start, date_end, dep_cutoff) in TARGETS.items():
        print(f"\n=== {android_ver} / {kernel_ver} ===")
        if update_target(android_ver, kernel_ver, date_start, date_end, dep_cutoff):
            any_changed = True

    print(f"\n{'Data updated.' if any_changed else 'All data up-to-date.'}")
    return any_changed


if __name__ == "__main__":
    import sys
    try:
        changed = main()
    except Exception as e:
        print(f"\nFATAL: {e}", file=sys.stderr)
        sys.exit(1)
    # Exit 0 = data changed, 2 = no changes (both are success)
    sys.exit(0 if changed else 2)
