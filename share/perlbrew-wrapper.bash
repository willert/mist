#!/bin/bash

if [ "x$PERLBREW_ROOT" == "x" ] ; then
		echo '$PERLBREW_ROOT not set';
		exit 1;
fi

if [ "x$MIST_APP_ROOT" == "x" ] ; then
		echo '$MIST_APP_ROOT not set';
		exit 1;
fi

if [ "x$MIST_PERLBREW_VERSION" == "x" ] ; then
		echo '$MIST_PERLBREW_VERSION not set';
		exit 1;
fi

source "$PERLBREW_ROOT/etc/bashrc"

MIST_ROOT="$MIST_APP_ROOT";
PERLBREW_OPTS="exec --quiet --with $MIST_PERLBREW_VERSION"

ARCH_NAME=`perlbrew $PERLBREW_OPTS perl -MConfig -e "print join( q{-}, q{perl}, \\\$Config{version}, \\\$Config{archname})"`
LOCAL_LIB="$MIST_ROOT/perl5/$ARCH_NAME"

export PATH="$LOCAL_LIB/bin:$LOCAL_LIB/sbin:$PATH"
export PATH="$MIST_ROOT/bin:$MIST_ROOT/sbin:$MIST_ROOT/script:$PATH"
export PERL5LIB="$MIST_ROOT/lib:$PERL5LIB"

eval `perlbrew $PERLBREW_OPTS perl -Mlocal::lib=$LOCAL_LIB`

perlbrew $PERLBREW_OPTS "$@"
