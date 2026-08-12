requires "local::lib" => '2.00';
requires "Getopt::Long" => '2.42';
requires "Module::Install";

requires "App::Cmd";
requires "App::cpanminus" => "1.7";

requires "Capture::Tiny";
requires "Digest::MD5";
requires "Sort::Key";

requires "Path::Class";
requires "File::Find::Upwards";
requires "File::HomeDir";
requires "File::Share";

requires 'Moo';
requires 'MooX::late';
requires 'MooX::HandlesVia';

# `mist doctor` compares core module sets across perl versions, so it needs a
# Module::CoreList that knows perls newer than the one mist runs under. The floor
# is load-bearing rather than decorative: Module::CoreList is core, so a bare
# requires would be filtered out by skip-core-satisfied and the 2015 copy that
# ships with 5.20.3 - which stops at 5.23.2 - would be used instead.
requires 'Module::CoreList' => '5.20260720';

requires 'CPAN::Meta' => '2.132830';
requires "CPAN::PackageDetails";
requires "CPAN::ParseDistribution";
requires "Module::CPANfile" => "1.0002";

requires 'Devel::CheckBin';
requires 'Devel::CheckLib';
requires 'Devel::CheckCompiler';
requires 'Probe::Perl';

requires 'Minilla' => '3.1.2';
requires 'Software::License' => '0.102250';
requires 'Version::Next';
