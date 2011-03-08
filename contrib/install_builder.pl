#!/usr/bin/perl

use File::Which;
use Path::Class qw/dir/;
use Cwd;


my $cpanm = which( 'cpanm' );

open my $in,  "<", "$cpanm" or die $!;
open my $out, ">", "mist-install.tmp" or die $!;

print STDERR "Generating mist-installer\n";

while (<$in>) {
    print $out $_;
    last if /# END OF FATPACK CODE\s*$/;
}

my @prereqs = qx{ dzil listdeps };
chomp for @prereqs;

my @args = (
  'perl5',
  dir( getcwd(), 'dists' ),
  sprintf( qq{'%s'}, join qq{',\n    '}, @prereqs ),
);

printf $out <<'INSTALLER', @args;
unless (caller) {
  my $app = App::cpanminus::script->new;
  $app->parse_options(
    '--local-lib-contained=%s',
    '--mirror=file//%s',
    %s
  );
  $app->doit or exit(1);
}
INSTALLER

close $out;

unlink "mist-install";
rename "mist-install.tmp", "mist-install";
chmod 0755, "mist-install";

END { unlink "mist-install.tmp" }
