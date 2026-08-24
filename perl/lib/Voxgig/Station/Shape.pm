package Voxgig::Station::Shape;

# The config grammar, as data (design station.md 4).
#
# TWO STEPS, AND THE FIRST IS WHAT MAKES THE SECOND HONEST.
#
# struct drops the unexpected-key check for a map whose spec node ends
# up EMPTY - "an empty spec object means the object can be open". An
# optional key is `['$ONE','$NIL', spec]`, and when the data does not
# carry that key the validator REMOVES it from the spec node. So a block
# whose keys are all optional degenerates into an open map exactly when
# the data has none of them, and `{"solar": {"bass": 1}}` validates
# clean - the one property the whole exercise is for, silently absent in
# the one case that matters.
#
# So: normalize_config materializes every documented default, and
# validate_config then runs a shape WITH NO OPTIONAL CONTAINERS AT ALL.
# After normalization every container is present, so the shape can
# require them, so unexpected-key detection is live at every level and
# every error names its path.
#
# A port of typescript/src/shape.ts, which is canonical. Two
# perl-specific mappings, both forced by the language rather than
# chosen:
#
#  - booleans crossing the corpus are JSON::PP booleans (the port's
#    existing rule), and struct's typify only knows its own, so the
#    tree handed to the validator is `_structify`ed on the way in - a
#    deep copy with the booleans translated. The value RETURNED is the
#    normalized form itself, untouched.
#  - that copy is an ORDERED map built through Voxgig::Station::Struct's
#    `mapkeys`, so struct walks the data in a deterministic order.
#    `config#every-error-at-once` pins the joined error order, and a
#    plain perl hash would answer differently on every run.

use strict;
use warnings;

use File::Basename ();
use File::Spec ();
use JSON::PP ();

use Voxgig::Station::Descriptor ();
use Voxgig::Station::Error ();
use Voxgig::Station::Struct qw(mapkeys ordered_map struct_clone struct_parse);

use Exporter 'import';
our @EXPORT_OK = qw(
  BLOCK_DEFAULTS MERGE_SENSITIVE PROFILE_DEFAULTS
  config_shape normalize_config validate_config
);

sub _ismap  { return ref( $_[0] ) eq 'HASH' ? 1 : 0 }
sub _islist { return ref( $_[0] ) eq 'ARRAY' ? 1 : 0 }
sub _isstr  { return ( defined $_[0] && !ref $_[0] ) ? 1 : 0 }

# ---------------------------------------------------------------------
# The defaults tables - ONE table, two callers
# ---------------------------------------------------------------------

# Profile-level containers. Safe to materialize early either way: they
# are containers, and a missing one merges as empty regardless.
#
# Each default is a MAKER, never a shared value: a station.json with two
# profiles must not end up with one `sdk` map behind both.
sub PROFILE_DEFAULTS {
    return (
        secrets => sub { return { providers => [ { kind => 'env' } ] } },
        api     => sub { return {} },
        sdk     => sub { return {} },
        feature => sub { return {} },
    );
}

# Block-level. `feature` is a container and safe early.
#
# `active` IS NOT, and that is the whole timing rule: a default
# synthesized into an OVERLAY block overwrites the base's real value and
# silently reactivates an integration the base deliberately barred
# (3.3). So the two consumers read this same table at different moments
# - validate_config before, to every block, because a block with no
# present keys is an open map; the profile resolver AFTER, to the merged
# instance, because an absent key must stay absent through the merge.
#
# `active` is a real JSON boolean, not a truthy scalar: the corpus
# compares by value, and perl's 1 serializes as a number where every
# other port emits `true`.
sub BLOCK_DEFAULTS {
    return (
        active  => sub { return JSON::PP::true },
        feature => sub { return {} },
    );
}

# The one block key carrying the timing rule. Named rather than
# inferred, so a reader does not have to work out which of the two it is
# and so a port can assert it.
our @MERGE_SENSITIVE = ('active');

sub MERGE_SENSITIVE { return @MERGE_SENSITIVE }

# ---------------------------------------------------------------------
# normalize_config
# ---------------------------------------------------------------------

# Materialize every documented default, DEFENSIVELY: a node that is not
# the kind it expects is left alone for validate to reject with a
# message that names the path. Pure data-in/data-out, and it MUST NOT
# MUTATE THE INPUT - every map is copied before anything is written
# into it.
#
# THE NORMALIZED FORM IS AN INPUT TO VALIDATION AND TO NOTHING ELSE.
# resolve_profile continues to read the RAW config.
sub normalize_config {
    my ($raw) = @_;
    return $raw unless _ismap($raw);

    my $out = { %$raw };
    $out->{station}  = 1  unless exists $out->{station};
    $out->{profiles} = {} unless exists $out->{profiles};
    return $out unless _ismap( $out->{profiles} );

    my %pdefaults = PROFILE_DEFAULTS();
    my %bdefaults = BLOCK_DEFAULTS();

    my %profiles;
    for my $pname ( keys %{ $out->{profiles} } ) {
        my $p = $out->{profiles}{$pname};
        if ( !_ismap($p) ) { $profiles{$pname} = $p; next }
        my $prof = {%$p};

        for my $key ( keys %pdefaults ) {
            $prof->{$key} = $pdefaults{$key}->() unless exists $prof->{$key};
        }

        # A `secrets` written without `providers` still gets the chain.
        if ( _ismap( $prof->{secrets} ) && !exists $prof->{secrets}{providers} ) {
            $prof->{secrets} =
              { %{ $prof->{secrets} }, providers => [ { kind => 'env' } ] };
        }

        $prof->{feature} = _normfeatures( $prof->{feature} );

        for my $bkey ( 'api', 'sdk' ) {
            next unless _ismap( $prof->{$bkey} );
            my %blocks;
            for my $ref ( keys %{ $prof->{$bkey} } ) {
                my $b = $prof->{$bkey}{$ref};
                if ( !_ismap($b) ) { $blocks{$ref} = $b; next }
                my $block = {%$b};
                for my $key ( keys %bdefaults ) {
                    $block->{$key} = $bdefaults{$key}->() unless exists $block->{$key};
                }
                $block->{feature} = _normfeatures( $block->{feature} );
                $blocks{$ref} = $block;
            }
            $prof->{$bkey} = \%blocks;
        }

        $profiles{$pname} = $prof;
    }
    $out->{profiles} = \%profiles;
    return $out;
}

# Per feature entry, at every level: `active` -> true.
#
# A FEATURE NAMED IN THE CONFIG IS ONE YOU ARE ASKING FOR. The SDK's own
# default is `active: false` for all but `log`, and
# `{"retry": {"retries": 3}}` plainly means "retry, with three
# attempts". It also keeps the feature map closed, for the same reason
# every other block needs one present key.
sub _normfeatures {
    my ($f) = @_;
    return $f unless _ismap($f);
    my %out;
    for my $name ( keys %$f ) {
        my $entry = $f->{$name};
        $out{$name} =
          ( _ismap($entry) && !exists $entry->{active} )
          ? { %$entry, active => JSON::PP::true }
          : $entry;
    }
    return \%out;
}

# ---------------------------------------------------------------------
# validate_config
# ---------------------------------------------------------------------

# `spec/config-shape.json`, 4.3 verbatim - the artifact every port
# reads. This port runs from the repo (like t/conform.t's specfile), so
# it reads the JSON itself rather than shipping a mirror. Parsed by
# struct's own reader, because the shape's `$OPEN` flags must be struct
# booleans for struct to see them.
#
# Every validate gets a CLONE: struct's validate CONSUMES the spec it
# walks (it deletes satisfied `$ONE` branches as it goes), so handing it
# the parsed constant twice would validate the second config against a
# spec the first had already eaten.
my $CONFIG_SHAPE;

sub _shapefile {
    my $dir = File::Basename::dirname( File::Spec->rel2abs(__FILE__) );
    for ( 1 .. 8 ) {
        my $cand = File::Spec->catfile( $dir, 'spec', 'config-shape.json' );
        return $cand if -e $cand;
        $dir = File::Basename::dirname($dir);
    }
    die 'station: spec/config-shape.json not found';
}

sub config_shape {
    if ( !defined $CONFIG_SHAPE ) {
        my $file = _shapefile();
        open( my $handle, '<', $file )
          or die 'station: cannot read ' . $file;
        local $/ = undef;
        my $text = <$handle>;
        close($handle);
        $CONFIG_SHAPE = struct_parse($text);
    }
    return struct_clone($CONFIG_SHAPE);
}

# Credential-shaped keys (5.2). `secret` is here AND is the one exempt
# key - see _secretvalue below; a blanket deny would reject the very
# mechanism that keeps values out of the file.
my @CREDENTIAL_KEYS = qw(
  apikey auth authorization token secret password credential bearer
);
my %CREDENTIAL_KEY = map { $_ => 1 } @CREDENTIAL_KEYS;

# The suffix rule catches `access_key`, `X-Api-Token` and friends in one
# rule rather than a growing list of spellings.
my @CREDENTIAL_SUFFIX = qw(_KEY _TOKEN _SECRET _PASSWORD);

# 5.2's backstop, and it is stated as one rather than as a grammar.
# `validname()` is a NAME grammar, not a credential filter: it rejects
# uppercase, hyphens, `+`, `/` and `=`, so it excludes most real
# credential formats - but a lowercase hex token passes it cleanly. A
# character class cannot tell a name from a secret.
#
# Note this is a RUN bound, not a length bound:
# `acme_internal_billing_service.apikey` is 36 characters and passes
# (runs of 4/8/7/7/6), which is the false positive a naive length bound
# would produce.
my $RUN_BOUND = 24;

# Normalize, then validate (4.2). Raises `station_config_invalid` with
# EVERY error at once - an eighteen-instance config that touches three
# of them must not die because the eighteenth has a typo'd package name.
#
# The 4.4 workarounds are merged into the SAME throw as struct's own
# errors: a struct new enough to reject a first-element gap itself
# reports a DIFFERENT spelling ("to be one of ..."), and the corpus pins
# the explicit one - so the pinned message is produced here either way,
# and behavior is identical whatever struct version resolves.
#
# Takes the NORMALIZED form. Handing it a raw config is the mistake 4.2
# exists to prevent, so every caller goes through normalize_config.
sub validate_config {
    my ($normalized) = @_;

    my @errs;
    Voxgig::Station::Struct::structmod();
    Voxgig::Station::Struct::struct_validate( _structify($normalized),
        config_shape(), { errs => \@errs } );

    my ( $secrets, $reserved, $invalid ) = _scan_config($normalized);

    if ( @errs || @$invalid ) {
        Voxgig::Station::Error::fail( 'station_config_invalid',
            join( '; ', @errs, @$invalid ) . _renamehint($normalized) );
    }
    if (@$reserved) {
        Voxgig::Station::Error::fail( 'station_feature_reserved',
            join( '; ', @$reserved ) );
    }
    if (@$secrets) {
        Voxgig::Station::Error::fail( 'station_config_secret',
            join( '; ', @$secrets ) );
    }
    return $normalized;
}

# A deep copy in the shape struct's validator understands: JSON::PP
# booleans become struct booleans (struct's typify knows only its own,
# and would call a JSON::PP one an `instance`), and every map becomes an
# ORDERED map walked through `mapkeys` - sorted for a plain perl hash -
# so the error order is the same on every run.
sub _structify {
    my ($val) = @_;
    return $val if !defined $val;
    return ( $val ? Voxgig::Struct::JTRUE() : Voxgig::Struct::JFALSE() )
      if JSON::PP::is_bool($val);
    return [ map { _structify($_) } @$val ] if _islist($val);
    if ( _ismap($val) ) {
        my $out = ordered_map();
        $out->{$_} = _structify( $val->{$_} ) for mapkeys($val);
        return $out;
    }
    return $val;
}

# `plugin` is REMOVED, not aliased (3.4) - a deprecated alias would be a
# second grammar for one concept in sixteen ports. The shape already
# rejects it as an unexpected key; this says WHAT TO RENAME, because
# "unexpected key: plugin" alone does not, and the migration for a
# single-instance project is exactly this one rename.
sub _renamehint {
    my ($cfg) = @_;
    my $profiles =
      _ismap($cfg) && _ismap( $cfg->{profiles} ) ? $cfg->{profiles} : {};
    my @hit =
      grep { _ismap( $profiles->{$_} ) && exists $profiles->{$_}{plugin} }
      mapkeys($profiles);
    return '' unless @hit;
    return '; rename `plugin` to `sdk` in '
      . join( ', ', map { 'profiles.' . $_ } @hit )
      . ' - the keys are unchanged, an untagged ref IS an api slug (3.4)';
}

# The 5.2 scans, over the parts of the grammar that hold arbitrary data.
# Everything else is closed by construction and needs no scan - and
# `profiles.<p>.secrets.providers` IS NOT SCANNED, because a provider
# block legitimately carries an `auth` sub-map.
#
# Collects rather than throws - validate_config owns the throw order.
sub _scan_config {
    my ($cfg) = @_;
    my ( @secrets, @reserved, @invalid );

    my $profiles =
      _ismap($cfg) && _ismap( $cfg->{profiles} ) ? $cfg->{profiles} : {};
    for my $pname ( mapkeys($profiles) ) {
        my $prof = $profiles->{$pname};
        next unless _ismap($prof);
        my $ppath = 'profiles.' . $pname;

        _checkfeatures( $prof->{feature}, $ppath . '.feature',
            \@secrets, \@reserved, \@invalid );

        for my $bkey ( 'api', 'sdk' ) {
            next unless _ismap( $prof->{$bkey} );
            for my $ref ( mapkeys( $prof->{$bkey} ) ) {
                my $block = $prof->{$bkey}{$ref};
                next unless _ismap($block);
                my $bpath = $ppath . '.' . $bkey . '.' . $ref;

                # The block's own `secret` holds a NAME. resolve_profile
                # checks it again per instance (station_secret_name);
                # this catches it at open(), for the whole file at once.
                if ( exists $block->{secret} ) {
                    _secretvalue( $block->{secret}, $bpath . '.secret', \@secrets );
                }

                # `options` is passthrough to a generated constructor,
                # so it is the one place a value can hide.
                _scan( $block->{options}, $bpath . '.options', \@secrets, \@reserved );
                _checkfeatures( $block->{feature}, $bpath . '.feature',
                    \@secrets, \@reserved, \@invalid );

                # 4.4's explicit checks, applied where the shape cannot
                # reach, raising the same code the shape would.
                _checkpolicy( $block->{policy}, $bpath . '.policy', \@invalid );
            }
        }
    }

    return ( \@secrets, \@reserved, \@invalid );
}

# A feature map at any level. `station` is reserved: station composes
# its own wrap, and a config that reconfigures it is asking for a state
# the ordering rules cannot express (8.4) - a config file that can
# switch off the component reading it is not a surface, it is a trap.
sub _checkfeatures {
    my ( $f, $path, $secrets, $reserved, $invalid ) = @_;
    return unless _ismap($f);

    for my $name ( mapkeys($f) ) {
        my $fpath = $path . '.' . $name;
        if ( 'station' eq $name ) {
            push @$reserved,
                $path
              . '.station is reserved: station composes its own wrap and it '
              . 'cannot be configured from station.json';
        }
        my $entry = $f->{$name};
        my $order = _ismap($entry) ? $entry->{order} : undef;
        if ( _ismap($order) ) {
            _firstelement( $order->{before}, $fpath . '.order.before', $invalid );
            _firstelement( $order->{after},  $fpath . '.order.after',  $invalid );
        }
        _scan( $entry, $fpath, $secrets, $reserved );
    }
    return;
}

# The policy block's 4.4 workarounds, in one place because they are one
# class of gap: struct cannot check what its own defects hide.
#
#  - `hosts`, `allow.op` and `allow.method` are `$CHILD` string lists,
#    so element 0 escapes the shape (see _firstelement below).
#  - `budget` is a map whose keys are ALL optional scalars, and struct
#    removes an unsatisfied optional key from the spec node - so
#    `budget: {rp: 1}` degenerates the spec into an open map and the
#    typo passes. `allow` does not have this problem (its `$CHILD` keys
#    stay in the spec whether or not the data carries them), and neither
#    does `policy` itself (`hosts` anchors it).
my %BUDGET_KEY = ( concurrency => 1, rps => 1 );

sub _checkpolicy {
    my ( $policy, $path, $invalid ) = @_;
    return unless _ismap($policy);

    _firstelement( $policy->{hosts}, $path . '.hosts', $invalid );

    my $allow = $policy->{allow};
    if ( _ismap($allow) ) {
        _firstelement( $allow->{op},     $path . '.allow.op',     $invalid );
        _firstelement( $allow->{method}, $path . '.allow.method', $invalid );
    }

    my $budget = $policy->{budget};
    if ( _ismap($budget) ) {
        my @unknown = sort grep { !$BUDGET_KEY{$_} } keys %$budget;
        push @$invalid,
          'Unexpected keys at field ' . $path . '.budget: ' . join( ', ', @unknown )
          if @unknown;
    }
    return;
}

# 4.4: `$CHILD` in LIST mode DOES NOT VALIDATE ELEMENT 0 - `["a", 1]`
# fails at index 1, `[1]` passes, at any list length. Filed upstream as
# voxgig/struct#113. It reaches THREE string lists in this shape:
# `policy.hosts`, and the per-feature `order.before` / `order.after`.
# Applied where the shape cannot reach, raising the same code the shape
# would, and PINNED IN THE CORPUS so the workaround is removed
# deliberately when struct is fixed rather than forgotten.
sub _firstelement {
    my ( $list, $path, $invalid ) = @_;
    return unless _islist($list) && @$list;
    my $first = $list->[0];
    return if 'string' eq _kindof($first);
    push @$invalid,
        'Expected field ' 
      . $path
      . '.0 to be string, but found '
      . _kindof($first) . ': '
      . Voxgig::Station::Descriptor::canonical_serialize($first);
    return;
}

# Recursive over EVERY nested map and list, not just the top level - a
# credential one level down is the case a top-level scan misses.
sub _scan {
    my ( $node, $path, $secrets, $reserved ) = @_;

    if ( _islist($node) ) {
        for my $i ( 0 .. $#$node ) {
            _scan( $node->[$i], $path . '.' . $i, $secrets, $reserved );
        }
        return;
    }
    if ( _isstr($node) ) {
        _userinfo( $node, $path, $secrets );
        return;
    }
    return unless _ismap($node);

    for my $key ( mapkeys($node) ) {
        my $kpath = $path . '.' . $key;
        my $val   = $node->{$key};

        # 8.6: station owns feature composition, so an `options.feature`
        # in a declarative config is a second, unreconciled ordering
        # input - two representations of one setting resolved
        # differently by sixteen ports.
        if ( 'feature' eq $key ) {
            push @$reserved,
                $kpath
              . ' is reserved: configure features under the block\'s own '
              . '`feature` key, not through `options`';
            next;
        }

        if ( 'secret' eq lc $key ) {
            _secretvalue( $val, $kpath, $secrets );
            next;
        }

        if ( _credentialkey($key) ) {
            push @$secrets,
                $kpath
              . ' is a credential-shaped key: station.json holds secret '
              . 'NAMES, never values (5.2)';
            next;
        }

        _scan( $val, $kpath, $secrets, $reserved );
    }
    return;
}

sub _credentialkey {
    my ($key) = @_;
    my $low = lc( defined $key ? "$key" : '' );
    $low =~ s/[^a-z0-9]+//g;
    return 1 if $CREDENTIAL_KEY{$low};
    my $token = Voxgig::Station::Descriptor::envtoken($key);
    for my $suffix (@CREDENTIAL_SUFFIX) {
        return 1
          if length($token) >= length($suffix)
          && $suffix eq substr( $token, -length($suffix) );
    }
    return 0;
}

# A `secret`-named key holds a NAME, and that exemption is not a
# loophole - it is the whole design, since a blanket deny would reject
# the very mechanism that keeps values out of the file. THREE checks,
# first failure wins, and they live in the same handful of lines
# precisely so a port cannot implement only the first and inherit the
# gap the others close.
sub _secretvalue {
    my ( $val, $path, $secrets ) = @_;

    if ( !_isstr($val) ) {
        push @$secrets,
          $path . ' must be a secret name (a string), but found ' . _kindof($val);
        return;
    }
    if ( !Voxgig::Sekreto::validname($val) ) {
        push @$secrets,
            $path
          . ' is not a valid sekreto name, so it cannot be a name and must '
          . 'not be a value: '
          . Voxgig::Station::Descriptor::canonical_serialize($val);
        return;
    }
    if ( $val =~ /[A-Za-z0-9]{$RUN_BOUND,}/ ) {
        push @$secrets,
            $path
          . ' contains an unbroken alphanumeric run of '
          . $RUN_BOUND
          . ' or more characters, which is not a name anybody writes';
    }
    return;
}

# One rule about VALUES rather than keys, because the `proxy` feature
# makes it concrete: `http://user:pass@proxy.internal:8080`. A parse
# failure is not an error - it returns silently.
sub _userinfo {
    my ( $val, $path, $secrets ) = @_;
    return unless $val =~ m{^[a-zA-Z][a-zA-Z0-9+.-]*://(.*)$};
    my $rest = $1;
    my ($authority) = $rest =~ m{^([^/?#]*)};
    return unless defined $authority;
    my $at = rindex( $authority, '@' );
    return if 0 >= $at;
    push @$secrets,
        $path
      . ' is a URL carrying userinfo, which puts a credential in the config '
      . 'file; use the proxy feature\'s `fromEnv` option instead (8.6)';
    return;
}

# THE SHAPE kindof, which must agree with struct's own spellings - NOT
# the feature checker's (Voxgig::Station::Feature has that one, and
# unifying the two would make one of them wrong).
#
# Perl scalars are untyped ('5' and 5 are indistinguishable by eye), so
# the number test leans on JSON::PP's SV-flag encoding, exactly as the
# canonical serializer does, rather than guessing from a string.
my $SCALAR_JSON = JSON::PP->new->allow_nonref(1)->allow_blessed(1)->convert_blessed(1);

sub _kindof {
    my ($val) = @_;
    return 'null' if !defined $val;
    return 'boolean' if JSON::PP::is_bool($val);
    my $r = ref $val;
    return 'list'   if 'ARRAY' eq $r;
    return 'object' if 'HASH' eq $r;
    return 'object' if '' ne $r;

    my $enc = eval { $SCALAR_JSON->encode($val) };
    return 'string' unless defined $enc;
    return 'integer' if $enc =~ /^-?\d+$/;
    return 'decimal' if $enc =~ /^-?[0-9][0-9.eE+-]*$/;
    return 'string';
}

1;
