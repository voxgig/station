package Voxgig::Station::Events;

# The solo event surface (design station.md 6): a bounded ring buffer plus
# a live tap with serialized callbacks. Events never fail an operation;
# overflow drops oldest and the drop count is visible in status(). Perl is
# a synchronous single-threaded runtime, so no locking rides here - the
# design's per-execution-model delivery semantics (6) make the inline,
# bounded path the correct one for this target.
#
# A port of typescript/src/events.ts, which is canonical.

use strict;
use warnings;

package Voxgig::Station::EventBuffer;

sub new {
    my ( $class, $max ) = @_;
    return bless {
        ring  => [],
        max   => ( defined $max ? $max : 1000 ),
        drops => 0,
        taps  => [],
    }, $class;
}

sub emit {
    my ( $self, $ev ) = @_;
    push @{ $self->{ring} }, $ev;
    if ( scalar( @{ $self->{ring} } ) > $self->{max} ) {
        shift @{ $self->{ring} };
        $self->{drops}++;
    }

    # Serialized, and a dying tap must not fail the operation that
    # emitted the event.
    for my $fn ( @{ $self->{taps} } ) {
        eval { $fn->($ev); 1 };
    }
    return;
}

sub events {
    my ($self) = @_;
    return [ @{ $self->{ring} } ];
}

# Subscribe; returns an unsubscribe coderef.
sub tap {
    my ( $self, $fn ) = @_;
    push @{ $self->{taps} }, $fn;
    return sub {
        $self->{taps} = [ grep { $_ != $fn } @{ $self->{taps} } ];
        return;
    };
}

sub status {
    my ($self) = @_;
    return {
        buffered => scalar( @{ $self->{ring} } ),
        dropped  => $self->{drops},
    };
}

1;
