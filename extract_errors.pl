#!/usr/bin/perl

use strict;
use warnings;
use autodie;

use File::Find;
use File::Path;
use File::Spec;
use Data::Dumper;
use Cwd;

use ExtUtils::PkgConfig;

my $PC_MODULE = 'libmongoc-1.0';

$Data::Dumper::Terse = 1;

my ($client_domain_hr, $client_code_hr) = _extract_errors();

my $client_domain_perl = Dumper($client_domain_hr);
my $client_code_perl   = Dumper($client_code_hr);

#----------------------------------------------------------------------

my $errdir = File::Spec->catdir('lib', 'MongoDB', 'XS', 'Error');
CORE::mkdir($errdir) or do {
    die "mkdir($errdir): $!" if !$!{'EEXIST'};
};

open my $hfh, '>', File::Spec->catfile('lib', 'MongoDB', 'XS', 'Error', 'ClientCodes.pm');

print {$hfh} <<"END";
package MongoDB::XS::Error::ClientCodes;

# This file is auto-generated from your installed MongoC headers
# and the latest official MongoDB server source code.

use strict;
use warnings;

our \%DOMAIN_TEXT = ( $client_domain_perl );
our \%CODE_TEXT = ( $client_code_perl );

1;
END

#----------------------------------------------------------------------

sub _extract_errors {
    my ($header_dir, $header_name) = _find_mongoc_err_header_or_die();

    my $path = File::Spec->catfile( $header_dir, $header_name );

    # hacky slurp:
    my $header_content = do { local ( @ARGV, $/ ) = $path; <> };

    return _extract_header_codes($header_content);
}

sub _extract_header_codes {
    my ($header_src) = @_;

    open my $rfh, '<', \$header_src or die $!;

    my $in_enum = 0;
    my $last_enum_value = -1;
    my @cur_enum_kv;
    my %enums;
    while (my $line = <$rfh>) {
        if ($in_enum) {
            if ($line =~ m<MONGOC_ERROR_([a-zA-Z0-9_]+)(?:\s*=\s*([0-9]+))?>) {
                my $value = $2 // (1 + $last_enum_value);
                $last_enum_value = $value;
                push @cur_enum_kv, $value, lc($1);
            }
            elsif ($line =~ m<\}\s*([a-zA-Z0-9_]+)>) {
                print "Finished enum: $1\n";
                $in_enum = 0;
                $enums{lc $1} = { @cur_enum_kv };
                @cur_enum_kv = ();
            }
        }
        elsif ($line =~ m<enum\s*\{>) {
            $in_enum = 1;
        }
    }

    return @enums{'mongoc_error_domain_t', 'mongoc_error_code_t'};
}

sub _find_mongoc_err_header_or_die {
    my $filename = 'mongoc-error.h';

    my @i = split m<\s+>, ExtUtils::PkgConfig->cflags_only_I($PC_MODULE);

    # Trim off leading -I, and reject anything that lacks it.
    @i = map { s<\A-I><> ? $_ : () } @i;

    print "Looking for $filename …\n";

    my $header_dir;

    my $cwd = Cwd::cwd();

    eval {
        File::Find::find(
            sub {
                if ($_ eq $filename) {
                    die "Found again?? $File::Find::name\n" if $header_dir;

                    print "Found it: $File::Find::name\n";
                    $header_dir = $File::Find::dir;

                    # File::Find leaves us no other way to stop iterating:
                    die 'zzzzzzzzzzzzz';
                }
            },
            @i,
        );
    };

    chdir $cwd or warn "chdir($cwd): $!";

    die if $@ !~ m<zzzzzzz>;

    if (!$header_dir) {
        die "Couldn’t find $filename!\n";
    }

    return $header_dir, $filename;
}
