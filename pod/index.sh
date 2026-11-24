#!/bin/bash
# index.sh - Runs inside the index pod. Writes the PACKAGES index for the
# binaries built in this cycle.
set -euxo pipefail

mkdir -p /mnt/tarballs
cd /mnt/tarballs
Rscript -e 'tools::write_PACKAGES(".", addFiles = TRUE, verbose = TRUE, latestOnly = TRUE)'
