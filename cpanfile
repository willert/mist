requires "App::Cmd" => "0";
requires "App::cpanminus" => "1.7";
requires "CPAN::PackageDetails" => "0";
requires "CPAN::ParseDistribution" => "0";
requires "File::Find::Upwards" => "0";
requires "File::HomeDir" => "0";
requires "Module::Path" => "0";
requires "Path::Class" => "0";
requires "Module::CPANfile" => "1.0002";

on 'configure' => sub {
  requires "ExtUtils::MakeMaker" => "6.30";
};
