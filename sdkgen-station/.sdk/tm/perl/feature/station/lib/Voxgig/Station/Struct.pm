package Voxgig::Station::Struct;

# The voxgig/struct seam (design station.md 4).
#
# struct backs validate_config, and unlike voxgig/omni it is a RUNTIME
# dependency: the validator runs at open(), not only under test. It is
# the SECOND dependency a station library takes, sanctioned by design 9;
# nothing else is added.
#
# Discovery follows the convention this port already uses for sekreto
# and omni - $STRUCT_HOME, then a sibling checkout, then two fixed
# fallbacks - and it is LAZY: `use Voxgig::Station` must not fail on a
# missing checkout for a caller that never validates a config.
#
# This module also owns the ORDERED MAP, which is not incidental. Perl
# hashes have no key order at all (`keys` is randomised per process),
# and design 8.4 makes declaration order load-bearing: it is the LAST
# tie-break of the feature order. Voxgig::Struct ships an insertion-
# ordered tied hash for exactly this reason, so station uses it rather
# than growing a second one, and `mapkeys` mirrors struct's own rule -
# insertion order for a tied map, sorted keys for a plain one, which is
# the only stable answer where there is no order to read.
#
# A port of javascript/src/structhome.js; typescript/src/shape.ts is
# canonical for what it is used for.

use strict;
use warnings;

use File::Basename ();
use File::Spec ();
use JSON::PP ();

use Exporter 'import';
our @EXPORT_OK = qw(
  jsonform mapkeys ordered_map struct_clone struct_home struct_parse
  struct_validate structmod
);

# The struct perl port's own library root inside a checkout.
my $STRUCT_MARKER = File::Spec->catfile( 'perl', 'lib', 'Voxgig', 'Struct.pm' );

sub struct_home {
    my ($marker) = @_;
    $marker = $STRUCT_MARKER unless defined $marker;

    my $dir = File::Basename::dirname( File::Spec->rel2abs(__FILE__) );  # .../lib/Voxgig/Station
    my $libroot =
      File::Basename::dirname( File::Basename::dirname($dir) );          # .../lib

    for my $cand (
        $ENV{STRUCT_HOME},
        File::Spec->catdir( $libroot, '..', '..', '..', 'struct' ),
        File::Spec->catdir( $libroot, '..', '..', '..', '..', 'struct' ),
        '/workspace/struct',
        '/home/user/struct',
      )
    {
        next unless defined $cand && '' ne $cand;
        return File::Spec->rel2abs($cand)
          if -e File::Spec->catfile( $cand, $marker );
    }

    die 'station: voxgig/struct not found - set STRUCT_HOME';
}

# Voxgig::Struct itself: already loadable first (a vendored side-by-side
# copy, an installed module, or a caller-supplied -I - the same order the
# sekreto bootstrap uses), then the checkout. Resolved on FIRST USE.
my $LOADED = 0;

sub structmod {
    return 'Voxgig::Struct' if $LOADED;

    if ( !eval { require Voxgig::Struct; 1 } ) {
        my $path = File::Spec->catdir( struct_home(), 'perl', 'lib' );
        unshift @INC, $path unless grep { $_ eq $path } @INC;
        require Voxgig::Struct;
    }

    $LOADED = 1;
    return 'Voxgig::Struct';
}

sub struct_clone    { structmod(); return Voxgig::Struct::clone( $_[0] ) }
sub struct_parse    { structmod(); return Voxgig::Struct::parse_json( $_[0] ) }
sub struct_validate { structmod(); return Voxgig::Struct::validate( @_ ) }

# An insertion-ordered map: struct's own tied hash, so a station map and
# a struct map are the same kind of thing and `clone` keeps the order.
sub ordered_map {
    structmod();
    my %h;
    tie %h, 'Voxgig::Struct::OrderedHash';
    my $out = \%h;
    while ( 2 <= scalar @_ ) {
        my $key = shift;
        my $val = shift;
        $out->{$key} = $val;
    }
    return $out;
}

# Struct's JSON tree in the spelling the rest of this port speaks: its
# own boolean singletons become JSON::PP booleans (the port's rule for
# every value that crosses a serialization boundary or the corpus) and
# its JSON-null singleton becomes undef. The ORDERED MAPS ARE KEPT, and
# they are the whole reason a config file is read through struct's
# reader rather than JSON::PP's: JSON::PP hands back plain perl hashes,
# and design 8.4's last tie-break is the order the config declared its
# features in.
sub jsonform {
    my ($val) = @_;
    return $val if !defined $val;

    my $ref = ref $val;
    return $val if '' eq $ref;

    structmod();
    return undef if Voxgig::Struct::is_jnull($val);
    return ( $val ? JSON::PP::true : JSON::PP::false )
      if Voxgig::Struct::is_jbool($val);

    return [ map { jsonform($_) } @$val ] if 'ARRAY' eq $ref;

    if ( 'HASH' eq $ref ) {
        my $out = ordered_map();
        $out->{$_} = jsonform( $val->{$_} ) for mapkeys($val);
        return $out;
    }

    return $val;
}

# The keys of a map in the order that MEANS something: insertion order
# when the map has one, sorted otherwise. Never raw `keys`, which is
# randomised per hash and would make design 8.4's last tie-break a
# different answer on every run.
sub mapkeys {
    my ($map) = @_;
    return () unless ref($map) eq 'HASH';
    my $tied = tied(%$map);
    return $tied->Keys if defined $tied && $tied->can('Keys');
    return sort keys %$map;
}

1;
