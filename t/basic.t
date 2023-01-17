#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Fatal;

use MongoDB::XS;

my $obj = MongoDB::XS->new("mongodb://127.0.0.1/?appname=pool-example");

isa_ok($obj, 'MongoDB::XS', 'new() return');

like(
	exception { MongoDB::XS->new("abcdefg") },
	qr<abcdefg>,
	'new() rejects invalid URI',
);

done_testing;

1;
