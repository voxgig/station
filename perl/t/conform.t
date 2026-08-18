# RUN: prove -Ilib -It t/
# RUN-SOME: perl -Ilib -It t/conform.t
#
# The station conformance suite: the pure-contract half of the design's
# (station.md 13) corpus, from spec/station.json, through voxgig/omni -
# the same file every port runs. Sections that need live SDK machinery
# (inject, order, event correlation) live in t/station.t and the
# generated-SDK integration flow; the corpus carries what a port can
# prove with no SDK present.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use Test::More tests => 7;

# Find the shared spec directory by walking up from this file.
sub specfile {
    my ($name) = @_;
    my $dir = dirname( File::Spec->rel2abs(__FILE__) );
    for ( 1 .. 8 ) {
        my $cand = File::Spec->catfile( $dir, 'spec', $name );
        return $cand if -e $cand;
        $dir = dirname($dir);
    }
    die "station: spec not found: $name";
}

# omni is a sibling checkout, not a published distribution (yet), so its
# lib is added to @INC by path (the sekreto port's idiom).
sub omnihome {
    my $here = dirname( File::Spec->rel2abs(__FILE__) );

    for my $cand (
        $ENV{OMNI_HOME},
        File::Spec->catdir( $here, '..', '..', '..', 'omni' ),
        File::Spec->catdir( $here, '..', '..', '..', '..', 'omni' ),
        '/workspace/omni',
        '/home/user/omni',
      )
    {
        next unless defined $cand;
        return $cand if -e File::Spec->catfile( $cand, 'spec', 'fib.json' );
    }

    die 'station: voxgig/omni not found - set OMNI_HOME';
}

BEGIN { unshift @INC, File::Spec->catdir( omnihome(), 'perl', 'lib' ) }

use Voxgig::Omni::Runner qw(makeRunner);
use Voxgig::Omni::Util qw(NULLMARK islist ismap);

# Voxgig::Station's bootstrap locates Voxgig::Sekreto (vendored, @INC,
# SEKRETO_HOME, or the sibling checkout).
use Voxgig::Station;
use Voxgig::Station::Descriptor qw(
  canonical_serialize envtoken normalize_descriptor secretname_default
);
use Voxgig::Station::Error qw(is_known_code);
use Voxgig::Station::Profile qw(resolve_profile);
use Voxgig::Station::Secrets qw(placeholder_for);

my $R = makeRunner( specfile('station.json') )->('station');

my $spec   = $R->{spec};
my $runset = $R->{runset};

# Spec nulls arrive as omni's NULLMARK sentinel; restore them so a
# subject sees what the spec means.
sub denull {
    my ($val) = @_;
    return undef if defined $val && !ref $val && NULLMARK eq $val;
    return [ map { denull($_) } @$val ] if islist($val);
    if ( ismap($val) ) {
        my %out;
        $out{$_} = denull( $val->{$_} ) for keys %$val;
        return \%out;
    }
    return $val;
}

# Run one group, reporting pass or fail through Test::More.
sub group {
    my ( $name, $body ) = @_;
    my $ok = eval { $body->(); 1 };
    if ($ok) {
        pass($name);
    }
    else {
        fail($name);
        diag("$@");
    }
}

group(
    'secretname',
    sub {
        $runset->(
            $spec->{secretname},
            sub {
                my ($vin) = @_;
                my $secretname = secretname_default( $vin->{slug} );
                return {
                    envtoken   => envtoken( $vin->{slug} ),
                    secretname => $secretname,
                    envkey     => Voxgig::Sekreto::envkey($secretname),
                };
            }
        );
    }
);

group(
    'placeholder',
    sub {
        $runset->( $spec->{placeholder}, sub { placeholder_for( $_[0] ) } );
    }
);

group(
    'descriptor',
    sub {
        $runset->(
            $spec->{descriptor},
            sub {
                my ($vin) = @_;
                my ($descriptor) =
                  normalize_descriptor( $vin->{config}, $vin->{feature} );
                return $descriptor;
            }
        );
    }
);

group(
    'descriptorwarnings',
    sub {
        $runset->(
            $spec->{descriptorwarnings},
            sub {
                my ($vin) = @_;
                my ( undef, $warnings ) =
                  normalize_descriptor( $vin->{config}, $vin->{feature} );
                return scalar @$warnings;
            }
        );
    }
);

group(
    'canonical',
    sub {
        $runset->(
            $spec->{canonical},
            sub { canonical_serialize( denull( $_[0] ) ) }
        );
    }
);

group(
    'profile',
    sub {
        $runset->(
            $spec->{profile},
            sub {
                my ($vin) = @_;
                return resolve_profile( denull( $vin->{config} ), $vin->{profile} );
            }
        );
    }
);

group(
    'errors',
    sub {
        $runset->( $spec->{errors}, sub { is_known_code( $_[0] ) } );
    }
);
