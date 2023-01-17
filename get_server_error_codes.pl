#!/usr/bin/perl

use strict;
use warnings;
use autodie;

#----------------------------------------------------------------------
# This script reaches out to the public Internet. It runs as part of
# publishing new versions of MongoDB::XS.
#----------------------------------------------------------------------

use File::Find;
use File::Spec;
use Data::Dumper;

use File::Which;
use HTTP::Tiny;
use File::Temp;
use JSON::PP;

$Data::Dumper::Terse = 1;

#----------------------------------------------------------------------

open my $hfh, '>', File::Spec->catfile('lib', 'MongoDB', 'XS', 'Error', 'ServerCodes.pm');

print {$hfh} <<"END";
package MongoDB::XS::Error::ServerCodes;

# This file is auto-generated from the latest official MongoDB
# server source code.

use strict;
use warnings;

our \%CODE_TEXT = ( $server_code_perl );

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

    File::Find::find(
        sub {
            if ($_ eq $filename) {
                die "Found again?? $File::Find::name\n" if $header_dir;

                print "Found it: $File::Find::name\n";
                $header_dir = $File::Find::dir;
            }
        },
        @i,
    );

    if (!$header_dir) {
        die "Couldn’t find $filename!\n";
    }

    return $header_dir, $filename;
}


#----------------------------------------------------------------------
# Getting server domain & error codes:

sub _get_server_error_codes {
    my $URL = 'https://raw.githubusercontent.com/mongodb/mongo/master/src/mongo/base/error_codes.yml';

    my %err_code;

    if (my $yq = File::Which::which('yq')) {
        my $yaml_resp = HTTP::Tiny->new()->get($URL);
        if (!$yaml_resp->{'success'}) {
            require Data::Dumper;
            die Data::Dumper::Dumper($yaml_resp);
        }

        my ($tfh, $temppath) = File::Temp::tempfile( CLEANUP => 1 );

        syswrite $tfh, $yaml_resp->{'content'};
        sysseek $tfh, 0, 0;

        my $json = do {
            open my $jfh, '-|', $yq, $temppath, '--output-format', 'json' or die $!;
            local $/; <$jfh>;
        };

        my $data = JSON::PP::decode_json($json);

        for my $ec_hr (@{ $data->{'error_codes'} }) {
            $err_code{ $ec_hr->{'code'} } = $ec_hr->{'name'};
        }
    }
    else {
        warn "Didn’t find yq; can’t build server error codes.\n";
    }

    return \%err_code;
}
