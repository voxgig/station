package Voxgig::Station::Factory;

# The factory table (design station.md 6.2).
#
# A FACTORY IS A CONSTRUCTOR *PLUS* THE SDK'S STATIC CONFIG, not a bare
# coderef, and leaving the second half out is a hole.
#
# Station composes the ordered feature array FOR the constructor, so it
# needs the transport roles and the feature option schemas BEFORE
# construction - but the adapter builds and registers its descriptor
# DURING construction. Nothing would be known in time. The generated
# package emits its config as a module-level constant, though, so it
# exists as soon as the package is linked and long before any instance
# is built. Station NORMALIZES THE DESCRIPTOR AT PROVIDE TIME, and three
# things follow:
#
#  - the per-api descriptor cache is populated at REGISTRATION rather
#    than on first construction;
#  - check() can validate every instance's feature config WITHOUT
#    constructing anything;
#  - the adapter's registration during construction becomes a
#    RECONCILIATION - same descriptor, now bound to a live client -
#    rather than the first sighting.
#
# The table is PROCESS-GLOBAL because path 1 of 6.2 is module
# self-registration: a generated package registers itself when it is
# loaded, which happens once per process and not once per Station. Perl
# runs one interpreter per process here, so a file-scoped hash IS that
# global; no mutex rides it, for the same reason the event buffer takes
# no lock.
#
# A port of typescript/src/factory.ts, which is canonical.

use strict;
use warnings;

use Scalar::Util qw(refaddr);

use Voxgig::Station::Descriptor qw(normalize_descriptor);
use Voxgig::Station::Error ();

use Exporter 'import';
our @EXPORT_OK = qw(factory_for provide provided reset_factories);

my %TABLE;

# The same value, in the sense `===` means in the canonical: one
# reference, or one scalar.
sub _same {
    my ( $a, $b ) = @_;
    return 1 if !defined $a && !defined $b;
    return 0 if !defined $a || !defined $b;
    return ( refaddr($a) == refaddr($b) ) ? 1 : 0 if ref($a) && ref($b);
    return 0 if ref($a) || ref($b);
    return ( $a eq $b ) ? 1 : 0;
}

# Register an api's `{construct, config}` pair.
#
# Idempotent per api: registering the SAME pair twice is a no-op,
# because module self-registration plus an explicit `provide` for one
# api is an ordinary thing for an application to end up with. A second
# registration with a DIFFERENT factory is `station_factory_conflict` -
# silently picking one of two SDK builds is not a thing to do quietly.
sub provide {
    my ( $api, $factory ) = @_;
    my $slug = defined $api ? "$api" : '';
    $factory = {} unless ref($factory) eq 'HASH';

    my $prior = $TABLE{$slug};
    if ( defined $prior ) {
        return $prior
          if _same( $prior->{construct}, $factory->{construct} )
          && _same( $prior->{config}, $factory->{config} );

        Voxgig::Station::Error::fail( 'station_factory_conflict',
            'two different factories registered for api "' . $slug
              . '"; a process has one build of an SDK, and picking between '
              . 'two silently is not a thing to do quietly' );
    }

    # AT PROVIDE TIME, which is the whole point of carrying `config`.
    my ( $descriptor, $warnings ) = normalize_descriptor( $factory->{config}, undef );

    my $entry = {
        api        => $slug,
        construct  => $factory->{construct},
        config     => $factory->{config},
        descriptor => $descriptor,
        warnings   => $warnings,
    };
    $TABLE{$slug} = $entry;
    return $entry;
}

sub factory_for {
    my ($api) = @_;
    return undef unless defined $api;
    return $TABLE{"$api"};
}

sub provided {
    return [ sort keys %TABLE ];
}

# Test seam. The table is process-global by design, so a suite that
# registers factories has to be able to put the process back.
sub reset_factories {
    %TABLE = ();
    return;
}

1;
