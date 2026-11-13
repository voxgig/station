package StationTestRetrofit;

# A fixture for the loader's RETROFIT path: a package whose SDK predates
# the station feature and self-registers nothing, so station builds the
# `{construct, config}` pair from its exports. It is not
# descriptor-blind - the `config` singleton sits beside the constructor.

use strict;
use warnings;

our $config = {
    main => {
        name    => 'Retrofit',
        slug    => 'retrofit',
        version => '0.0.1',
        target  => 'perl',
    },
    feature => {},
    options => { auth => { prefix => 'Bearer' } },
    entity  => {},
};

{

    package StationTestRetrofit::SDK;

    sub new {
        my ( $class, $options ) = @_;
        my $self = bless { mode => 'live', features => [], options => $options },
          $class;

        # A generated constructor runs its `extend` features; the carried
        # adapter is how the declarative path reaches a pre-station SDK.
        my $utility = { fetcher => sub { return ( {}, undef ) } };
        my $ctx     = {
            client  => $self,
            utility => $utility,
            options => $options,
            config  => $config,
        };
        # sdkgen's list form names its entries; a generated SDK reads them so.
        my $given = $options->{feature};
        my ($entry) =
          ref($given) eq 'ARRAY'
          ? grep { 'station' eq ( $_->{name} // '' ) } @$given
          : ( ( $given || {} )->{station} );
        for my $feature ( @{ $options->{extend} || [] } ) {
            push @{ $self->{features} }, $feature;
            $feature->init( $ctx, { %{ $entry || {} } } );
        }
        return $self;
    }
}

1;
