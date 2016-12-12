#!/usr/bin/env bash

shopt -s nullglob

function remove_ngless_bin {
    # Ensure that the directory where ngless unpacks embedded binaries is removed (we want to test the embedded blobs)
    NGLDIR="$HOME/.local/share/ngless/bin"
    [ -d "$NGLDIR" ] && echo "Removing $NGLDIR to ensure embedded bins are used" && rm -rf "$NGLDIR"
}

# This script is located on the root of the repository
# where samtools and bwa are also compiled
REPO="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ "$0" == *-embedded.sh ]]; then
    echo ">>> Testing NGLess ( with embedded binaries ) <<<"
    MAKETARGET="ngless-embed"
    remove_ngless_bin
elif [[ "$0" == *-static.sh ]]; then
    echo ">>> Testing NGLess ( static build with embedded binaries ) <<<"
    MAKETARGET="static"
    remove_ngless_bin
else
    echo ">>> Testing NGLess ( regular build ) <<<"
    export NGLESS_SAMTOOLS_BIN=$REPO/samtools-1.3.1/samtools
    export NGLESS_BWA_BIN=$REPO/bwa-0.7.15/bwa
    MAKETARGET=""
fi

ok="yes"

make
if test $? -ne "0"; then
    echo "ERROR IN 'make'"
    ok=no
fi
# haskell unit tests
make check
if test $? -ne "0"; then
    echo "ERROR IN 'make check'"
    ok=no
fi

# Our test target (if not the default) is then also used for the subsequent tests
if [ "$MAKETARGET" != "" ]; then
    make $MAKETARGET
    if test $? -ne "0"; then
        echo "ERROR IN 'make $MAKETARGET'"
        ok=no
    fi
fi

ngless_bin=$(stack path --local-install-root)/bin/ngless
if ! test -x $ngless_bin ; then
    echo "Could not determine path for ngless (guessed $ngless_bin)"
    exit 1
fi

basedir=$REPO
for testdir in tests/*; do
    if test -d $testdir; then
        if test -f ${testdir}/TRAVIS_SKIP -a x$TRAVIS = xtrue; then
            echo "Skipping $testir on Travis"
            continue
        fi
        echo "Running $testdir"
        cd $testdir
        mkdir -p temp
        validate_arg=""
        if [[ $testdir == tests/error-validation-* ]] ; then
            validate_arg="-n"
        fi
        $ngless_bin --quiet -t temp $validate_arg *.ngl > output.stdout.txt 2>output.stderr.txt
        ngless_exit=$?
        if [[ $testdir == tests/error-* ]] ; then
            if test $ngless_exit -eq "0"; then
                echo "Expected error message in test"
                ok=no
            fi
        else
            if test $ngless_exit -ne "0"; then
                echo "Error exit in test"
                ok=no
            fi
        fi
        for f in expected.*; do
            out=output${f#expected}
            diff -u $f $out
            if test $? -ne "0"; then
               echo "ERROR in test $testdir: $out did not match $f"
               ok=no
            fi
        done
        if test -x ./check.sh; then
            ./check.sh
            if test $? -ne "0"; then
                echo "ERROR in test $testdir: ./check.sh failed"
                ok=no
            fi
        fi
        if test -x ./cleanup.sh; then
            ./cleanup.sh
        fi
        rm -rf temp
        rm -rf *.output_ngless
        rm -f output.*
        cd $basedir
    fi
done

if test $ok = "yes"; then
    echo "All done."
else
    echo "An error occurred."
    exit 1
fi
