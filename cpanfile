requires "App::Cmd";
requires "Capture::Tiny";
requires "CPAN::PackageDetails";
requires "CPAN::ParseDistribution";
requires "Digest::MD5";
requires "File::Find::Upwards";
requires "File::HomeDir";
requires "File::Share";
requires "Module::Path";
requires "Path::Class";
requires "List::MoreUtils";
requires "Module::CPANfile" => "1.0002";
requires "Moose";
requires 'Devel::CheckBin';
requires 'Devel::CheckLib';
requires 'Devel::CheckCompiler';
requires 'Probe::Perl';

requires "App::cpanminus" => "1.7";
requires 'Minilla' => '0.11.0';

on 'configure' => sub {
  requires "ExtUtils::MakeMaker" => "6.30";
};
