#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use MongoDB::XS;

ok( MongoDB::XS::version_string(), 'version_string()' );

done_testing;

1;
