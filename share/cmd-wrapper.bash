#!/bin/bash

# get the absolute path of the executable
SELF_PATH=$(cd -P -- "$(dirname -- "$0")" && pwd -P) && SELF_PATH=$SELF_PATH/$(basename -- "$0")

# resolve symlinks
while [ -h $SELF_PATH ]; do
    # 1) cd to directory of the symlink
    # 2) cd to the directory of where the symlink points
    # 3) get the pwd
    # 4) append the basename
    DIR=$(dirname -- "$SELF_PATH")
    SYM=$(readlink $SELF_PATH)
    SELF_PATH=$(cd $DIR && cd $(dirname -- "$SYM") && pwd)/$(basename -- "$SYM")
done

WRAPPER=$(dirname $SELF_PATH)

CALL_PATH="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/$(basename $0)"

if [ $SELF_PATH == $CALL_PATH ] ; then
  echo "$(basename $0): Must be called as a symlink named like the command to be run" >&2
  exit 1
fi

# try to upward-find mist directory
for UPDIR in . .. ../.. ../../.. ../../../.. ; do
  TEST="$WRAPPER/$UPDIR/mistfile";
  if [ -f $TEST ] ; then
      LOCAL_LIB=$( cd -P "$( dirname "$TEST" )" && pwd )
      BASE_DIR="$WRAPPER/$UPDIR"
      break
  fi
done

BASE_DIR=$( readlink -f -- "$BASE_DIR" )

#exit if we can't find any
if [ ! $LOCAL_LIB ] ; then
  echo "$0: No mistfile found. Abort!" >&2
  exit 1
fi

export LD_LIBRARY_PATH=$BASE_DIR/perl5/lib:$LD_LIBRARY_PATH

exec "$BASE_DIR/perl5/bin/mist-run" `basename $0` "$@"
