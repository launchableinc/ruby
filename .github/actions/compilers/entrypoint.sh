#! /bin/bash

# Copyright (c) 2024 Ruby developers.  All rights reserved.
#
# This file is  a part of the programming language  Ruby.  Permission is hereby
# granted, to  either redistribute and/or  modify this file, provided  that the
# conditions  mentioned in  the file  COPYING are  met.  Consult  the file  for
# details.

grouped()
{
    echo "::group::${@}"
    "${@}"
    echo "::endgroup::"
}

set -e
set -u
set -o pipefail

srcdir="/github/workspace/src"
builddir="$(mktemp -dt)"

export GITHUB_WORKFLOW='Compilations'
export CONFIGURE_TTY='never'
export RUBY_DEBUG='ci rgengc'
export RUBY_TESTOPTS='-q --color=always --tty=no'
export RUBY_DEBUG_COUNTER_DISABLE='1'
export GNUMAKEFLAGS="-j$((1 + $(nproc --all)))"

case "x${INPUT_ENABLE_SHARED}" in
x | xno | xfalse )
    enable_shared='--disable-shared'
    ;;
*)
    enable_shared='--enable-shared'
    ;;
esac

pushd ${builddir}

grouped git config --global --add safe.directory ${srcdir}

grouped ${srcdir}/configure        \
    -C                             \
    --with-gcc="${INPUT_WITH_GCC}" \
    --enable-debug-env             \
    --disable-install-doc          \
    --with-ext=-test-/cxxanyargs,+ \
    ${enable_shared}               \
    ${INPUT_APPEND_CONFIGURE}      \
    CFLAGS="${INPUT_CFLAGS}"       \
    CXXFLAGS="${INPUT_CXXFLAGS}"   \
    optflags="${INPUT_OPTFLAGS}"   \
    cppflags="${INPUT_CPPFLAGS}"   \
    debugflags='-ggdb3' # -g0 disables backtraces when SEGV.  Do not set that.

popd

if [[ -n "${INPUT_STATIC_EXTS}" ]]; then
    echo "::group::ext/Setup"
    set -x
    mkdir ${builddir}/ext
    (
        for ext in ${INPUT_STATIC_EXTS}; do
            echo "${ext}"
        done
    ) >> ${builddir}/ext/Setup
    set +x
    echo "::endgroup::"
fi

ruby_test_opts=''
tests=''

# Launchable
setup_launchable() {
    pushd ${srcdir}
    # Launchable creates .launchable file in the current directory, but cannot a file to ${srcdir} directory.
    # As a workaround, we set LAUNCHABLE_SESSION_DIR to ${builddir}.
    export LAUNCHABLE_SESSION_DIR=${builddir}
    local github_ref="${GITHUB_REF//\//_}"
    boot_report_path='launchable_bootstraptest.json'
    test_report_path='launchable_test_all.json'
    ruby_test_opts+=--launchable-test-reports="${boot_report_path}"
    tests+=--launchable-test-reports="${test_report_path}"
    grouped launchable record build --name "${github_ref}"_"${GITHUB_PR_HEAD_SHA}" || true
    trap launchable_record_test EXIT
}
launchable_record_test() {
    pushd "${builddir}"
    grouped launchable record tests --flavor test_task=test --test-suite bootstraptest raw "${boot_report_path}" || true
    if [ "$INPUT_CHECK" = "true" ]; then
        grouped launchable record tests --flavor test_task=test-all --test-suite test-all raw "${test_report_path}" || true
    fi
}
if [ "$LAUNCHABLE_ENABLED" = "true" ]; then
    setup_launchable
fi

pushd ${builddir}

grouped make showflags
grouped make all
grouped make test RUBY_TESTOPTS="${ruby_test_opts}"

[[ -z "${INPUT_CHECK}" ]] && exit 0

if [ "$INPUT_CHECK" = "true" ]; then
  tests+=" -- ruby -ext-"
else
  tests+=" -- $INPUT_CHECK"
fi

# grouped make install
grouped make test-all TESTS="$tests" || true
