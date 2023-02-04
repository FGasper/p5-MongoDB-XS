#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use MongoDB::XS;

ok( MongoDB::XS::mongoc_version_string(), 'version_string()' );

done_testing;

1;
