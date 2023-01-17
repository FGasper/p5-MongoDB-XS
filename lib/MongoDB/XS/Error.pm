package MongoDB::XS::Error;

use strict;
use warnings;

=encoding utf-8

=head1 NAME

MongoDB::XS::Error - L<MongoDB|https://mongodb.com> errors

=head1 DESCRIPTION

This class represents an error response from libbson’s
L<bson_error_t|https://mongoc.org/libbson/current/bson_error_t.html>,
which L<libmongoc|https://mongoc.org/> uses to indicate failure.

=head1 OVERLOADING

Instances of this class stringify to a human-friendly representation
of the error string. Domain and code are stringified (if possible).

=head1 FUNCTIONS

=head2 $str = domain2str( $NUMBER )

Converts an error domain number to a human-readable string.
Returns undef if no string is found.

=head2 $str = code2str_client( $NUMBER )

Like C<domain2str()> but for client error codes.

=head2 $str = code2str_server( $NUMBER )

Like C<domain2str()> but for server error codes.

=cut

use MongoDB::XS::ErrorCodes;

use overload (
	q<""> => \&_stringify,
);

# cf. https://mongoc.org/libmongoc/current/errors.html
our %CLIENT_CODE_IS_EXTERNAL = map { $_ => 1 } (
    'sasl',
    'client_side_encryption',
);

our %DOMAIN_MEANS_SERVER_CODE = map { $_ => 1 } (
    'server',
    'write_concern',
);

sub new {
    my ($class, $domain, $code, $msg) = @_;
    return bless [$domain, $code, $msg], $class;
}

sub domain2str {
    return $MongoDB::XS::ErrorCodes::DOMAIN_TEXT{ shift() };
}

sub code2str_client {
    return $MongoDB::XS::ErrorCodes::CLIENT_CODE_TEXT{ shift() };
}

sub code2str_server {
    return $MongoDB::XS::ErrorCodes::SERVER_CODE_TEXT{ shift() };
}

sub _stringify {
    my $self = shift;

    my $domain = $self->[0];
    $domain = domain2str($domain) || $domain;

    my $code = $self->[1];

    if ($DOMAIN_MEANS_SERVER_CODE{$domain}) {
        $code = code2str_server($code) || $code;
    }
    elsif (!$CLIENT_CODE_IS_EXTERNAL{$domain}) {
        $code = code2str_client($code) || $code;
    }

    return "MongoDB $domain\::$code: $self->[2]";
}

1;
