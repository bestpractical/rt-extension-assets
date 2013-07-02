use strict;
use warnings;

package RT::Assets;
use base 'RT::SearchBuilder';

use Role::Basic "with";
with "RT::SearchBuilder::Role::Roles";

use Scalar::Util qw/blessed/;

=head1 NAME

RT::Assets - a collection of L<RT::Asset> objects

=head1 METHODS

Only additional methods or overridden behaviour beyond the L<RT::SearchBuilder>
(itself a L<DBIx::SearchBuilder>) class are documented below.

=head2 LimitToActiveStatus

=cut

sub LimitToActiveStatus {
    my $self = shift;

    $self->Limit( FIELD => 'Status', VALUE => $_ )
        for RT::Catalog->LifecycleObj->Valid('initial', 'active');
}

=head2 Limit

Defaults CASESENSITIVE to 0

=cut

sub Limit {
    my $self = shift;
    my %args = (
        CASESENSITIVE => 0,
        @_
    );
    $self->SUPER::Limit(%args);
}

=head1 INTERNAL METHODS

Public methods which encapsulate implementation details.  You shouldn't need to
call these in normal code.

=head2 AddRecord

Checks the L<RT::Asset> is readable before adding it to the results

=cut

sub AddRecord {
    my $self  = shift;
    my $asset = shift;
    return unless $asset->CurrentUserCanSee;

    return if $asset->__Value('Status') eq 'deleted'
        and not $self->{'allow_deleted_search'};

    $self->SUPER::AddRecord($asset, @_);
}

=cut

=head2 NewItem

Returns a new empty RT::Asset item

=cut

sub NewItem {
    my $self = shift;
    return RT::Asset->new( $self->CurrentUser );
}

=head1 PRIVATE METHODS

=head2 _Init

Sets default ordering by Name ascending.

=cut

sub _Init {
    my $self = shift;

    $self->OrderBy( FIELD => 'Name', ORDER => 'ASC' );
    return $self->SUPER::_Init( @_ );
}

sub SimpleSearch {
    my $self = shift;
    my %args = (
        Fields      => RT->Config->Get('AssetSearchFields'),
        Catalog     => RT->Config->Get('DefaultCatalog'),
        Term        => undef,
        @_
    );

    # XXX: We only search a single catalog so that we can map CF names
    # to their ids, as searching CFs by CF name is rather complicated
    # and currently fails in odd ways.  Such a mapping obviously assumes
    # that names are unique within the catalog, but ids are also
    # allowable as well.
    my %cfs;
    my $catalog = RT::Catalog->new( $self->CurrentUser );
    $catalog->Load( $args{Catalog} );
    my $cfs = $catalog->AssetCustomFields;
    while (my $customfield = $cfs->Next) {
        $cfs{$customfield->id} = $cfs{$customfield->Name}
            = $customfield;
    }

    $self->Limit( FIELD => 'Catalog', VALUE => $catalog->id );

    while (my ($name, $op) = each %{$args{Fields}}) {
        $op = 'STARTSWITH'
            unless $op =~ /^(?:LIKE|(?:START|END)SWITH|=|!=)$/i;

        if ($name =~ /^CF\.(?:\{(.*)}|(.*))$/) {
            my $cfname = $1 || $2;
            $self->LimitCustomField(
                CUSTOMFIELD     => $cfs{$cfname},
                OPERATOR        => $op,
                VALUE           => $args{Term},
                ENTRYAGGREGATOR => 'OR',
                SUBCLAUSE       => 'autocomplete',
            ) if $cfs{$cfname};
        } elsif ($name eq 'id' and $op =~ /(?:LIKE|(?:START|END)SWITH)$/i) {
            $self->Limit(
                FUNCTION        => "CAST( main.$name AS TEXT )",
                OPERATOR        => $op,
                VALUE           => $args{Term},
                ENTRYAGGREGATOR => 'OR',
                SUBCLAUSE       => 'autocomplete',
            ) if $args{Term} =~ /^\d+$/;
        } else {
            $self->Limit(
                FIELD           => $name,
                OPERATOR        => $op,
                VALUE           => $args{Term},
                ENTRYAGGREGATOR => 'OR',
                SUBCLAUSE       => 'autocomplete',
            );
        }
    }
    return $self;
}

sub OrderByCols {
    my $self = shift;
    my @res  = ();
    for my $row (@_) {
        if ( blessed($row->{FIELD}) and $row->{FIELD}->isa("RT::CustomField") ) {
            push @res, $self->_OrderByCF( $row, $row->{FIELD} );
        } else {
            push @res, $row;
       }
    }
    return $self->SUPER::OrderByCols( @res );
}

=head2 _DoSearch

=head2 _DoCount

Limits to non-deleted assets unless the C<allow_deleted_search> flag is set.

=cut

sub _DoSearch {
    my $self = shift;
    $self->Limit( FIELD => 'Status', OPERATOR => '!=', VALUE => 'deleted', SUBCLAUSE => "not_deleted" )
        unless $self->{'allow_deleted_search'};
    $self->SUPER::_DoSearch(@_);
}

sub _DoCount {
    my $self = shift;
    $self->Limit( FIELD => 'Status', OPERATOR => '!=', VALUE => 'deleted', SUBCLAUSE => "not_deleted" )
        unless $self->{'allow_deleted_search'};
    $self->SUPER::_DoCount(@_);
}

sub Table { "RTxAssets" }

RT::Base->_ImportOverlays();

1;
