# NAME

MongoDB::XS - [MongoDB](https://mongodb.com) in Perl via C/XS.

# SYNOPSIS

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

# DESCRIPTION

This library provides MongoDB support in Perl
via an XS binding to MongoDB’s official C driver,
[MongoC](https://mongoc.org).

This is a research project, **NOT** an official MongoDB driver.

# DESIGN

This module avoids blocking Perl.
Toward that end, each instance runs “behind” Perl in a separate POSIX
thread; a pollable file descriptor facilitates event loop integration.

There is no attempt here to replicate the extensive interfaces found
in official MongoDB drivers. Instead this module provides a minimal
interface that should nevertheless expose most useful MongoDB client
functionality.

For example, to use a
[change stream](https://www.mongodb.com/docs/manual/changeStreams/),
run the
[aggregate](https://www.mongodb.com/docs/manual/reference/command/aggregate/)
command with a
[$changeStream](https://www.mongodb.com/docs/manual/reference/operator/aggregation/changeStream/). This will return a cursor, which you can give to
[getMore](https://www.mongodb.com/docs/manual/reference/command/getMore/)
to receive successive pieces of the change stream.

Also see `/examples` in the distribution.

# BSON

Several interfaces here expect and return raw [BSON](https://bsonspec.org)
(MongoDB’s binary JSON variant).

How you create & parse the BSON is up to you.
CPAN offers [multiple BSON modules](https://metacpan.org/search?q=bson);
alternatively, you can use [JSON::PP](https://metacpan.org/pod/JSON%3A%3APP) or some other JSON module
with this module’s BSON⟷JSON conversion functions (see below).

# STATUS

This module is experimental; its interface is subject to change.
It’s been stable for the author as an alternative to
`mongosh`, but YMMV.

# NOTES

This library never calls
[mongoc\_cleanup()](http://mongoc.org/libmongoc/current/mongoc_cleanup.html).

# SEE ALSO

MongoDB’s [now-discontinued official Perl driver](https://metacpan.org/pod/MongoDB) is the
obvious point of reference.

# GENERAL-USE METHODS

## $obj = _CLASS_->new( $URI )

Instantiates _CLASS_ with the given $URI.

NB: This may block briefly for DNS lookups.

## $obj = _OBJ_->run\_command( $REQUEST\_BSON, $CALLBACK )

Sends a request (encoded as BSON) to MongoDB.
(See
[mongoc\_client\_command\_simple](http://mongoc.org/libmongoc/current/mongoc_client_command_simple.html) for details.)

The $CALLBACK receives either:

- A raw BSON string (to indicate success).
- A [MongoDB::XS::Error](https://metacpan.org/pod/MongoDB%3A%3AXS%3A%3AError) object.

Exceptions that escape the callback are trapped and reported
as warnings.

## $level = _OBJ_->get\_read\_concern()

Returns a string that represents _OBJ_’s active read concern,
or undef if there is none.

The string should match the value of one of the read-concern
constants mentioned below.

## $obj = _OBJ_->set\_read\_concern( $LEVEL )

Sets the client’s read concern. $LEVEL should be one of the
read-concern constants mentioned below.

It returns _OBJ_.

## $hr = _OBJ_->get\_write\_concern()

Returns a reference to a hash that represents _OBJ_’s active
write concern. The hash contents are `w`, `j`, and `wtimeout`;
see [MongoDB’s documentation](https://www.mongodb.com/docs/manual/reference/write-concern/) for details of what these mean.

(Undef values indicate that no value has been set, so the default
is active.)

## $obj = _OBJ_->set\_write\_concern( \\%WC )

`get_write_concern()`’s complement. It expects the same hash
reference. Individual values can be omitted (or left undef) to
indicate a default value.

For example, the following:

    {
        w        => 1,
        j        => undef,
        wtimeout => 7,
    }

… indicates the default value for `j` but explicit values
for `w` and `wtimeout`.

This method returns _OBJ_.

# EVENT LOOP INTEGRATION METHODS

## _OBJ_->process()

Reads any queued request results and calls their associated
callbacks.

## $fd = _OBJ_->fd()

Returns the OS file descriptor that, when readable, indicates
that at least one result is ready for `process()`ing.

**NOTE:** Some Perl event libraries only interact with Perl filehandles.
For these libraries you can do:

    use POSIX ();

    my $fd_dup = POSIX::dup($mdb->fd()) or die "dup: $!";

    open my $mdb_fh, '+>&', $fd_dup or die "open(dup): $!";

(The `dup()` ensures that, when Perl closes $mdb\_fh, it won’t affect
mongoc.)

# STATIC FUNCTIONS

## $str = mongoc\_version\_string()

Returns MongoC’s version as a string.

## $json = bson2cejson( $BSON )

Converts BSON to
[Canonical Extended JSON](https://github.com/mongodb/specifications/blob/master/source/extended-json.rst).

## $json = bson2rejson( $BSON )

Converts BSON to
[Relaxed Extended JSON](https://github.com/mongodb/specifications/blob/master/source/extended-json.rst).

## $bson = ejson2bson( $EXT\_JSON )

Converts Extended JSON (either variant??) to a raw BSON string.

# LICENSE & COPYRIGHT

Copyright 2023 by Gasper Software Consulting. All rights reserved.

This library is licensed under the same license as Perl itself.
See [perlartistic](https://metacpan.org/pod/perlartistic).
