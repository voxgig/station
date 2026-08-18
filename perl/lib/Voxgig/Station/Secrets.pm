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
our @EXPORT_OK = qw(placeholder_for);

sub placeholder_for {
    my ($slug) = @_;
    return '[station:' . ( defined $slug ? $slug : '' ) . ']';
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
    my ( $self, $slug, $value ) = @_;
    $self->{overrides}{$slug} = $value;
    push @{ $self->{held} }, $value;
    return;
}

# Resolve the value for a plugin's secret name. Misses and store errors
# keep sekreto's distinction (design station.md 5.2): a miss is
# station_secret_no_value, a store that could not answer is
# station_secret_error with sekreto's message intact - and never a retry
# against a weaker store (sekreto owns the chain).
sub value {
    my ( $self, $slug, $name ) = @_;

    my $override = $self->{overrides}{$slug};
    return $override if defined $override;

    my $cached = $self->{cache}{$slug};
    return $cached if defined $cached;

    my $value = eval { $self->{sekreto}->get($name) };
    if ( my $err = $@ ) {
        my $msg = "$err";
        if ( Scalar::Util::blessed($err)
            && $err->isa('Voxgig::Sekreto::SekretoError')
            && 0 <= index( $msg, 'unknown secret' ) ) {
            Voxgig::Station::Error::fail( 'station_secret_no_value',
                'no store had "' . $name . '" for plugin "' . $slug . '"' );
        }
        Voxgig::Station::Error::fail( 'station_secret_error', $msg );
    }

    $self->{cache}{$slug} = $value;
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
