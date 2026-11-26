#!/bin/bash
# build_pkg.sh - Runs inside a build container. Installs one package with
# `--build` and publishes the results to the cycle's data directory (/mnt).
# Its output (the container log) is the build log that bioc-build judges.
#
# Ported from dispatch_k8s_job.sh in r-container-binaries-k8s-builder. The
# publish protocol is unchanged (see that repo's
# docs/adr/0001-atomic-publish-to-shared-nfs-library.md): a package directory
# in /mnt/library is immutable once published, and files are staged in
# /mnt/.staging and renamed into place, so concurrent builds never see a
# partially written package or tarball.
#
# Input: the PKG environment variable, and optionally BUILD_NCPUS (cores
# for parallel dependency installs and make -j; default 1).

set -euxo pipefail
shopt -s nullglob

: "${PKG:?PKG must be set}"

export TEMP_LIBRARY="/tmp/library"
export SHARED_LIBRARY="/mnt/library"
TARDIR="/mnt/tarballs"
# Same filesystem as the destinations (so rename is atomic) but outside
# every directory that is read (library, tarballs).
STAGEDIR="/mnt/.staging"
# Unique per container; names staging paths on the shared volume.
STAGE_TAG="$(hostname)"
WORKDIR="/tmp/build"
export BUILD_NCPUS="${BUILD_NCPUS:-1}"
if [ "${BUILD_NCPUS}" -gt 1 ] && [ -z "${MAKEFLAGS:-}" ]; then
  export MAKEFLAGS="-j${BUILD_NCPUS}"
fi

mkdir -p "${TARDIR}" "${TEMP_LIBRARY}" "${SHARED_LIBRARY}" "${STAGEDIR}" "${WORKDIR}"

# Publish a package into the shared library atomically: copy to a staging
# dir, then rename into place. First published copy wins.
publish_pkg() {
  local name="$1"
  local dest="${SHARED_LIBRARY}/${name}"
  local stage="${STAGEDIR}/library-${name}-${STAGE_TAG}"
  if [ -e "${dest}" ]; then
    echo "Skipping ${name}: already in shared library"
    return 0
  fi
  rm -rf "${stage}"
  cp -r "${TEMP_LIBRARY}/${name}" "${stage}"
  # rename(2) refuses to replace a non-empty directory, so losing a race
  # with another publisher fails here instead of overwriting.
  if mv -T "${stage}" "${dest}"; then
    echo "Published ${name}"
  elif [ -d "${dest}" ]; then
    echo "Skipping ${name}: published concurrently by another build"
    rm -rf "${stage}" || true
  else
    echo "Error: failed to publish ${name} to shared library" >&2
    rm -rf "${stage}" || true
    return 1
  fi
}

ls -1 "${TEMP_LIBRARY}" > /tmp/initial_libs.txt

# Install with the container-local library first (new installs land there)
# and the shared library second (dependencies built earlier in the cycle).
cd "${WORKDIR}"
time Rscript -e '
  Sys.setenv(BIOCONDUCTOR_USE_CONTAINER_REPOSITORY = FALSE)
  pkg <- Sys.getenv("PKG")
  tmp <- Sys.getenv("TEMP_LIBRARY")
  .libPaths(c(tmp, Sys.getenv("SHARED_LIBRARY"), .libPaths()))
  options(Ncpus = as.integer(Sys.getenv("BUILD_NCPUS", "1")))
  BiocManager::install(
    pkg, INSTALL_opts = "--build", update = TRUE, quiet = FALSE,
    dependencies = TRUE, force = TRUE, keep_outputs = TRUE
  )
  ok <- pkg %in% rownames(installed.packages(lib.loc = tmp))
  q(status = if (ok) 0L else 1L)
' 2>&1

# Publish newly installed packages to the shared library.
cd "${TEMP_LIBRARY}"
ls -1 > /tmp/final_libs.txt
comm -13 /tmp/initial_libs.txt /tmp/final_libs.txt | while read -r pkg; do
  if [ -d "${pkg}" ]; then
    publish_pkg "${pkg}"
  fi
done

# Publish build artifacts: stage, then rename.
cd "${WORKDIR}"
tarballs=(*.tar.gz)
echo "Tarballs detected: ${tarballs[*]:-none}"
for tarball in "${tarballs[@]}"; do
  cp "${tarball}" "${STAGEDIR}/${tarball}.${STAGE_TAG}"
  mv -f "${STAGEDIR}/${tarball}.${STAGE_TAG}" "${TARDIR}/${tarball}"
  rm -f "${tarball}"
done
echo "Build artifacts stored in ${TARDIR}"
