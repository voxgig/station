package StationTestLoadable;

# A fixture for the loader (design station.md 6.3) path 1: a package that
# SELF-REGISTERS when it is loaded, which is what a generated package
# does and what makes `api.<slug>.package` close the loop.

use strict;
use warnings;

my $CONFIG = {
    main => {
        name    => 'Loadable',
        slug    => 'loadable',
        version => '0.0.1',
        target  => 'perl',
    },
    feature => {},
    options => { auth => { prefix => 'Bearer' } },
    entity  => {},
};

# The `config` singleton, as a sub - the spelling a generated perl
# package uses, and the first one factory_from_module looks for.
sub config { return $CONFIG }

{

    package StationTestLoadable::SDK;

    sub new {
        my ( $class, $options ) = @_;
        return bless { options => $options, features => [] }, $class;
    }
}

Voxgig::Station::Factory::provide(
    'loadable',
    {
        construct => sub { return StationTestLoadable::SDK->new( $_[0] ) },
        config    => $CONFIG,
    }
);

1;
