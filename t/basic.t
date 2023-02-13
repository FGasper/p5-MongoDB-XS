#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;

use MongoDB::XS;

alarm 60;

my $obj = MongoDB::XS->new("mongodb://127.0.0.1/?appname=pool-example");

isa_ok($obj, 'MongoDB::XS', 'new() return');

my $err = exception { MongoDB::XS->new("abcdefg") };
isa_ok(
	$err,
	q<MongoDB::XS::Error>,
	'new() rejects invalid URI',
) or diag explain $err;

done_testing;

1;
