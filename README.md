### OVERVIEW

_mist_ is intended to help with the quasi-deployment of uninstalled
(or uninstallable) Perl applications. The most common applications for
this are [Catalyst][cat] applications, but it might prove useful in other
scenarios, too.

_mist_ works with [Dist::Zilla][dzil] and [cpanm] to create and maintain a
stable CPAN mirror in your project path that only includes the
needed CPAN or DarkPAN distributions.

The benefits of this approach are:

1. You always have a stable set of known-good modules available.

2. These modules can easily be installed in a _local::lib_ container
   and won't interfere with any other applications on this machine
	 or the system perl installation.

3. _mist_ creates a self-contained executable based on [cpanm] so
   no system-wide installation whatsoever (not even _local::lib_)
   is required on target machines.

4. Your applications dependencies can easily be put under version
	 control with all the benefits that brings.

_mist_ is in the earliest stages of development so any input is more
than welcome.

### INSTALLATION

_mist_ is completely self-contained and only needs an available perlbrew
environment. Inside _mist_ call:

`./mpan-install`

BE PATIENT, it takes some time!

[dzil]: http://dzil.org/ "Dist::Zilla homepage"
[cpanm]: http://xrl.us/cpanm "Download App::cpanminus"
[cat]: http://www.catalystframework.org/ "Catalyst Framework"
