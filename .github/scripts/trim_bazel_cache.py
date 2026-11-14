#!/usr/bin/env python3
"""Trim the Bazel disk cache to a size budget before it is saved to the Actions cache.

Bazel refreshes an entry's mtime whenever a build uses it, so deleting the oldest
files first drops what recent builds no longer need. The repository cache (external
downloads) is small and counted, but never trimmed.

usage: trim_bazel_cache.py <disk_cache_dir> <repository_cache_dir> <budget_gb>
"""
import os
import sys


def files_under(root):
    for dirpath, _, names in os.walk(root):
        for name in names:
            path = os.path.join(dirpath, name)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            yield path, st.st_size, st.st_mtime


def main():
    disk_cache, repo_cache, budget_gb = sys.argv[1], sys.argv[2], float(sys.argv[3])
    budget = int(budget_gb * 1024 ** 3)

    repo_bytes = sum(size for _, size, _ in files_under(repo_cache))
    entries = sorted(files_under(disk_cache), key=lambda e: e[2])  # oldest first
    total = repo_bytes + sum(size for _, size, _ in entries)
    gib = 1024 ** 3
    print("Bazel caches: %.2f GiB (repository cache %.2f GiB), budget %.2f GiB"
          % (total / gib, repo_bytes / gib, budget / gib))

    removed = 0
    for path, size, _ in entries:
        if total <= budget:
            break
        try:
            os.remove(path)
        except OSError:
            continue
        total -= size
        removed += size
    print("Trimmed %.2f GiB, %.2f GiB left to save" % (removed / gib, total / gib))


if __name__ == "__main__":
    main()
