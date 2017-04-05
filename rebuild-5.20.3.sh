#!/bin/bash

# CPANM_OPTS="--reinstall --notest";
# CPANM_OPTS="--notest";
CPANM_OPTS="--reinstall";

rm -Rf perl5 mpan-dist

source /opt/perl5/etc/bashrc
perlbrew switch 5.20.3

cpanm --save-dists mpan-dist -L perl5/ $CPANM_OPTS --installdeps .
cpanm --save-dists mpan-dist -L perl5/ $CPANM_OPTS \
			List::Util IPC::Run3 \
			Test::Fatal Test::Exception \
			Digest::MD5 Getopt::Long \
			Test::Tester \
			
# rebuild mist indizes
MIST_REBUILD_IN_PROGRESS=1 perl -Mlocal::lib=perl5 ./script/mist index
MIST_REBUILD_IN_PROGRESS=1 perl -Mlocal::lib=perl5 ./script/mist compile

./mpan-install $CPANM_OPTS
