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

is($obj->get_read_concern(), undef, 'get_read_concern() when default');

is(
    $obj->set_read_concern(MongoDB::XS::READ_CONCERN_MAJORITY),
    $obj,
    'set_read_concern() should return $self',
);

is(
    $obj->get_read_concern(),
    MongoDB::XS::READ_CONCERN_MAJORITY,
    'set_read_concern() should work',
);

is_deeply(
    $obj->get_write_concern(),
    {
        w => undef,
        j => undef,
        wtimeout => 0,
    },
    'default write concern',
);

is(
    $obj->set_write_concern( {
        w => 'majority',
    } ),
    $obj,
    'set_write_concern() returns $self',
);

is_deeply(
    $obj->get_write_concern(),
    {
        w => 'majority',
        j => undef,
        wtimeout => 0,
    },
    'set_write_concern() with only w=majority',
);

$obj->set_write_concern( {
    w => 2,
    j => 0,
    wtimeout => 67,
} );

is_deeply(
    $obj->get_write_concern(),
    {
        w => 2,
        j => !1,
        wtimeout => 67,
    },
    'set_write_concern() with other args',
);

$obj->set_write_concern( {
    j => 1,
} );

is_deeply(
    $obj->get_write_concern(),
    {
        w => undef,
        j => !0,
        wtimeout => 0,
    },
    'set_write_concern() with only j=1',
);

done_testing;

1;
