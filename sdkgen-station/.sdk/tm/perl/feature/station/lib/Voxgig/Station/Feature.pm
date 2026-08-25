package Voxgig::Station::Feature;

# Feature management (design station.md 8): the three-level merge, the
# constraint-and-band resolver, and the descriptor-derived checker.
#
# The resolver is written to voxgig/plugin's 7 semantics so plugin can
# extract it - this is one of the pieces the joint plan means by
# "station builds natively to plugin's semantics".
#
# A port of typescript/src/feature.ts, which is canonical.
#
# ONE PERL NOTE, AND IT RUNS THROUGH THE WHOLE FILE: a perl hash has NO
# key order (`keys` is randomised per hash), and 8.4 makes declaration
# order load-bearing - it is the LAST tie-break of the feature order.
# So every map this module BUILDS is an insertion-ordered map
# (Voxgig::Station::Struct::ordered_map, struct's own tied hash), and
# every map it READS is walked through `mapkeys`, which answers
# insertion order where there is one and sorted keys where there is
# none. A config parsed from station.json carries its order (the
# reader is struct's); a config passed in code as a plain perl hash
# has none to carry, and falls back to sorted - this port's one
# behavioural divergence on 8.4's last tie-break, stated in README.md.

use strict;
use warnings;

use JSON::PP ();
use Scalar::Util qw(blessed);

use Voxgig::Station::Descriptor ();
use Voxgig::Station::Error ();
use Voxgig::Station::Struct qw(mapkeys ordered_map);

use Exporter 'import';
our @EXPORT_OK = qw(
  BAND_DEFAULT BAND_STATION BAND_TEST RESERVED_KEYS
  checkfeatures checkpin composefeatures defaultband featuresources
  mergefeatures resolveorder
);

sub _ismap  { return ref( $_[0] ) eq 'HASH' ? 1 : 0 }
sub _islist { return ref( $_[0] ) eq 'ARRAY' ? 1 : 0 }

# Exactly boolean false - a JSON::PP boolean or struct's own. A plain 0
# is a number, and `false !== 0` in the canonical, so it is not this.
sub _isfalse {
    my ($val) = @_;
    return 0 unless defined $val && ref $val;
    return 0
      unless JSON::PP::is_bool($val)
      || ( blessed($val) && 'Voxgig::Struct::Bool' eq ref($val) );
    return $val ? 0 : 1;
}

# ---------------------------------------------------------------------
# 8.3 - the merge
# ---------------------------------------------------------------------

# Reserved on a feature entry: not options, and never passed through to
# the SDK's own option map.
our @RESERVED_KEYS = ( 'active', 'order' );
my %RESERVED = map { $_ => 1 } @RESERVED_KEYS;

sub RESERVED_KEYS { return @RESERVED_KEYS }

# `feature` is the ONE key where 3.3's shallow-per-key rule is wrong:
# composition is the entire point, a fleet default plus a per-instance
# tweak. So it is a TWO-LEVEL merge - per feature name, then per option
# key - and NO DEEPER. A map-valued option REPLACES wholesale, which is
# what `{"$MERGE": {"deep": 2}}` states and what a port defaulting to a
# deep merge would silently get wrong.
#
# NO DEFAULTS ARE SYNTHESIZED HERE - the caller passes RAW blocks. An
# entry mentioned at one level with only a tuning key must NOT
# synthesize `active` and switch on a feature a broader level turned
# off. That is the 3.3 defect one level down.
sub mergefeatures {
    my ($sources) = @_;
    my $out = ordered_map();

    for my $src ( @{ _islist($sources) ? $sources : [] } ) {
        next unless _ismap($src);
        for my $name ( mapkeys($src) ) {
            my $entry = $src->{$name};
            if ( !_ismap($entry) ) { $out->{$name} = $entry; next }

            # Per option key, and NOT deeper.
            my $at = $out->{$name};
            if ( !_ismap($at) ) { $at = ordered_map(); $out->{$name} = $at }
            $at->{$_} = $entry->{$_} for mapkeys($entry);
        }
    }
    return $out;
}

# The six sources for one instance, in 3.3's order extended by the
# profile level:
#
#   1 base.feature            4 overlay.feature
#   2 base.api[<api>].feature 5 overlay.api[<api>].feature
#   3 base.sdk[<ref>].feature 6 overlay.sdk[<ref>].feature
#
# PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and within a profile
# the narrower block wins. Assembled here rather than at the call site
# so the order lives in exactly one place.
sub featuresources {
    my ( $base, $overlay, $api, $ref ) = @_;
    return [
        _at( $base,    undef, undef ),
        _at( $base,    'api', $api ),
        _at( $base,    'sdk', $ref ),
        _at( $overlay, undef, undef ),
        _at( $overlay, 'api', $api ),
        _at( $overlay, 'sdk', $ref ),
    ];
}

sub _at {
    my ( $level, $kind, $key ) = @_;
    return undef unless _ismap($level);
    return $level->{feature} unless defined $kind;
    my $map = $level->{$kind};
    return undef unless _ismap($map) && defined $key;
    my $block = $map->{$key};
    return _ismap($block) ? $block->{feature} : undef;
}

# ---------------------------------------------------------------------
# 8.4 - activation and order
# ---------------------------------------------------------------------

# `test` substitutes the base transport, so it takes the innermost band;
# `station` sits immediately outside it, pinned; everything else is band
# 0, outside station. HIGHER IS FURTHER IN.
#
# THE DEFAULT IS TODAY'S BEHAVIOUR EXPRESSED IN THE NEW MODEL rather
# than as a special case: a project that writes no `order` anywhere sees
# exactly today's nesting.
use constant BAND_DEFAULT => 0;
use constant BAND_STATION => 100;
use constant BAND_TEST    => 200;

sub defaultband {
    my ($name) = @_;
    return BAND_TEST    if 'test' eq $name;
    return BAND_STATION if 'station' eq $name;
    return BAND_DEFAULT;
}

# A feature named in the config is one you are ASKING for, so an entry
# with no `active` is active.
sub _active {
    my ($entry) = @_;
    return !_isfalse($entry) if !_ismap($entry);
    return !_isfalse( $entry->{active} );
}

# `before`/`after` take a feature name or a list of them, stringified.
sub _listof {
    my ($val) = @_;
    return [] unless defined $val;
    return [ map { defined $_ ? "$_" : '' } @{ _islist($val) ? $val : [$val] } ];
}

# Resolve the activation order: constraints, then bands, then the
# feature's position in the merged map.
#
# `before`/`after` are SATISFIED VACUOUSLY when the named feature is
# absent - `after: 'test'` loads fine in a project with no test feature,
# which is sdkgen's `__after__` behaviour kept rather than reinvented.
#
# Constraints beat bands; bands break ties no constraint decides;
# remaining ties break by declaration position, so the result is a
# stable topological sort with no alphabetical accident in it.
#
# Returns OUTERMOST FIRST, which is the array form the constructor takes
# and the direction plugin's chain composes in.
sub resolveorder {
    my ($merged) = @_;
    $merged = {} unless _ismap($merged);

    my @names = grep { _active( $merged->{$_} ) } mapkeys($merged);
    my %pos;
    $pos{ $names[$_] } = $_ for 0 .. $#names;

    my %band;
    for my $name (@names) {
        my $entry = $merged->{$name};
        my $order = _ismap($entry) ? $entry->{order} : undef;
        my $b =
          ( _ismap($order) && _isnumber( $order->{band} ) )
          ? 0 + $order->{band}
          : defaultband($name);
        $band{$name} = $b;
    }

    # Edges from OUTER to INNER: `after: X` means "further in than X".
    my %inner = map { $_ => {} } @names;
    for my $name (@names) {
        my $entry = $merged->{$name};
        my $order = _ismap($entry) ? $entry->{order} : undef;
        next unless _ismap($order);
        for my $other ( @{ _listof( $order->{after} ) } ) {
            $inner{$other}{$name} = 1 if exists $inner{$other};
        }
        for my $other ( @{ _listof( $order->{before} ) } ) {
            $inner{$name}{$other} = 1 if exists $inner{$other};
        }
    }

    my %indeg = map { $_ => 0 } @names;
    for my $name (@names) {
        $indeg{$_}++ for keys %{ $inner{$name} };
    }

    # Kahn, picking the LOWEST BAND first (outermost), then declaration
    # position - so ties break the same way in every port.
    my @ready = grep { 0 == $indeg{$_} } @names;
    my @out;
    while (@ready) {
        @ready =
          sort { $band{$a} <=> $band{$b} || $pos{$a} <=> $pos{$b} } @ready;
        my $name = shift @ready;
        push @out, { name => $name, band => $band{$name}, entry => $merged->{$name} };
        for my $next ( sort { $pos{$a} <=> $pos{$b} } keys %{ $inner{$name} } ) {
            $indeg{$next}--;
            push @ready, $next if 0 == $indeg{$next};
        }
    }

    if ( scalar(@out) != scalar(@names) ) {
        my %emitted = map { $_->{name} => 1 } @out;
        my @stuck = sort grep { !$emitted{$_} } @names;
        Voxgig::Station::Error::fail( 'station_feature_order',
            'feature ordering constraints form a cycle among ['
              . join( ', ', @stuck ) . ']' );
    }

    return \@out;
}

# Station's own position is PINNED and not orderable (8.4): an order
# that moves `station` away from immediately-outside-the-base is
# REJECTED, not honoured.
#
# The pin is INNERMOST, and the spelling matters. A chain composes with
# the FIRST binding outermost, so a pin written in sort terms - "station
# first" - would place every other wrapper between the adapter and the
# base: the exact inversion of the invariant, and one that would leave
# station's wire-truth events observing the wrong boundary while still
# looking ordered.
sub checkpin {
    my ($ordered) = @_;
    $ordered = [] unless _islist($ordered);

    my ($at) = grep { 'station' eq $ordered->[$_]{name} } 0 .. $#$ordered;
    return unless defined $at;

    my ($base) = grep { 'test' eq $ordered->[$_]{name} } 0 .. $#$ordered;
    my $want = defined $base ? $base - 1 : scalar(@$ordered) - 1;

    if ( $at != $want ) {
        Voxgig::Station::Error::fail( 'station_feature_order',
            'an ordering would move `station` away from immediately outside '
              . 'the base transport; its position is pinned innermost and is '
              . 'not orderable (8.4)' );
    }
    return;
}

# Compose the ordered rows into the ARRAY FORM the generated constructor
# already accepts. No new seam: it is what connect() already does for
# station's own placement, with more in it.
sub composefeatures {
    my ($ordered) = @_;
    my @out;
    for my $row ( @{ _islist($ordered) ? $ordered : [] } ) {
        my $entry = _ismap( $row->{entry} ) ? $row->{entry} : {};
        my $out = ordered_map( name => $row->{name}, active => JSON::PP::true );
        for my $key ( mapkeys($entry) ) {
            next if $RESERVED{$key};
            $out->{$key} = $entry->{$key};
        }
        push @out, $out;
    }
    return \@out;
}

# ---------------------------------------------------------------------
# 8.5 - the checker, derived from the descriptor
# ---------------------------------------------------------------------

# Check a merged feature map against the SDK'S OWN DECLARATION.
#
# The schema arrives with the FACTORY rather than with a live client
# (6.2), so this needs no construction and no network - which is what
# lets check() run it for every instance in CI.
#
# Derived from the descriptor, NEVER hand-written, so it cannot drift:
# when a feature gains an option, the next regeneration teaches station
# about it with no station change.
#
# SCALARS AGREE BY CONSTRUCTION; COMPOUND OPTIONS ARE KIND-CHECKED ONLY,
# and that limit is real and deliberate: an empty list default says
# nothing reliable about its element type and a nested map default says
# nothing about its value shapes.
#
# COLLECTS, never throws - the callers own the throw.
sub checkfeatures {
    my ( $merged, $descriptor ) = @_;
    my @faults;

    my $declared =
      ( _ismap($descriptor) && _islist( $descriptor->{features} ) )
      ? $descriptor->{features}
      : [];
    my %byname;
    for my $row (@$declared) {
        next unless _ismap($row);
        $byname{ defined $row->{name} ? "$row->{name}" : '' } = $row;
    }
    my @declarednames = sort keys %byname;

    $merged = {} unless _ismap($merged);
    for my $name ( sort keys %$merged ) {
        my $spec = $byname{$name};
        if ( !defined $spec ) {
            push @faults,
              {
                code    => 'station_feature_unknown',
                feature => $name,
                message => 'the SDK has no feature "' . $name . '"; it declares ['
                  . join( ', ', @declarednames ) . ']',
              };
            next;
        }

        my $entry = $merged->{$name};
        next unless _ismap($entry);
        my $defaults = _ismap( $spec->{options} ) ? $spec->{options} : {};
        my @defaultkeys = sort keys %$defaults;

        for my $key ( sort keys %$entry ) {
            next if $RESERVED{$key};

            if ( !exists $defaults->{$key} ) {

                # THE CASE THAT ACTUALLY BITES: `retry.retires: 5` is
                # accepted and silently ignored today, because the SDK's
                # own feature spec is `$OPEN` per feature so the SDK
                # cannot catch it and nothing else looks.
                push @faults,
                  {
                    code    => 'station_feature_option',
                    feature => $name,
                    key     => $key,
                    message => 'feature "' . $name . '" declares no option "'
                      . $key . '"; it declares [' . join( ', ', @defaultkeys ) . ']',
                  };
                next;
            }

            my $want = _kindof( $defaults->{$key} );
            my $got  = _kindof( $entry->{$key} );
            if ( $want ne $got ) {
                push @faults,
                  {
                    code    => 'station_feature_option',
                    feature => $name,
                    key     => $key,
                    message => 'feature "' . $name . '" option "' . $key
                      . '" expects ' . $want . ', but found ' . $got . ': '
                      . Voxgig::Station::Descriptor::canonical_serialize( $entry->{$key} ),
                  };
            }
        }
    }

    return \@faults;
}

# THE FEATURE kindof - deliberately NOT the shape one (which must agree
# with struct's own spellings). Unifying the two would make one of them
# wrong.
my $SCALAR_JSON = JSON::PP->new->allow_nonref(1)->allow_blessed(1)->convert_blessed(1);

sub _kindof {
    my ($val) = @_;
    return 'null' if !defined $val;
    return 'boolean' if JSON::PP::is_bool($val);
    my $r = ref $val;
    return 'list' if 'ARRAY' eq $r;
    return 'map'  if 'HASH' eq $r;
    return 'map'  if '' ne $r;
    return _isnumber($val) ? 'number' : 'string';
}

# A number by SV flags, never a guess from a string: JSON::PP encodes a
# numeric scalar bare and a string quoted, which is the same test the
# canonical serializer makes.
sub _isnumber {
    my ($val) = @_;
    return 0 if !defined $val || ref $val;
    my $enc = eval { $SCALAR_JSON->encode($val) };
    return ( defined $enc && $enc =~ /^-?[0-9][0-9.eE+-]*$/ ) ? 1 : 0;
}

1;
