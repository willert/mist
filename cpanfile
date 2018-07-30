requires "local::lib" => '2.00';
requires "Getopt::Long" => '2.42';

requires "App::Cmd";
requires "App::cpanminus" => "1.7";

requires "Capture::Tiny";
requires "Digest::MD5";
requires "Module::Path";
requires "Sort::Key";

requires "Path::Class";
requires "File::Find::Upwards";
requires "File::HomeDir";
requires "File::Share";

requires 'Moo';
requires 'MooX::late';
requires 'MooX::HandlesVia';

requires 'CPAN::Meta' => '2.132830';
requires "CPAN::PackageDetails";
requires "CPAN::ParseDistribution";
requires "Module::CPANfile" => "1.0002";

requires 'Devel::CheckBin';
requires 'Devel::CheckLib';
requires 'Devel::CheckCompiler';
requires 'Probe::Perl';

requires 'Minilla' => '0.11.0';
requires 'Software::License';
requires 'Version::Next';
requires 'thanks';

on 'configure' => sub {
  requires "ExtUtils::MakeMaker" => "6.30";
};
