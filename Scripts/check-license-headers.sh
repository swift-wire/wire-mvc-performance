#!/usr/bin/env bash
#
# Verify every tracked Swift file carries the SPDX licence header.
#
# Headers are checked rather than merely applied once because the failure is silent: a new file
# without one is not a build error, and nothing else in the toolchain looks. SwiftLint's own
# `file_header` rule is not used for this because its `included:` scope covers `Sources` only,
# which would leave tests, plugins and the manifests unchecked.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
project="$(basename "$root")"
cd "$root"

spdx='// SPDX-License-Identifier: Apache-2.0'
copyright="// Copyright (c) [0-9]\{4\} the ${project} project authors"

fail=0
while IFS= read -r file; do
    # The SPDX line is first, except in a manifest, where `// swift-tools-version:` must stay on
    # line 1, and in a file carrying an upstream notice above its own.
    if ! head -5 "$file" | grep -qxF "$spdx"; then
        echo "missing SPDX identifier: $file"
        fail=1
        continue
    fi
    if ! head -12 "$file" | grep -q "$copyright"; then
        echo "missing copyright line: $file"
        fail=1
    fi
done < <(git ls-files '*.swift')

if [ "$fail" -ne 0 ]; then
    cat <<USAGE

Add to the top of each file listed above — in a Package.swift, immediately after the
\`// swift-tools-version:\` line, which must stay first:

    $spdx
    // Copyright (c) $(date +%Y) the ${project} project authors

USAGE
    exit 1
fi

echo "licence headers OK ($(git ls-files '*.swift' | wc -l | tr -d ' ') files)"
