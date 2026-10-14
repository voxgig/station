package Voxgig::Station::Secrets;

# The secret broker (design station.md 5): sekreto resolves, station
# places. The broker holds resolved values privately - they never enter
# options, events, or captures; the SDK sees only the placeholder.
#
# A port of typescript/src/secrets.ts, which is canonical. Voxgig::Sekreto
# is located and loaded by Voxgig::Station's bootstrap before this module
# is used (vendored side-by-side, @INC, SEKRETO_HOME, or a sibling
# checkout).

use strict;
use warnings;

use Scalar::Util qw(blessed);

use Voxgig::Station::Error ();

use Exporter 'import';
our @EXPORT_OK = qw(encode_query_value placeholder_for substitute);

# Keyed by INSTANCE (design station.md 7.2). Two live instances of one
# api must have distinct placeholders or the injection seam cannot tell
# which credential a header wants. For an untagged instance this IS the
# api slug, so the single-instance case is unchanged to the byte.
sub placeholder_for {
    my ($name) = @_;
    return '[station:' . ( defined $name ? $name : '' ) . ']';
}

# Every UTF-8 byte outside RFC 3986's unreserved set becomes upper-case
# %XX. A byte string, such as a value read from the environment, is
# already UTF-8.
sub encode_query_value {
    my ($value) = @_;
    my $bytes = defined $value ? "$value" : '';
    utf8::encode($bytes) if utf8::is_utf8($bytes);
    $bytes =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
    return $bytes;
}

sub _match_at {
    my ( $text, $at, $end, $placeholder ) = @_;
    my $i = $at;
    for my $ch ( split //, $placeholder ) {
        if ( $i < $end && substr( $text, $i, 1 ) eq $ch ) {
            $i++;
            next;
        }
        if (   $i + 3 <= $end
            && '%' eq substr( $text, $i, 1 )
            && substr( $text, $i + 1, 2 ) =~ /\A[0-9A-Fa-f]{2}\z/
            && hex( substr( $text, $i + 1, 2 ) ) == ord($ch) ) {
            $i += 3;
            next;
        }
        return -1;
    }
    return $i - $at;
}

# The placeholder becomes the value in header values and in the URL
# query, where an SDK percent-encodes it (any hex case) and the value is
# encoded in turn. The path and fragment are never touched; the headers
# are a copy.
sub substitute {
    my ( $url, $headers, $placeholder, $value ) = @_;
    my $out = { %{ ref($headers) eq 'HASH' ? $headers : {} } };
    return { url => $url, headers => $out } if '' eq $placeholder;

    for my $h ( keys %$out ) {
        my $v = $out->{$h};
        next unless defined $v && !ref $v && 0 <= index( $v, $placeholder );
        $out->{$h} = join( $value, split( /\Q$placeholder\E/, $v, -1 ) );
    }

    my $q = index( $url, '?' );
    return { url => $url, headers => $out } if -1 == $q;
    my $hash    = index( $url, '#', $q );
    my $end     = -1 == $hash ? length($url) : $hash;
    my $encoded = encode_query_value($value);
    my $query   = '';
    for ( my $i = $q + 1 ; $i < $end ; ) {
        my $n = _match_at( $url, $i, $end, $placeholder );
        if ( 0 < $n ) {
            $query .= $encoded;
            $i += $n;
        }
        else {
            $query .= substr( $url, $i, 1 );
            $i++;
        }
    }
    return {
        url     => substr( $url, 0, $q + 1 ) . $query . substr( $url, $end ),
        headers => $out,
    };
}

package Voxgig::Station::SecretBroker;

sub new {
    my ( $class, $providers ) = @_;
    return bless {
        sekreto => Voxgig::Sekreto->new( { providers => $providers } ),

        # Values hoisted by adopt() from a resident options apikey
        # (design station.md 3.1).
        overrides => {},
        cache     => {},

        # Every value this broker ever held, for the exact-value scrub.
        held => [],
    }, $class;
}

sub hoist {
    my ( $self, $name, $value ) = @_;
    $self->{overrides}{$name} = $value;
    push @{ $self->{held} }, $value;
    return;
}

# Resolve the value for an instance's secret name. Misses and store errors
# keep sekreto's distinction (design station.md 5.2): a miss is
# station_secret_no_value, a store that could not answer is
# station_secret_error with sekreto's message intact - and never a retry
# against a weaker store (sekreto owns the chain).
# OVERRIDES ARE KEYED BY INSTANCE; THE RESOLUTION CACHE IS KEYED BY
# SECRET NAME (design station.md 5.3). A hoisted credential belongs to
# the one instance it was resident in, but a resolved VALUE belongs to
# the name it was resolved for - so several instances sharing one
# api-level `secret` cost one lookup rather than one each, and every
# per-request client an auto-tagged create() produces shares the
# declared instance's entry instead of re-resolving.
#
# Keying the cache by instance instead is the defect this replaces: at
# 26 instances over 20 apis it turns one store round-trip into 26.
sub value {
    my ( $self, $instance, $name ) = @_;

    my $override = $self->{overrides}{$instance};
    return $override if defined $override;

    my $cached = $self->{cache}{$name};
    return $cached if defined $cached;

    my $value = eval { $self->{sekreto}->get($name) };
    if ( my $err = $@ ) {
        my $msg = "$err";
        if ( Scalar::Util::blessed($err)
            && $err->isa('Voxgig::Sekreto::SekretoError')
            && 0 <= index( $msg, 'unknown secret' ) ) {
            Voxgig::Station::Error::fail( 'station_secret_no_value',
                'no store had "' . $name . '" for plugin "' . $instance . '"' );
        }
        Voxgig::Station::Error::fail( 'station_secret_error', $msg );
    }

    $self->{cache}{$name} = $value;
    push @{ $self->{held} }, $value;
    return $value;
}

# Exact-value scrub, deliberately WITHOUT sekreto's four-character
# readability floor (design station.md 7 as revised): on boundaries where
# the promise is absolute, every held value is scrubbed whatever its
# length. sekreto's own redactall runs too, covering values resolved by
# the underlying instance that station never held.
sub scrub {
    my ( $self, $text ) = @_;
    my $out = $self->{sekreto}->redactall( defined $text ? "$text" : '' );
    for my $value ( @{ $self->{held} } ) {
        next if !defined $value || '' eq $value;
        $out = join( '[redacted]', split( /\Q$value\E/, $out, -1 ) );
        my $encoded = Voxgig::Station::Secrets::encode_query_value($value);
        $out = join( '[redacted]', split( /\Q$encoded\E/, $out, -1 ) )
          if $encoded ne $value;
    }
    return $out;
}

# Drop caches so the next resolve asks the stores again (rotation support
# rides on sekreto's refresh, design station.md 5.3).
sub refresh {
    my ($self) = @_;
    $self->{cache} = {};
    $self->{sekreto}->refresh if $self->{sekreto}->can('refresh');
    return;
}

1;
