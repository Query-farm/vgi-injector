#!/bin/sh
# Copyright 2026 Query.Farm LLC
# Licensed under the Apache License, Version 2.0
#
# Downloads the Mozilla CA certificate bundle if missing or older than 7 days.
# Source: curl's maintained extraction of Mozilla's CA bundle.

BUNDLE="src/ca-certificates.crt"
MAX_AGE_DAYS=7
URL="https://curl.se/ca/cacert.pem"

needs_update() {
    if [ ! -f "$BUNDLE" ]; then
        return 0
    fi
    if [ "$(uname)" = "Darwin" ]; then
        mod_time=$(stat -f %m "$BUNDLE")
    else
        mod_time=$(stat -c %Y "$BUNDLE")
    fi
    now=$(date +%s)
    age=$(( (now - mod_time) / 86400 ))
    [ "$age" -ge "$MAX_AGE_DAYS" ]
}

if needs_update; then
    echo "Downloading CA bundle from $URL..."
    curl -fsSL -o "$BUNDLE" "$URL"
    echo "CA bundle updated: $(wc -c < "$BUNDLE" | tr -d ' ') bytes"
else
    echo "CA bundle is up to date (less than ${MAX_AGE_DAYS} days old)"
fi
