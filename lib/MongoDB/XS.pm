package MongoDB::XS;

use strict;
use warnings;

our $VERSION = '0.01_01';

=encoding utf-8

=head1 NAME

MongoDB::XS - L<MongoDB|https://mongodb.com> in Perl via C/XS.

=head1 SYNOPSIS

    use MongoDB::XS;

    # This sample code uses AnyEvent for demonstration only;
    # any event interface will work.
    use AnyEvent;

    my $mdb = MongoDB::XS->new("mongodb://127.0.0.1");

    my $cv = AE::cv();

    # When the fd is readable there is at least one result pending.
    my $w = AE::io( $mdb->fd(), 0, sub {
        $mdb->process();
        $cv->send();
    } );

    my $request_bson = MongoDB::XS::ejson2bson('{"hello": 1}');

    $mdb->run_command(
        'admin',
        $request_bson,
        sub ($resp) {
            if ($resp isa Mongo::DB::Error) {
                warn $resp;
            }
            else {
                # Success! $resp is a BSON string.
                # Parse it, and be on your way.
            }
        },
    );

    $cv->recv();

=head1 DESCRIPTION

This library provides MongoDB support in Perl
via an XS binding to MongoDB’s official C driver,
L<MongoC|https://mongoc.org>.

This is a research project, B<NOT> an official MongoDB driver.

=head1 DESIGN

This module avoids blocking Perl.
Toward that end, each instance runs “behind” Perl in a separate POSIX
thread; a pollable file descriptor facilitates event loop integration.

There is no attempt here to replicate the extensive interfaces found
in official MongoDB drivers. Instead this module provides a
minimal interface that should nevertheless expose most useful MongoDB
client functionality, while also requiring minimal maintenance.

For example, to use a
L<change stream|https://www.mongodb.com/docs/manual/changeStreams/>,
run the
L<aggregate|https://www.mongodb.com/docs/manual/reference/command/aggregate/>
command with a
L<$changeStream|https://www.mongodb.com/docs/manual/reference/operator/aggregation/changeStream/>. This will return a cursor, which you can give to
L<getMore|https://www.mongodb.com/docs/manual/reference/command/getMore/>
to receive successive pieces of the change stream.

Also see F</examples> in the distribution.

=head1 BSON

Several interfaces here expect and return raw L<BSON|https://bsonspec.org>
(MongoDB’s binary JSON variant).

How you create & parse the BSON is up to you.
CPAN offers L<multiple BSON modules|https://metacpan.org/search?q=bson>;
alternatively, you can use L<JSON::PP> or some other JSON module
with this module’s BSON/JSON conversion functions (see below).

=head1 STATUS

This module is experimental; its interface is subject to change.
It’s been stable for the author as an alternative to
C<mongosh>, but YMMV.

=head1 NOTES

This library never calls
L<mongoc_cleanup()|http://mongoc.org/libmongoc/current/mongoc_cleanup.html>.

=head1 SEE ALSO

MongoDB’s L<now-discontinued official Perl driver|MongoDB> is the
obvious point of reference.

=cut

#----------------------------------------------------------------------

use MongoDB::XS::Error ();

use XSLoader;
XSLoader::load( __PACKAGE__, $VERSION );

#----------------------------------------------------------------------

=head1 GENERAL-USE METHODS

=head2 $obj = I<CLASS>->new( $URI )

Instantiates I<CLASS> with the given $URI.

NB: This may block briefly for DNS lookups.

=head2 $obj = I<OBJ>->run_command( $REQUEST_BSON, $CALLBACK )

Sends a request (encoded as BSON) to MongoDB.
(See
L<mongoc_client_command_simple|http://mongoc.org/libmongoc/current/mongoc_client_command_simple.html> for details.)

The $CALLBACK receives either:

=over

=item * A raw BSON string (to indicate success).

=item * A L<MongoDB::XS::Error> object.

=back

Exceptions that escape the callback are trapped and reported
as warnings.

=head2 $level = I<OBJ>->get_read_concern()

Returns a string that represents I<OBJ>’s active read concern,
or undef if there is none.

The string should match the value of one of the read-concern
constants mentioned below.

=head2 $obj = I<OBJ>->set_read_concern( $LEVEL )

Sets the client’s read concern. $LEVEL should be one of the
read-concern constants mentioned below.

It returns I<OBJ>.

=head2 $hr = I<OBJ>->get_write_concern()

Returns a reference to a hash that represents I<OBJ>’s active
write concern. The hash contents are C<w>, C<j>, and C<wtimeout>;
see L<MongoDB’s documentation|https://www.mongodb.com/docs/manual/reference/write-concern/> for details of what these mean.

(Undef values indicate that no value has been set, so the default
is active.)

=head2 $obj = I<OBJ>->set_write_concern( \%WC )

C<get_write_concern()>’s complement. It expects the same hash
reference. Individual values can be omitted (or left undef) to
indicate a default value.

For example, the following:

    {
        w        => 1,
        j        => undef,
        wtimeout => 7,
    }

… indicates the default value for C<j> but explicit values
for C<w> and C<wtimeout>.

This method returns I<OBJ>.

=head1 CONSTANTS

=over

=item * READ_CONCERN_LOCAL, READ_CONCERN_MAJORITY,
READ_CONCERN_LINEARIZABLE, READ_CONCERN_AVAILABLE,
and READ_CONCERN_SNAPSHOT

=back

=head1 EVENT LOOP INTEGRATION METHODS

=head2 I<OBJ>->process()

Reads any queued request results and calls their associated
callbacks.

=cut

=head2 $fd = I<OBJ>->fd()

Returns the OS file descriptor that, when readable, indicates
that at least one result is ready for C<process()>ing.

B<NOTE:> Some Perl event libraries only interact with Perl filehandles.
For these libraries you can do:

    use POSIX ();

    my $fd_dup = POSIX::dup($mdb->fd()) or die "dup: $!";

    open my $mdb_fh, '+>&', $fd_dup or die "open(dup): $!";

(The C<dup()> ensures that, when Perl closes $mdb_fh, it won’t affect
mongoc.)

=head1 STATIC FUNCTIONS

=head2 $str = mongoc_version_string()

Returns MongoC’s version as a string.

=head2 $json = bson2cejson( $BSON )

Converts BSON to
L<Canonical Extended JSON|https://github.com/mongodb/specifications/blob/master/source/extended-json.rst>.

=head2 $json = bson2rejson( $BSON )

Converts BSON to
L<Relaxed Extended JSON|https://github.com/mongodb/specifications/blob/master/source/extended-json.rst>.

=head2 $bson = ejson2bson( $EXT_JSON )

Converts Extended JSON (either variant??) to a raw BSON string.

=cut

1;

=head1 LICENSE & COPYRIGHT

Copyright 2023 by Gasper Software Consulting. All rights reserved.

This library is licensed under the same license as Perl itself.
See L<perlartistic>.
