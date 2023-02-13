#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::FailWarnings;
use Test::Deep;

use MongoDB::XS;

alarm 60;

eval 'require AnyEvent' or do {
    plan skip_all => "No AnyEvent: $@";
};

my $mdb = MongoDB::XS->new('mongodb://localhost');

my $cv;

my $w = AnyEvent->io(
    fh => $mdb->fd(),
    poll => 'r',
    cb => sub {
        $mdb->process();
        warn if !eval { $cv->send(); 1 };
    },
);

#----------------------------------------------------------------------

my @tests = (
    sub {
        my @rc;
        $mdb->get_read_concern(sub { push @rc, shift });

        is_deeply(\@rc, [], 'read concern unset at first');

        $cv->recv();

        is_deeply( \@rc, [undef], 'default read concern' );
    },
    sub {
        my $called;
        $mdb->set_read_concern(MongoDB::XS::READ_CONCERN_MAJORITY, sub {
            $called = 1;
        });

        $cv->recv();
        ok $called, 'set_read_concern() callback is called';
    },
    sub {
        my @c;
        $mdb->get_read_concern(sub { push @c, shift });
        $cv->recv();

        is_deeply( \@c, [
            MongoDB::XS::READ_CONCERN_MAJORITY,
        ], 'set_read_concern() should work' );
    },

    # --------------------------------------------------

    sub {
        my @c;
        $mdb->get_write_concern(sub { push @c, shift });

        is_deeply(\@c, [], 'write concern unset at first');

        $cv->recv();

        is_deeply(
            \@c,
            [ { j => undef, w => undef, wtimeout => 0 } ],
            'default write concern',
        ) or diag explain \@c;
    },

    sub {
        my $called;
        $mdb->set_write_concern( { w => 'majority' }, sub { $called = 1 } );

        $cv->recv();

        ok $called, 'callback called';
    },

    sub {
        my @c;
        $mdb->get_write_concern(sub { push @c, shift });

        $cv->recv();

        is_deeply(
            \@c,
            [
                {
                    w => 'majority',
                    j => undef,
                    wtimeout => 0,
                },
            ],
            'set_write_concern() with only w=majority',
        ) or diag explain \@c;
    },

    sub {
        my $called;
        $mdb->set_write_concern(
            {
                w => 2,
                j => 0,
                wtimeout => 67,
            },
        );

        $cv->recv();
    },

    sub {
        my $c;
        $mdb->get_write_concern(sub { $c = shift });

        $cv->recv();

        is_deeply(
            $c,
            {
                w => 2,
                j => !!0,
                wtimeout => 67,
            },
            'set_write_concern() with other args',
        ) or diag explain $c;
    },

    sub {
        my $called;
        $mdb->set_write_concern( { j => 1 } );

        $cv->recv();
    },

    sub {
        my $c;
        $mdb->get_write_concern(sub { $c = shift });

        $cv->recv();

        is_deeply(
            $c,
            {
                w => undef,
                j => !0,
                wtimeout => 0,
            },
            'set_write_concern() with only j=1',
        ) or diag explain $c;
    },
);

for my $t (@tests) {
    $cv = AnyEvent->condvar();
    $t->();
}

done_testing;
