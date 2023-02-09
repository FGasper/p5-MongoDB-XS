#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
#use Test::FailWarnings;
#use Test::Deep;

use MongoDB::XS;

alarm 60;

my $URI = $ENV{'MDXS_TEST_MONGODB_URI'} or do {
    plan skip_all => "No MDXS_TEST_MONGODB_URI in env";
};

my $req_bson = MongoDB::XS::ejson2bson('{"hello":1}');

{
    my $mdb = MongoDB::XS->new($URI);

    diag 'after new()';

    $mdb->run_command( admin => $req_bson, sub { die 'no' } );

    diag 'after run_command()';
}

ok 1, 'finished';

done_testing;
