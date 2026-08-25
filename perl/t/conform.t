# RUN: prove -Ilib -It t/
# RUN-SOME: perl -Ilib -It t/conform.t
#
# The station conformance suite: the pure-contract half of the design's
# (station.md 13) corpus, from spec/station.json, through voxgig/omni -
# the same file every port runs. Sections that need live SDK machinery
# (inject, order, event correlation) live in t/station.t and the
# generated-SDK integration flow; the corpus carries what a port can
# prove with no SDK present.
#
# TWO EXPLICIT TABLES, and the tests are REGISTERED FROM THEM:
#
#   @DRIVERS  section name -> the subject that runs it. This is the
#             opt-in surface: a section runs if and only if it is here,
#             and because registration is derived from the table a
#             section named here cannot silently fail to execute.
#   @PENDING  section name -> a written REASON for not running it. An
#             entry here is a recorded decision, not an omission.
#
# `sections-covered` then closes the other direction: it reads
# spec/station.json DIRECTLY - not through the runner, which resolves and
# normalizes a named section and would hide one it never resolved - and
# asserts that (drivers + pending) EXACTLY equals the corpus's own
# section list. A section added to the corpus and not picked up here
# fails loudly instead of never running; a section renamed away from
# under a stale driver or a stale pending pin fails too.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use JSON::PP ();
use Test::More;

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
# SEKRETO_HOME, or the sibling checkout); Voxgig::Station::Struct locates
# voxgig/struct the same way, lazily.
use Voxgig::Station qw(instance_ref);
use Voxgig::Station::Descriptor qw(
  canonical_serialize envtoken normalize_descriptor secretname_default
);
use Voxgig::Station::Error qw(is_known_code);
use Voxgig::Station::Feature qw(
  checkpin featuresources mergefeatures resolveorder
);
use Voxgig::Station::Profile qw(resolve_profile);
use Voxgig::Station::Secrets qw(placeholder_for);
use Voxgig::Station::Shape qw(normalize_config validate_config);
use Voxgig::Station::Struct qw(struct_parse);

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

# --- declaration order, which a perl hash cannot keep ---
#
# 8.4's LAST tie-break is the order the config declared its features in.
# The canonical library gets that free from a JavaScript object and omni
# hands this port the entry as JSON::PP parsed it - a plain perl hash,
# whose key order perl randomises per hash. So the spec file is parsed a
# SECOND time with struct's own order-preserving reader, and each
# `feature` entry's authored `merged` map is indexed by the canonical
# serialization of its `in` value.
#
# A MISS IS AN ERROR, not a shrug: the fallback would be sorted keys,
# which happens to agree with the authored order in every entry of this
# section and would therefore pass by alphabetical accident while
# silently never testing the tie-break at all.
my %MERGED_ORDER;

sub mergedorder {
    if ( !%MERGED_ORDER ) {
        my $file = specfile('station.json');
        open( my $handle, '<', $file ) or die "station: cannot read $file";
        local $/ = undef;
        my $text = <$handle>;
        close($handle);

        my $parsed = struct_parse($text);
        my $set    = $parsed->{primary}{station}{feature}{set};
        for my $entry ( @{ ref($set) eq 'ARRAY' ? $set : [] } ) {
            next unless ref($entry) eq 'HASH' && ref( $entry->{in} ) eq 'HASH';
            next unless ref( $entry->{in}{merged} ) eq 'HASH';
            $MERGED_ORDER{ canonical_serialize( $entry->{in} ) } =
              $entry->{in}{merged};
        }
    }
    my ($vin) = @_;
    my $key = canonical_serialize($vin);
    my $merged = $MERGED_ORDER{$key};
    die 'station: no authored key order for feature entry: ' . $key
      unless defined $merged;
    return $merged;
}

# One driver per section this port RUNS, keyed by the corpus section
# name. A LIST OF PAIRS rather than a hash, because a perl hash has no
# order and the table is meant to read in the order the sections do.
my @DRIVERS = (
    [
        secretname => sub {
            my ($vin) = @_;
            my $secretname = secretname_default( $vin->{slug} );
            return {
                envtoken   => envtoken( $vin->{slug} ),
                secretname => $secretname,
                envkey     => Voxgig::Sekreto::envkey($secretname),
            };
        }
    ],

    [ placeholder => sub { return placeholder_for( $_[0] ) } ],

    [
        descriptor => sub {
            my ($vin) = @_;
            my ($descriptor) =
              normalize_descriptor( $vin->{config}, $vin->{feature} );
            return $descriptor;
        }
    ],

    [
        descriptorwarnings => sub {
            my ($vin) = @_;
            my ( undef, $warnings ) =
              normalize_descriptor( $vin->{config}, $vin->{feature} );
            return scalar @$warnings;
        }
    ],

    [ canonical => sub { return canonical_serialize( denull( $_[0] ) ) } ],

    # Normalize, then validate (design station.md 4.2). The entry is a
    # RAW config in, and either the normalized output or the expected
    # error out - the two steps are ONE pipeline, and a port that splits
    # them is free to validate the wrong form.
    [
        config => sub {
            return validate_config( normalize_config( denull( $_[0] ) ) );
        }
    ],

    # The 3.3 merge, and the whole of this port's profile contract.
    [
        instance => sub {
            my ($vin) = @_;
            return resolve_profile( denull( $vin->{config} ), $vin->{profile} );
        }
    ],

    # 6.1's `as` rule: pure over (api, opts), so it is corpus-shaped
    # rather than driver-shaped even though it decides a registry key.
    [ instanceref => sub { return instance_ref( $_[0]{api}, $_[0]{opts} ) } ],

    # 8's pure half: the three-level merge with its depth boundary, and
    # the 8.4 order resolution. ONE driver, TWO entry shapes - `merged`
    # selects the resolver, anything else the merge - because a port that
    # guessed from looser cues would run the wrong subject on a mistyped
    # entry.
    [
        feature => sub {
            my ($vin) = @_;
            if ( defined $vin->{merged} ) {
                my $ordered = resolveorder( mergedorder($vin) );
                checkpin($ordered);
                return [ map { $_->{name} } @$ordered ];
            }
            return mergefeatures(
                featuresources(
                    denull( $vin->{base} ), denull( $vin->{overlay} ),
                    $vin->{api},            $vin->{ref}
                )
            );
        }
    ],

    [ errors => sub { return is_known_code( $_[0] ) } ],
);

# The sections this port deliberately does NOT run, with the reason - an
# entry here is a decision, not an omission. EMPTY: this port runs every
# section the corpus carries, so the guard below reduces to drivers ==
# corpus sections. The table stays because it is the only sanctioned way
# to not run one.
my @PENDING = ();

plan tests => 1 + scalar(@DRIVERS);

# Section completeness: the sections run plus the explicit PENDING list
# must EXACTLY cover what spec/station.json carries. Read as raw JSON
# rather than through the runner, which resolves a named section and
# would hide one it never resolved.
subtest 'sections-covered' => sub {
    plan tests => 1;

    my $file = specfile('station.json');
    open( my $handle, '<', $file ) or die "station: cannot read $file";
    local $/ = undef;
    my $text = <$handle>;
    close($handle);

    my $spec = JSON::PP->new->decode($text);
    my @present = sort keys %{ $spec->{primary}{station} };
    my @covered = sort map { $_->[0] } ( @DRIVERS, @PENDING );

    is_deeply( \@covered, \@present, 'every corpus section is run or pinned' );
};

my $R = makeRunner( specfile('station.json') )->('station');

my $spec   = $R->{spec};
my $runset = $R->{runset};

for my $row (@DRIVERS) {
    my ( $section, $subject ) = @$row;
    subtest $section => sub {
        plan tests => 1;

        # A renamed section would otherwise match nothing and pass.
        if ( !defined $spec->{$section} ) {
            fail( 'corpus section missing: ' . $section );
            return;
        }

        my $ok = eval { $runset->( $spec->{$section}, $subject ); 1 };
        if ($ok) {
            pass($section);
        }
        else {
            fail($section);
            diag("$@");
        }
    };
}
