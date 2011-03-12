#!/bin/bash

# change to your checkout path
CHECKOUT="/home/willert/Devel/mist"

source $CHECKOUT/perl5/etc/mist.mistrc
$CHECKOUT/script/mist.PL $@
