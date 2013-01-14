use strict;
use warnings;

package RT::Catalogs;
use base 'RT::SearchBuilder';

=head1 NAME

RT::Catalogs - a collection of L<RT::Catalog> objects

=head1 METHODS

Only additional methods or overridden behaviour beyond the L<RT::SearchBuilder>
(itself a L<DBIx::SearchBuilder>) class are documented below.

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

Checks the L<RT::Catalog> is readable before adding it to the results

=cut

sub AddRecord {
    my $self    = shift;
    my $catalog = shift;
    return unless $catalog->CurrentUserCanSee;

    $self->SUPER::AddRecord($catalog, @_);
}

=cut

=head2 NewItem

Returns a new empty RT::Catalog item

=cut

sub NewItem {
    my $self = shift;
    return RT::Catalog->new( $self->CurrentUser );
}

=head1 PRIVATE METHODS

=head2 _Init

Sets default ordering by Name ascending.

=cut

sub _Init {
    my $self = shift;

    $self->{'with_disabled_column'} = 1;

    $self->OrderBy( FIELD => 'Name', ORDER => 'ASC' );
    return $self->SUPER::_Init( @_ );
}

sub Table { "RTxCatalogs" }

RT::Base->_ImportOverlays();

1;
