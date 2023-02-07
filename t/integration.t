#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Deep;

eval 'require AnyEvent' or do {
    plan skip_all => "No AnyEvent: $@";
};

my $URI = $ENV{'MDXS_TEST_MONGODB_URI'} or do {
    plan skip_all => "No MDXS_TEST_MONGODB_URI in env";
};

use MongoDB::XS;
use JSON::PP;

my $mdb = MongoDB::XS->new($URI);

my @tests = (
    {
        req => q<{ "hello": 1 }>,
        cb => sub {
            my ($resp, $err) = @_;

            cmp_deeply(
                $resp,
                superhashof( {
                    connectionId => superhashof({}),
                    hosts => superbagof(),
                } ),
                'expected response',
            ) or diag explain [$resp, $err];
        },
    },
);

for my $t_hr (@tests) {
    diag "Request: $t_hr->{'req'}";

    my $request_bson = MongoDB::XS::ejson2bson($t_hr->{'req'});

    my $resp;

    my $cv = AnyEvent::condvar();

    my $w = AnyEvent->io(
        fh => $mdb->fd(),
        poll => 'r',
        cb => sub {
            $mdb->process();
            $cv->send();
        },
    );

    $mdb->run_command(
        'admin',
        $request_bson,
        sub { $resp = shift },
    );

    $cv->recv();

    my $success = UNIVERSAL::isa($resp, 'MongoDB::XS::Error') ? undef : JSON::PP::decode_json( MongoDB::XS::bson2cejson($resp) );

    $t_hr->{'cb'}->($success, $resp);
}

done_testing;
