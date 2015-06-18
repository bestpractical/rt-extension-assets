# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2014 Best Practical Solutions, LLC
#                                          <sales@bestpractical.com>
#
# (Except where explicitly superseded by other copyright notices)
#
#
# LICENSE:
#
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
#
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
#
#
# CONTRIBUTION SUBMISSION POLICY:
#
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
#
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
#
# END BPS TAGGED BLOCK }}}

use strict;
use warnings;

package RT::Assets;
use base 'RT::SearchBuilder';

use Role::Basic "with";
with "RT::SearchBuilder::Role::Roles" => { -rename => {RoleLimit => '_RoleLimit'}};

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

=head2 LimitCatalog

Limit Catalog

=cut

sub LimitCatalog {
    my $self = shift;
    my %args = (
        FIELD    => 'Catalog',
        OPERATOR => '=',
        @_
    );

    if ( $args{OPERATOR} eq '=' ) {
        $self->{Catalog} = $args{VALUE};
    }
    $self->SUPER::Limit(%args);
}

=head2 RoleLimit

Re-uses the underlying JOIN, if possible.

=cut

sub RoleLimit {
    my $self = shift;
    my %args = (
        TYPE => '',
        SUBCLAUSE => '',
        OPERATOR => '=',
        @_
    );

    my $key = "role-join-".join("-",map {$args{$_}//''} qw/SUBCLAUSE TYPE OPERATOR/);
    my @ret = $self->_RoleLimit(%args, BUNDLE => $self->{$key} );
    $self->{$key} = \@ret;
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
    $self->{'table'}                   = "RTxAssets";
    $self->{'RecalcAssetLimits'}      = 1;
    $self->{'restriction_index'}       = 1;
    $self->{'primary_key'}             = "id";
    delete $self->{'items_array'};
    delete $self->{'item_map'};
    delete $self->{'columns_to_display'};
    $self->OrderBy( FIELD => 'Name', ORDER => 'ASC' );

    $self->SUPER::_Init(@_);

    $self->_InitSQL();
}

sub _InitSQL {
    my $self = shift;
    # Private Member Variables (which should get cleaned)
    $self->{'_sql_cf_alias'}  = undef;
    $self->{'_sql_object_cfv_alias'}  = undef;
    $self->{'_sql_watcher_join_users_alias'} = undef;
    $self->{'_sql_query'}         = '';
    $self->{'_sql_looking_at'}    = {};
}

sub Count {
    my $self = shift;
    $self->_ProcessRestrictions() if ( $self->{'RecalcAssetLimits'} == 1 );
    return ( $self->SUPER::Count() );
}

sub CountAll {
    my $self = shift;
    $self->_ProcessRestrictions() if ( $self->{'RecalcAssetLimits'} == 1 );
    return ( $self->SUPER::CountAll() );
}

=head2 ItemsArrayRef

Returns a reference to the set of all items found in this search

=cut

sub ItemsArrayRef {
    my $self = shift;

    return $self->{'items_array'} if $self->{'items_array'};

    my $placeholder = $self->_ItemsCounter;
    $self->GotoFirstItem();
    while ( my $item = $self->Next ) {
        push( @{ $self->{'items_array'} }, $item );
    }
    $self->GotoItem($placeholder);
    $self->{'items_array'} ||= [];
    $self->{'items_array'}
        = $self->ItemsOrderBy( $self->{'items_array'} );

    return $self->{'items_array'};
}

sub ItemsArrayRefWindow {
    my $self = shift;
    my $window = shift;

    my @old = ($self->_ItemsCounter, $self->RowsPerPage, $self->FirstRow+1);

    $self->RowsPerPage( $window );
    $self->FirstRow(1);
    $self->GotoFirstItem;

    my @res;
    while ( my $item = $self->Next ) {
        push @res, $item;
    }

    $self->RowsPerPage( $old[1] );
    $self->FirstRow( $old[2] );
    $self->GotoItem( $old[0] );

    return \@res;
}


sub Next {
    my $self = shift;

    $self->_ProcessRestrictions() if ( $self->{'RecalcAssetLimits'} == 1 );

    my $Asset = $self->SUPER::Next;
    return $Asset unless $Asset;

    if ( $Asset->__Value('Status') eq 'deleted'
        && !$self->{'allow_deleted_search'} )
    {
        return $self->Next;
    }
    elsif ( RT->Config->Get('UseSQLForACLChecks') ) {
        # if we found an asset with this option enabled then
        # all assets we found are ACLed, cache this fact
        my $key = join ";:;", $self->CurrentUser->id, 'ShowAsset', 'RT::Asset-'. $Asset->id;
        $RT::Principal::_ACL_CACHE->{ $key } = 1;
        return $Asset;
    }
    elsif ( $Asset->CurrentUserHasRight('ShowAsset') ) {
        # has rights
        return $Asset;
    }
    else {
        # If the user doesn't have the right to show this asset
        return $self->Next;
    }
}

sub _DoSearch {
    my $self = shift;
    $self->Limit( FIELD => 'Status', OPERATOR => '!=', VALUE => 'deleted', SUBCLAUSE => "not_deleted" )
      unless $self->{ 'allow_deleted_search' };
    $self->CurrentUserCanSee if RT->Config->Get('UseSQLForACLChecks');
    return $self->SUPER::_DoSearch( @_ );
}

sub _DoCount {
    my $self = shift;
    $self->Limit( FIELD => 'Status', OPERATOR => '!=', VALUE => 'deleted', SUBCLAUSE => "not_deleted" )
      unless $self->{ 'allow_deleted_search' };
    $self->CurrentUserCanSee if RT->Config->Get('UseSQLForACLChecks');
    return $self->SUPER::_DoCount( @_ );
}

sub _RolesCanSee {
    my $self = shift;

    my $cache_key = 'RolesHasRight;:;ShowAsset';

    if ( my $cached = $RT::Principal::_ACL_CACHE->{ $cache_key } ) {
        return %$cached;
    }

    my $ACL = RT::ACL->new( RT->SystemUser );
    $ACL->Limit( FIELD => 'RightName', VALUE => 'ShowAsset' );
    $ACL->Limit( FIELD => 'PrincipalType', OPERATOR => '!=', VALUE => 'Group' );
    my $principal_alias = $ACL->Join(
        ALIAS1 => 'main',
        FIELD1 => 'PrincipalId',
        TABLE2 => 'Principals',
        FIELD2 => 'id',
    );
    $ACL->Limit( ALIAS => $principal_alias, FIELD => 'Disabled', VALUE => 0 );

    my %res = ();
    foreach my $ACE ( @{ $ACL->ItemsArrayRef } ) {
        my $role = $ACE->__Value('PrincipalType');
        my $type = $ACE->__Value('ObjectType');
        if ( $type eq 'RT::System' ) {
            $res{ $role } = 1;
        }
        elsif ( $type eq 'RT::Catalog' ) {
            next if $res{ $role } && !ref $res{ $role };
            push @{ $res{ $role } ||= [] }, $ACE->__Value('ObjectId');
        }
        else {
            $RT::Logger->error('ShowAsset right is granted on unsupported object');
        }
    }
    $RT::Principal::_ACL_CACHE->{ $cache_key } = \%res;
    return %res;
}

sub _DirectlyCanSeeIn {
    my $self = shift;
    my $id = $self->CurrentUser->id;

    my $cache_key = 'User-'. $id .';:;ShowAsset;:;DirectlyCanSeeIn';
    if ( my $cached = $RT::Principal::_ACL_CACHE->{ $cache_key } ) {
        return @$cached;
    }

    my $ACL = RT::ACL->new( RT->SystemUser );
    $ACL->Limit( FIELD => 'RightName', VALUE => 'ShowAsset' );
    my $principal_alias = $ACL->Join(
        ALIAS1 => 'main',
        FIELD1 => 'PrincipalId',
        TABLE2 => 'Principals',
        FIELD2 => 'id',
    );
    $ACL->Limit( ALIAS => $principal_alias, FIELD => 'Disabled', VALUE => 0 );
    my $cgm_alias = $ACL->Join(
        ALIAS1 => 'main',
        FIELD1 => 'PrincipalId',
        TABLE2 => 'CachedGroupMembers',
        FIELD2 => 'GroupId',
    );
    $ACL->Limit( ALIAS => $cgm_alias, FIELD => 'MemberId', VALUE => $id );
    $ACL->Limit( ALIAS => $cgm_alias, FIELD => 'Disabled', VALUE => 0 );

    my @res = ();
    foreach my $ACE ( @{ $ACL->ItemsArrayRef } ) {
        my $type = $ACE->__Value('ObjectType');
        if ( $type eq 'RT::System' ) {
            # If user is direct member of a group that has the right
            # on the system then he can see any asset
            $RT::Principal::_ACL_CACHE->{ $cache_key } = [-1];
            return (-1);
        }
        elsif ( $type eq 'RT::Catalog' ) {
            push @res, $ACE->__Value('ObjectId');
        }
        else {
            $RT::Logger->error('ShowAsset right is granted on unsupported object');
        }
    }
    $RT::Principal::_ACL_CACHE->{ $cache_key } = \@res;
    return @res;
}

sub CurrentUserCanSee {
    my $self = shift;
    return if $self->{'_sql_current_user_can_see_applied'};

    return $self->{'_sql_current_user_can_see_applied'} = 1
        if $self->CurrentUser->UserObj->HasRight(
            Right => 'SuperUser', Object => $RT::System
        );

    local $self->{using_restrictions};

    my $id = $self->CurrentUser->id;

    # directly can see in all catalogs then we have nothing to do
    my @direct_catalogs = $self->_DirectlyCanSeeIn;
    return $self->{'_sql_current_user_can_see_applied'} = 1
        if @direct_catalogs && $direct_catalogs[0] == -1;

    my %roles = $self->_RolesCanSee;
    {
        my %skip = map { $_ => 1 } @direct_catalogs;
        foreach my $role ( keys %roles ) {
            next unless ref $roles{ $role };

            my @catalogs = grep !$skip{$_}, @{ $roles{ $role } };
            if ( @catalogs ) {
                $roles{ $role } = \@catalogs;
            } else {
                delete $roles{ $role };
            }
        }
    }

# there is no global watchers, only catalogs and tickes, if at
# some point we will add global roles then it's gonna blow
# the idea here is that if the right is set globaly for a role
# and user plays this role for a catalog directly not a ticket
# then we have to check in advance
    if ( my @tmp = grep $_ ne 'Owner' && !ref $roles{ $_ }, keys %roles ) {

        my $groups = RT::Groups->new( RT->SystemUser );
        $groups->Limit( FIELD => 'Domain', VALUE => 'RT::Catalog-Role', CASESENSITIVE => 0 );
        $groups->Limit(
            FIELD         => 'Name',
            FUNCTION      => 'LOWER(?)',
            OPERATOR      => 'IN',
            VALUE         => [ map {lc $_} @tmp ],
            CASESENSITIVE => 1,
        );
        my $principal_alias = $groups->Join(
            ALIAS1 => 'main',
            FIELD1 => 'id',
            TABLE2 => 'Principals',
            FIELD2 => 'id',
        );
        $groups->Limit( ALIAS => $principal_alias, FIELD => 'Disabled', VALUE => 0 );
        my $cgm_alias = $groups->Join(
            ALIAS1 => 'main',
            FIELD1 => 'id',
            TABLE2 => 'CachedGroupMembers',
            FIELD2 => 'GroupId',
        );
        $groups->Limit( ALIAS => $cgm_alias, FIELD => 'MemberId', VALUE => $id );
        $groups->Limit( ALIAS => $cgm_alias, FIELD => 'Disabled', VALUE => 0 );
        while ( my $group = $groups->Next ) {
            push @direct_catalogs, $group->Instance;
        }
    }

    unless ( @direct_catalogs || keys %roles ) {
        $self->Limit(
            SUBCLAUSE => 'ACL',
            ALIAS => 'main',
            FIELD => 'id',
            VALUE => 0,
            ENTRYAGGREGATOR => 'AND',
        );
        return $self->{'_sql_current_user_can_see_applied'} = 1;
    }

    {
        my $join_roles = keys %roles;
        $join_roles = 0 if $join_roles == 1 && $roles{'Owner'};
        my ($role_group_alias, $cgm_alias);
        if ( $join_roles ) {
            $role_group_alias = $self->_RoleGroupsJoin( New => 1 );
            $cgm_alias = $self->_GroupMembersJoin( GroupsAlias => $role_group_alias );
            $self->Limit(
                LEFTJOIN   => $cgm_alias,
                FIELD      => 'MemberId',
                OPERATOR   => '=',
                VALUE      => $id,
            );
        }
        my $limit_catalogs = sub {
            my $ea = shift;
            my @catalogs = @_;

            return unless @catalogs;
            $self->Limit(
                SUBCLAUSE       => 'ACL',
                ALIAS           => 'main',
                FIELD           => 'Catalog',
                OPERATOR        => 'IN',
                VALUE           => [ @catalogs ],
                ENTRYAGGREGATOR => $ea,
            );
            return 1;
        };

        $self->SUPER::_OpenParen('ACL');
        my $ea = 'AND';
        $ea = 'OR' if $limit_catalogs->( $ea, @direct_catalogs );
        while ( my ($role, $catalogs) = each %roles ) {
            $self->SUPER::_OpenParen('ACL');
            if ( $role eq 'Owner' ) {
                $self->Limit(
                    SUBCLAUSE => 'ACL',
                    FIELD           => 'Owner',
                    VALUE           => $id,
                    ENTRYAGGREGATOR => $ea,
                );
            }
            else {
                $self->Limit(
                    SUBCLAUSE       => 'ACL',
                    ALIAS           => $cgm_alias,
                    FIELD           => 'MemberId',
                    OPERATOR        => 'IS NOT',
                    VALUE           => 'NULL',
                    QUOTEVALUE      => 0,
                    ENTRYAGGREGATOR => $ea,
                );
                $self->Limit(
                    SUBCLAUSE       => 'ACL',
                    ALIAS           => $role_group_alias,
                    FIELD           => 'Name',
                    VALUE           => $role,
                    ENTRYAGGREGATOR => 'AND',
                    CASESENSITIVE   => 0,
                );
            }
            $limit_catalogs->( 'AND', @$catalogs ) if ref $catalogs;
            $ea = 'OR' if $ea eq 'AND';
            $self->SUPER::_CloseParen('ACL');
        }
        $self->SUPER::_CloseParen('ACL');
    }
    return $self->{'_sql_current_user_can_see_applied'} = 1;
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
    my $catalog;
    if (ref $args{Catalog}) {
        $catalog = $args{Catalog};
    } else {
        $catalog = RT::Catalog->new( $self->CurrentUser );
        $catalog->Load( $args{Catalog} );
    }

    my %cfs;
    my $cfs = $catalog->AssetCustomFields;
    while (my $customfield = $cfs->Next) {
        $cfs{$customfield->id} = $cfs{$customfield->Name}
            = $customfield;
    }

    $self->LimitCatalog( VALUE => $catalog->id );

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
            ) unless $args{Term} =~ /\D/ and $name eq 'id';
        }
    }
    return $self;
}

sub OrderByCols {
    my $self = shift;
    my @res  = ();

    my $class = $self->_RoleGroupClass;

    for my $row (@_) {
        if ($row->{FIELD} =~ /^CF\.(?:\{(.*)\}|(.*))$/) {
            my $name = $1 || $2;
            my $cf = RT::CustomField->new( $self->CurrentUser );
            $cf->LoadByNameAndCatalog(
                Name => $name,
                Catalog => $self->{'Catalog'},
            );
            if ( $cf->id ) {
                push @res, $self->_OrderByCF( $row, $cf->id, $cf );
            }
        } elsif ($row->{FIELD} =~ /^(\w+)(?:\.(\w+))?$/) {
            my ($role, $subkey) = ($1, $2);
            if ($class->HasRole($role)) {
                $self->{_order_by_role}{ $role }
                        ||= ( $self->_WatcherJoin( Name => $role, Class => $class) )[2];
                push @res, {
                    %$row,
                    ALIAS => $self->{_order_by_role}{ $role },
                    FIELD => $subkey || 'EmailAddress',
                };
            } else {
                push @res, $row;
            }
        } else {
            push @res, $row;
        }
    }
    return $self->SUPER::OrderByCols( @res );
}

sub _OpenParen {
    $_[0]->SUPER::_OpenParen( $_[1] || 'assetsql' );
}
sub _CloseParen {
    $_[0]->SUPER::_CloseParen( $_[1] || 'assetsql' );
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
    $self->{'must_redo_search'} = 1;
    delete $self->{'raw_rows'};
    delete $self->{'count_all'};

    if ($self->{'using_restrictions'}) {
        RT->Deprecated( Message => "Mixing old-style LimitFoo methods with Limit is deprecated" );
        $self->LimitField(@_);
    }

    $args{SUBCLAUSE} ||= "assetsql"
        if $self->{parsing_assetsql} and not $args{LEFTJOIN};

    $self->{_sql_looking_at}{ lc $args{FIELD} } = 1
        if $args{FIELD} and (not $args{ALIAS} or $args{ALIAS} eq "main");

    $self->SUPER::Limit(%args);
}


=head2 LimitField

Takes a paramhash with the fields FIELD, OPERATOR, VALUE and DESCRIPTION
Generally best called from LimitFoo methods

=cut

sub LimitField {
    my $self = shift;
    my %args = (
        FIELD       => undef,
        OPERATOR    => '=',
        VALUE       => undef,
        DESCRIPTION => undef,
        @_
    );
    $args{'DESCRIPTION'} = $self->loc(
        "[_1] [_2] [_3]",  $args{'FIELD'},
        $args{'OPERATOR'}, $args{'VALUE'}
        )
        if ( !defined $args{'DESCRIPTION'} );


    if ($self->_isLimited > 1) {
        RT->Deprecated( Message => "Mixing old-style LimitFoo methods with Limit is deprecated" );
    }
    $self->{using_restrictions} = 1;

    my $index = $self->_NextIndex;

# make the TicketRestrictions hash the equivalent of whatever we just passed in;

    %{ $self->{'TicketRestrictions'}{$index} } = %args;

    $self->{'RecalcTicketLimits'} = 1;

    return ($index);
}

sub Table { "RTxAssets" }

# Configuration Tables:

# FIELD_METADATA is a mapping of searchable Field name, to Type, and other
# metadata.

our %FIELD_METADATA = (
    id              => [ 'ID', ], #loc_left_pair
    Name             => [ 'STRING', ], #loc_left_pair
    Description      => [ 'STRING', ], #loc_left_pair
    Status          => [ 'STRING', ], #loc_left_pair
    Catalog         => [ 'ENUM' => 'Catalog', ], #loc_left_pair
    LastUpdated      => [ 'DATE'            => 'LastUpdated', ], #loc_left_pair
    Created          => [ 'DATE'            => 'Created', ], #loc_left_pair

    Linked          => [ 'LINK' ], #loc_left_pair
    LinkedTo        => [ 'LINK' => 'To' ], #loc_left_pair
    LinkedFrom      => [ 'LINK' => 'From' ], #loc_left_pair
    MemberOf        => [ 'LINK' => To => 'MemberOf', ], #loc_left_pair
    DependsOn       => [ 'LINK' => To => 'DependsOn', ], #loc_left_pair
    RefersTo        => [ 'LINK' => To => 'RefersTo', ], #loc_left_pair
    HasMember       => [ 'LINK' => From => 'MemberOf', ], #loc_left_pair
    DependentOn     => [ 'LINK' => From => 'DependsOn', ], #loc_left_pair
    DependedOnBy    => [ 'LINK' => From => 'DependsOn', ], #loc_left_pair
    ReferredToBy    => [ 'LINK' => From => 'RefersTo', ], #loc_left_pair

    Owner           => [ 'WATCHERFIELD' => 'Owner', ], #loc_left_pair
    OwnerGroup      => [ 'MEMBERSHIPFIELD' => 'Owner', ], #loc_left_pair
    HeldBy          => [ 'WATCHERFIELD' => 'HeldBy', ], #loc_left_pair
    HeldByGroup     => [ 'MEMBERSHIPFIELD' => 'HeldBy', ], #loc_left_pair
    Contact         => [ 'WATCHERFIELD' => 'Contact', ], #loc_left_pair
    ContactGroup    => [ 'MEMBERSHIPFIELD' => 'Contact', ], #loc_left_pair

    CustomFieldValue => [ 'CUSTOMFIELD' => 'Asset' ], #loc_left_pair
    CustomField      => [ 'CUSTOMFIELD' => 'Asset' ], #loc_left_pair
    CF               => [ 'CUSTOMFIELD' => 'Asset' ], #loc_left_pair
);

# Lower Case version of FIELDS, for case insensitivity
our %LOWER_CASE_FIELDS = map { ( lc($_) => $_ ) } (keys %FIELD_METADATA);

our %SEARCHABLE_SUBFIELDS = (
    User => [qw(
        EmailAddress Name RealName Nickname Organization Address1 Address2
        City State Zip Country WorkPhone HomePhone MobilePhone PagerPhone id
    )],
);

# Mapping of Field Type to Function
our %dispatch = (
    ENUM            => \&_EnumLimit,
    INT             => \&_IntLimit,
    ID              => \&_IdLimit,
    LINK            => \&_LinkLimit,
    DATE            => \&_DateLimit,
    STRING          => \&_StringLimit,
    WATCHERFIELD    => \&_WatcherLimit,
    MEMBERSHIPFIELD => \&_WatcherMembershipLimit,
    CUSTOMFIELD     => \&_CustomFieldLimit,
#    HASATTRIBUTE    => \&_HasAttributeLimit,
#    LIFECYCLE       => \&_LifecycleLimit,
);

# Default EntryAggregator per type
# if you specify OP, you must specify all valid OPs
my %DefaultEA = (
    INT  => 'AND',
    ENUM => {
        '='  => 'OR',
        '!=' => 'AND'
    },
    DATE => {
        'IS' => 'OR',
        'IS NOT' => 'OR',
        '='  => 'OR',
        '>=' => 'AND',
        '<=' => 'AND',
        '>'  => 'AND',
        '<'  => 'AND'
    },
    STRING => {
        '='        => 'OR',
        '!='       => 'AND',
        'LIKE'     => 'AND',
        'NOT LIKE' => 'AND'
    },
    LINK         => 'OR',
    LINKFIELD    => 'AND',
    TARGET       => 'AND',
    BASE         => 'AND',
    WATCHERFIELD => {
        '='        => 'OR',
        '!='       => 'AND',
        'LIKE'     => 'OR',
        'NOT LIKE' => 'AND'
    },

    HASATTRIBUTE => {
        '='        => 'AND',
        '!='       => 'AND',
    },

    CUSTOMFIELD => 'OR',
);

sub FIELDS     { return \%FIELD_METADATA }

our @SORTFIELDS = qw(id Name Status Catalog Owner Created LastUpdated );

=head2 SortFields

Returns the list of fields that lists of assets can easily be sorted by

=cut

sub SortFields {
    my $self = shift;
    return (@SORTFIELDS);
}


# BEGIN SQL STUFF *********************************


sub CleanSlate {
    my $self = shift;
    $self->SUPER::CleanSlate( @_ );
    delete $self->{$_} foreach qw(
        _sql_cf_alias
        _sql_group_members_aliases
        _sql_object_cfv_alias
        _sql_role_group_aliases
        _sql_u_watchers_alias_for_sort
        _sql_u_watchers_aliases
        _sql_current_user_can_see_applied
    );
}

=head1 Limit Helper Routines

These routines are the targets of a dispatch table depending on the
type of field.  They all share the same signature:

  my ($self,$field,$op,$value,@rest) = @_;

The values in @rest should be suitable for passing directly to
DBIx::SearchBuilder::Limit.

Essentially they are an expanded/broken out (and much simplified)
version of what ProcessRestrictions used to do.  They're also much
more clearly delineated by the TYPE of field being processed.

=head2 _IdLimit

Handle ID field.

=cut

sub _IdLimit {
    my ( $sb, $field, $op, $value, @rest ) = @_;
    return $sb->_IntLimit( $field, $op, $value, @rest );
}

=head2 _EnumLimit

Handle Fields which are limited to certain values, and potentially
need to be looked up from another class.

This subroutine actually handles two different kinds of fields.  For
some the user is responsible for limiting the values.  (i.e. Status,
Type).

For others, the value specified by the user will be looked by via
specified class.

Meta Data:
  name of class to lookup in (Optional)

=cut

sub _EnumLimit {
    my ( $sb, $field, $op, $value, @rest ) = @_;

    # SQL::Statement changes != to <>.  (Can we remove this now?)
    $op = "!=" if $op eq "<>";

    die "Invalid Operation: $op for $field"
        unless $op eq "="
        or $op     eq "!=";

    my $meta = $FIELD_METADATA{$field};
    if ( defined $meta->[1] && defined $value && $value !~ /^\d+$/ ) {
        my $class = "RT::" . $meta->[1];
        my $o     = $class->new( $sb->CurrentUser );
        $o->Load($value);
        $value = $o->Id || 0;
    }
    $sb->Limit(
        FIELD    => $field,
        VALUE    => $value,
        OPERATOR => $op,
        @rest,
    );
}

=head2 _IntLimit

Handle fields where the values are limited to integers.  (For example,
Priority, TimeWorked.)

Meta Data:
  None

=cut

sub _IntLimit {
    my ( $sb, $field, $op, $value, @rest ) = @_;

    my $is_a_like = $op =~ /MATCHES|ENDSWITH|STARTSWITH|LIKE/i;

    # We want to support <id LIKE '1%'> for asset autocomplete,
    # but we need to explicitly typecast on Postgres
    if ( $is_a_like && RT->Config->Get('DatabaseType') eq 'Pg' ) {
        return $sb->Limit(
            FUNCTION => "CAST(main.$field AS TEXT)",
            OPERATOR => $op,
            VALUE    => $value,
            @rest,
        );
    }

    $sb->Limit(
        FIELD    => $field,
        VALUE    => $value,
        OPERATOR => $op,
        @rest,
    );
}

=head2 _LinkLimit

Handle fields which deal with links between assets.  (MemberOf, DependsOn)

Meta Data:
  1: Direction (From, To)
  2: Link Type (MemberOf, DependsOn, RefersTo)

=cut

sub _LinkLimit {
    my ( $sb, $field, $op, $value, @rest ) = @_;

    my $meta = $FIELD_METADATA{$field};
    die "Invalid Operator $op for $field" unless $op =~ /^(=|!=|IS|IS NOT)$/io;

    my $is_negative = 0;
    if ( $op eq '!=' || $op =~ /\bNOT\b/i ) {
        $is_negative = 1;
    }
    my $is_null = 0;
    $is_null = 1 if !$value || $value =~ /^null$/io;

    my $direction = $meta->[1] || '';
    my ($matchfield, $linkfield) = ('', '');
    if ( $direction eq 'To' ) {
        ($matchfield, $linkfield) = ("Target", "Base");
    }
    elsif ( $direction eq 'From' ) {
        ($matchfield, $linkfield) = ("Base", "Target");
    }
    elsif ( $direction ) {
        die "Invalid link direction '$direction' for $field\n";
    } else {
        $sb->_OpenParen;
        $sb->_LinkLimit( 'LinkedTo', $op, $value, @rest );
        $sb->_LinkLimit(
            'LinkedFrom', $op, $value, @rest,
            ENTRYAGGREGATOR => (($is_negative && $is_null) || (!$is_null && !$is_negative))? 'OR': 'AND',
        );
        $sb->_CloseParen;
        return;
    }

    my $is_local = 1;
    if ( $is_null ) {
        $op = ($op =~ /^(=|IS)$/i)? 'IS': 'IS NOT';
    }
    elsif ( $value =~ /\D/ ) {
        $value = RT::URI->new( $sb->CurrentUser )->CanonicalizeURI( $value );
        $is_local = 0;
    }
    $matchfield = "Local$matchfield" if $is_local;

#For doing a left join to find "unlinked assets" we want to generate a query that looks like this
#    SELECT main.* FROM Assets main
#        LEFT JOIN Links Links_1 ON (     (Links_1.Type = 'MemberOf')
#                                      AND(main.id = Links_1.LocalTarget))
#        WHERE Links_1.LocalBase IS NULL;

    my $join_expression;
    if ( RT->Config->Get('DatabaseType') eq 'SQLite' ) {
        $join_expression = q{'} . RT::URI::asset->new( RT->SystemUser )->LocalURIPrefix . q{' ||  main.id};
    }
    else {
        $join_expression = q{CONCAT( '} . RT::URI::asset->new( RT->SystemUser )->LocalURIPrefix . q{',  main.id )};
    }
    if ( $is_null ) {
        my $linkalias = $sb->Join(
            TYPE   => 'LEFT',
            ALIAS1 => 'main',
            FIELD1 => 'id',
            TABLE2 => 'Links',
            FIELD2 => $linkfield,
            EXPRESSION => $join_expression,
        );
        $sb->Limit(
            LEFTJOIN => $linkalias,
            FIELD    => 'Type',
            OPERATOR => '=',
            VALUE    => $meta->[2],
        ) if $meta->[2];
        $sb->Limit(
            @rest,
            ALIAS      => $linkalias,
            FIELD      => $matchfield,
            OPERATOR   => $op,
            VALUE      => 'NULL',
            QUOTEVALUE => 0,
        );
    }
    else {
        my $linkalias = $sb->Join(
            TYPE   => 'LEFT',
            ALIAS1 => 'main',
            FIELD1 => 'id',
            TABLE2 => 'Links',
            FIELD2 => $linkfield,
            EXPRESSION => $join_expression,
        );
        $sb->Limit(
            LEFTJOIN => $linkalias,
            FIELD    => 'Type',
            OPERATOR => '=',
            VALUE    => $meta->[2],
        ) if $meta->[2];
        $sb->Limit(
            LEFTJOIN => $linkalias,
            FIELD    => $matchfield,
            OPERATOR => '=',
            VALUE    => $value,
        );
        $sb->Limit(
            @rest,
            ALIAS      => $linkalias,
            FIELD      => $matchfield,
            OPERATOR   => $is_negative? 'IS': 'IS NOT',
            VALUE      => 'NULL',
            QUOTEVALUE => 0,
        );
    }
}

=head2 _DateLimit

Handle date fields.  (Created, LastTold..)

Meta Data:
  1: type of link.  (Probably not necessary.)

=cut

sub _DateLimit {
    my ( $sb, $field, $op, $value, %rest ) = @_;

    die "Invalid Date Op: $op"
        unless $op =~ /^(=|>|<|>=|<=|IS(\s+NOT)?)$/i;

    my $meta = $FIELD_METADATA{$field};
    die "Incorrect Meta Data for $field"
        unless ( defined $meta->[1] );

    if ( $op =~ /^(IS(\s+NOT)?)$/i) {
        return $sb->Limit(
            FUNCTION => $sb->NotSetDateToNullFunction,
            FIELD    => $meta->[1],
            OPERATOR => $op,
            VALUE    => "NULL",
            %rest,
        );
    }

    if ( my $subkey = $rest{SUBKEY} ) {
        if ( $subkey eq 'DayOfWeek' && $op !~ /IS/i && $value =~ /[^0-9]/ ) {
            for ( my $i = 0; $i < @RT::Date::DAYS_OF_WEEK; $i++ ) {
                # Use a case-insensitive regex for better matching across
                # locales since we don't have fc() and lc() is worse.  Really
                # we should be doing Unicode normalization too, but we don't do
                # that elsewhere in RT.
                # 
                # XXX I18N: Replace the regex with fc() once we're guaranteed 5.16.
                next unless lc $RT::Date::DAYS_OF_WEEK[ $i ] eq lc $value
                         or $sb->CurrentUser->loc($RT::Date::DAYS_OF_WEEK[ $i ]) =~ /^\Q$value\E$/i;

                $value = $i; last;
            }
            return $sb->Limit( FIELD => 'id', VALUE => 0, %rest )
                if $value =~ /[^0-9]/;
        }
        elsif ( $subkey eq 'Month' && $op !~ /IS/i && $value =~ /[^0-9]/ ) {
            for ( my $i = 0; $i < @RT::Date::MONTHS; $i++ ) {
                # Use a case-insensitive regex for better matching across
                # locales since we don't have fc() and lc() is worse.  Really
                # we should be doing Unicode normalization too, but we don't do
                # that elsewhere in RT.
                # 
                # XXX I18N: Replace the regex with fc() once we're guaranteed 5.16.
                next unless lc $RT::Date::MONTHS[ $i ] eq lc $value
                         or $sb->CurrentUser->loc($RT::Date::MONTHS[ $i ]) =~ /^\Q$value\E$/i;

                $value = $i + 1; last;
            }
            return $sb->Limit( FIELD => 'id', VALUE => 0, %rest )
                if $value =~ /[^0-9]/;
        }

        my $tz;
        if ( RT->Config->Get('ChartsTimezonesInDB') ) {
            my $to = $sb->CurrentUser->UserObj->Timezone
                || RT->Config->Get('Timezone');
            $tz = { From => 'UTC', To => $to }
                if $to && lc $to ne 'utc';
        }

        # $subkey is validated by DateTimeFunction
        my $function = $RT::Handle->DateTimeFunction(
            Type     => $subkey,
            Field    => $sb->NotSetDateToNullFunction,
            Timezone => $tz,
        );

        return $sb->Limit(
            FUNCTION => $function,
            FIELD    => $meta->[1],
            OPERATOR => $op,
            VALUE    => $value,
            %rest,
        );
    }

    my $date = RT::Date->new( $sb->CurrentUser );
    $date->Set( Format => 'unknown', Value => $value );

    if ( $op eq "=" ) {

        # if we're specifying =, that means we want everything on a
        # particular single day.  in the database, we need to check for >
        # and < the edges of that day.

        $date->SetToMidnight( Timezone => 'server' );
        my $daystart = $date->ISO;
        $date->AddDay;
        my $dayend = $date->ISO;

        $sb->_OpenParen;

        $sb->Limit(
            FIELD    => $meta->[1],
            OPERATOR => ">=",
            VALUE    => $daystart,
            %rest,
        );

        $sb->Limit(
            FIELD    => $meta->[1],
            OPERATOR => "<",
            VALUE    => $dayend,
            %rest,
            ENTRYAGGREGATOR => 'AND',
        );

        $sb->_CloseParen;

    }
    else {
        $sb->Limit(
            FUNCTION => $sb->NotSetDateToNullFunction,
            FIELD    => $meta->[1],
            OPERATOR => $op,
            VALUE    => $date->ISO,
            %rest,
        );
    }
}

=head2 _StringLimit

Handle simple fields which are just strings.  (Subject,Type)

Meta Data:
  None

=cut

sub _StringLimit {
    my ( $sb, $field, $op, $value, @rest ) = @_;

    # FIXME:
    # Valid Operators:
    #  =, !=, LIKE, NOT LIKE
    if ( RT->Config->Get('DatabaseType') eq 'Oracle'
        && (!defined $value || !length $value)
        && lc($op) ne 'is' && lc($op) ne 'is not'
    ) {
        if ($op eq '!=' || $op =~ /^NOT\s/i) {
            $op = 'IS NOT';
        } else {
            $op = 'IS';
        }
        $value = 'NULL';
    }

    if ($field eq "Status") {
        $value = lc $value;
    }

    $sb->Limit(
        FIELD         => $field,
        OPERATOR      => $op,
        VALUE         => $value,
        CASESENSITIVE => 0,
        @rest,
    );
}

=head2 _WatcherLimit

Handle watcher limits.  (Requestor, CC, etc..)

Meta Data:
  1: Field to query on



=cut

sub _WatcherLimit {
    my $self  = shift;
    my $field = shift;
    my $op    = shift;
    my $value = shift;
    my %rest  = (@_);

    my $meta = $FIELD_METADATA{ $field };
    my $type = $meta->[1] || '';
    my $class = $meta->[2] || 'Asset';

    # Bail if the subfield is not allowed
    if (    $rest{SUBKEY}
        and not grep { $_ eq $rest{SUBKEY} } @{$SEARCHABLE_SUBFIELDS{'User'}})
    {
        die "Invalid watcher subfield: '$rest{SUBKEY}'";
    }

    $self->RoleLimit(
        TYPE      => $type,
        CLASS     => "RT::$class",
        FIELD     => $rest{SUBKEY},
        OPERATOR  => $op,
        VALUE     => $value,
        SUBCLAUSE => "assetsql",
        %rest,
    );
}

=head2 _WatcherMembershipLimit

Handle watcher membership limits, i.e. whether the watcher belongs to a
specific group or not.

Meta Data:
  1: Role to query on

=cut

sub _WatcherMembershipLimit {
    my ( $self, $field, $op, $value, %rest ) = @_;

    # we don't support anything but '='
    die "Invalid $field Op: $op"
        unless $op =~ /^=$/;

    unless ( $value =~ /^\d+$/ ) {
        my $group = RT::Group->new( $self->CurrentUser );
        $group->LoadUserDefinedGroup( $value );
        $value = $group->id || 0;
    }

    my $meta = $FIELD_METADATA{$field};
    my $type = $meta->[1] || '';

    my ($members_alias, $members_column);
    if ( $type eq 'Owner' ) {
        ($members_alias, $members_column) = ('main', 'Owner');
    } else {
        (undef, undef, $members_alias) = $self->_WatcherJoin( New => 1, Name => $type );
        $members_column = 'id';
    }

    my $cgm_alias = $self->Join(
        ALIAS1          => $members_alias,
        FIELD1          => $members_column,
        TABLE2          => 'CachedGroupMembers',
        FIELD2          => 'MemberId',
    );
    $self->Limit(
        LEFTJOIN => $cgm_alias,
        ALIAS => $cgm_alias,
        FIELD => 'Disabled',
        VALUE => 0,
    );

    $self->Limit(
        ALIAS    => $cgm_alias,
        FIELD    => 'GroupId',
        VALUE    => $value,
        OPERATOR => $op,
        %rest,
    );
}

=head2 _CustomFieldDecipher

Try and turn a CF descriptor into (cfid, cfname) object pair.

Takes an optional second parameter of the CF LookupType, defaults to Asset CFs.

=cut

sub _CustomFieldDecipher {
    my ($self, $string, $lookuptype) = @_;
    $lookuptype ||= $self->_SingularClass->CustomFieldLookupType;

    my ($object, $field, $column) = ($string =~ /^(?:(.+?)\.)?\{(.+)\}(?:\.(Content|LargeContent))?$/);
    $field ||= ($string =~ /^\{(.*?)\}$/)[0] || $string;

    my ($cf, $applied_to);

    if ( $object ) {
        my $record_class = RT::CustomField->RecordClassFromLookupType($lookuptype);
        $applied_to = $record_class->new( $self->CurrentUser );
        $applied_to->Load( $object );

        if ( $applied_to->id ) {
            RT->Logger->debug("Limiting to CFs identified by '$field' applied to $record_class #@{[$applied_to->id]} (loaded via '$object')");
        }
        else {
            RT->Logger->warning("$record_class '$object' doesn't exist, parsed from '$string'");
            $object = 0;
            undef $applied_to;
        }
    }

    if ( $field =~ /\D/ ) {
        $object ||= '';
        my $cfs = RT::CustomFields->new( $self->CurrentUser );
        $cfs->Limit( FIELD => 'Name', VALUE => $field, CASESENSITIVE => 0 );
        $cfs->LimitToLookupType($lookuptype);

        if ($applied_to) {
            $cfs->SetContextObject($applied_to);
            $cfs->LimitToObjectId($applied_to->id);
        }

        # if there is more then one field the current user can
        # see with the same name then we shouldn't return cf object
        # as we don't know which one to use
        $cf = $cfs->First;
        if ( $cf ) {
            $cf = undef if $cfs->Next;
        }
    }
    else {
        $cf = RT::CustomField->new( $self->CurrentUser );
        $cf->Load( $field );
        $cf->SetContextObject($applied_to)
            if $cf->id and $applied_to;
    }

    return ($object, $field, $cf, $column);
}

=head2 _CustomFieldLimit

Limit based on CustomFields

Meta Data:
  none

=cut

sub _CustomFieldLimit {
    my ( $self, $_field, $op, $value, %rest ) = @_;

    my $meta  = $FIELD_METADATA{ $_field };
    my $class = $meta->[1] || 'Asset';
    my $type  = "RT::$class"->CustomFieldLookupType;

    my $field = $rest{'SUBKEY'} || die "No field specified";

    # For our sanity, we can only limit on one object at a time

    my ($object, $cfid, $cf, $column);
    ($object, $field, $cf, $column) = $self->_CustomFieldDecipher( $field, $type );


    $self->_LimitCustomField(
        %rest,
        LOOKUPTYPE  => $type,
        CUSTOMFIELD => $cf || $field,
        KEY      => $cf ? $cf->id : "$type-$object.$field",
        OPERATOR => $op,
        VALUE    => $value,
        COLUMN   => $column,
        SUBCLAUSE => "assetsql",
    );
}

=head2 PrepForSerialization

You don't want to serialize a big assets object, as
the {items} hash will be instantly invalid _and_ eat
lots of space

=cut

sub PrepForSerialization {
    my $self = shift;
    delete $self->{'items'};
    delete $self->{'items_array'};
    $self->RedoSearch();
}

=head2 FromSQL

Convert a RT-SQL string into a set of SearchBuilder restrictions.

Returns (1, 'Status message') on success and (0, 'Error Message') on
failure.

=cut

sub _parser {
    my ($self,$string) = @_;
    my $ea = '';

    my %sub_tree;
    my $depth = 0;

    my %callback;
    $callback{'OpenParen'} = sub {
      $self->_OpenParen;
      $depth++;
      push @$_, '(' foreach values %sub_tree;
    };
    $callback{'CloseParen'} = sub {
      $self->_CloseParen;
      $depth--;
      foreach my $list ( values %sub_tree ) {
          if ( $list->[-1] eq '(' ) {
              pop @$list;
              pop @$list if $list->[-1] =~ /^(?:AND|OR)$/i;
          }
          else {
              pop @$list while $list->[-2] ne '(';
              $list->[-1] = pop @$list;
          }
      }
    };
    $callback{'EntryAggregator'} = sub {
      $ea = $_[0] || '';
      push @$_, $ea foreach grep @$_ && $_->[-1] ne '(', values %sub_tree;
    };
    $callback{'Condition'} = sub {
        my ($key, $op, $value) = @_;

        my $negative_op = ($op eq '!=' || $op =~ /\bNOT\b/i);
        my $null_op = ( 'is not' eq lc($op) || 'is' eq lc($op) );
        # key has dot then it's compound variant and we have subkey
        my $subkey = '';
        ($key, $subkey) = ($1, $2) if $key =~ /^([^\.]+)\.(.+)$/;

        # normalize key and get class (type)
        my $class;
        if (exists $LOWER_CASE_FIELDS{lc $key}) {
            $key = $LOWER_CASE_FIELDS{lc $key};
            $class = $FIELD_METADATA{$key}->[0];
        }
        die "Unknown field '$key' in '$string'" unless $class;

        # replace __CurrentUser__ with id
        $value = $self->CurrentUser->id if $value eq '__CurrentUser__';


        unless( $dispatch{ $class } ) {
            die "No dispatch method for class '$class'"
        }
        my $sub = $dispatch{ $class };

        my @res; my $bundle_with;
        if ( $class eq 'WATCHERFIELD' && $key ne 'Owner' && !$negative_op && (!$null_op || $subkey) ) {
            if ( !$sub_tree{$key} ) {
              $sub_tree{$key} = [ ('(')x$depth, \@res ];
            } else {
              $bundle_with = $self->_check_bundling_possibility( $string, @{ $sub_tree{$key} } );
              if ( $sub_tree{$key}[-1] eq '(' ) {
                    push @{ $sub_tree{$key} }, \@res;
              }
            }
        }

        # Remove our aggregator from subtrees where our condition didn't get added
        pop @$_ foreach grep @$_ && $_->[-1] =~ /^(?:AND|OR)$/i, values %sub_tree;

        # A reference to @res may be pushed onto $sub_tree{$key} from
        # above, and we fill it here.
        @res = $sub->( $self, $key, $op, $value,
                SUBCLAUSE       => '',  # don't need anymore
                ENTRYAGGREGATOR => $ea,
                SUBKEY          => $subkey,
                BUNDLE          => $bundle_with,
              );
        $ea = '';
    };
    RT::SQL::Parse($string, \%callback);
}

sub FromSQL {
    my ($self,$query) = @_;

    {
        # preserve first_row and show_rows across the CleanSlate
        local ($self->{'first_row'}, $self->{'show_rows'}, $self->{_sql_looking_at});
        $self->CleanSlate;
        $self->_InitSQL();
    }

    return (1, $self->loc("No Query")) unless $query;

    $self->{_sql_query} = $query;
    eval {
        local $self->{parsing_assetsql} = 1;
        $self->_parser( $query );
    };
    if ( $@ ) {
        my $error = "$@";
        $RT::Logger->error("Couldn't parse query: $error");
        return (0, $error);
    }

    # We don't want deleted tickets unless 'allow_deleted_search' is set
    unless( $self->{'allow_deleted_search'} ) {
        $self->Limit(
            FIELD    => 'Status',
            OPERATOR => '!=',
            VALUE => 'deleted',
        );
    }

    # set SB's dirty flag
    $self->{'must_redo_search'} = 1;
    $self->{'RecalcAssetLimits'} = 0;
    return (1, $self->loc("Valid Query"));
}

=head2 Query

Returns the last string passed to L</FromSQL>.

=cut

sub Query {
    my $self = shift;
    return $self->{_sql_query};
}

=head2 ClearRestrictions

Removes all restrictions irretrievably

=cut

sub ClearRestrictions {
    my $self = shift;
    delete $self->{'AssetRestrictions'};
    $self->{_sql_looking_at} = {};
    $self->{'RecalcAssetLimits'}      = 1;
}

# Convert a set of oldstyle SB Restrictions to Clauses for RQL

sub _RestrictionsToClauses {
    my $self = shift;

    my %clause;
    foreach my $row ( keys %{ $self->{'AssetRestrictions'} } ) {
        my $restriction = $self->{'AssetRestrictions'}{$row};

        # We need to reimplement the subclause aggregation that SearchBuilder does.
        # Default Subclause is ALIAS.FIELD, and default ALIAS is 'main',
        # Then SB AND's the different Subclauses together.

        # So, we want to group things into Subclauses, convert them to
        # SQL, and then join them with the appropriate DefaultEA.
        # Then join each subclause group with AND.

        my $field = $restriction->{'FIELD'};
        my $realfield = $field;    # CustomFields fake up a fieldname, so
                                   # we need to figure that out

        # One special case
        # Rewrite LinkedTo meta field to the real field
        if ( $field =~ /LinkedTo/ ) {
            $realfield = $field = $restriction->{'TYPE'};
        }

        # Two special case
        # Handle subkey fields with a different real field
        if ( $field =~ /^(\w+)\./ ) {
            $realfield = $1;
        }

        die "I don't know about $field yet"
            unless ( exists $FIELD_METADATA{$realfield}
                or $restriction->{CUSTOMFIELD} );

        my $type = $FIELD_METADATA{$realfield}->[0];
        my $op   = $restriction->{'OPERATOR'};

        my $value = (
            grep    {defined}
                map { $restriction->{$_} } qw(VALUE TICKET BASE TARGET)
        )[0];

        # this performs the moral equivalent of defined or/dor/C<//>,
        # without the short circuiting.You need to use a 'defined or'
        # type thing instead of just checking for truth values, because
        # VALUE could be 0.(i.e. "false")

        # You could also use this, but I find it less aesthetic:
        # (although it does short circuit)
        #( defined $restriction->{'VALUE'}? $restriction->{VALUE} :
        # defined $restriction->{'TICKET'} ?
        # $restriction->{TICKET} :
        # defined $restriction->{'BASE'} ?
        # $restriction->{BASE} :
        # defined $restriction->{'TARGET'} ?
        # $restriction->{TARGET} )

        my $ea = $restriction->{ENTRYAGGREGATOR}
            || $DefaultEA{$type}
            || "AND";
        if ( ref $ea ) {
            die "Invalid operator $op for $field ($type)"
                unless exists $ea->{$op};
            $ea = $ea->{$op};
        }

        # Each CustomField should be put into a different Clause so they
        # are ANDed together.
        if ( $restriction->{CUSTOMFIELD} ) {
            $realfield = $field;
        }

        exists $clause{$realfield} or $clause{$realfield} = [];

        # Escape Quotes
        $field =~ s!(['\\])!\\$1!g;
        $value =~ s!(['\\])!\\$1!g;
        my $data = [ $ea, $type, $field, $op, $value ];

        # here is where we store extra data, say if it's a keyword or
        # something.  (I.e. "TYPE SPECIFIC STUFF")

        if (lc $ea eq 'none') {
            $clause{$realfield} = [ $data ];
        } else {
            push @{ $clause{$realfield} }, $data;
        }
    }
    return \%clause;
}

=head2 ClausesToSQL

=cut

sub ClausesToSQL {
  my $self = shift;
  my $clauses = shift;
  my @sql;

  for my $f (keys %{$clauses}) {
    my $sql;
    my $first = 1;

    # Build SQL from the data hash
    for my $data ( @{ $clauses->{$f} } ) {
      $sql .= $data->[0] unless $first; $first=0; # ENTRYAGGREGATOR
      $sql .= " '". $data->[2] . "' ";            # FIELD
      $sql .= $data->[3] . " ";                   # OPERATOR
      $sql .= "'". $data->[4] . "' ";             # VALUE
    }

    push @sql, " ( " . $sql . " ) ";
  }

  return join("AND",@sql);
}

sub _ProcessRestrictions {
    my $self = shift;

    delete $self->{'items_array'};
    delete $self->{'item_map'};
    delete $self->{'raw_rows'};
    delete $self->{'count_all'};

    my $sql = $self->Query;
    if ( !$sql || $self->{'RecalcAssetLimits'} ) {

        local $self->{using_restrictions};
        #  "Restrictions to Clauses Branch\n";
        my $clauseRef = eval { $self->_RestrictionsToClauses; };
        if ($@) {
            $RT::Logger->error( "RestrictionsToClauses: " . $@ );
            $self->FromSQL("");
        }
        else {
            $sql = $self->ClausesToSQL($clauseRef);
            $self->FromSQL($sql) if $sql;
        }
    }

    $self->{'RecalcAssetLimits'} = 0;

}

sub _check_bundling_possibility {
    my $self = shift;
    my $string = shift;
    my @list = reverse @_;
    while (my $e = shift @list) {
        next if $e eq '(';
        if ( lc($e) eq 'and' ) {
            return undef;
        }
        elsif ( lc($e) eq 'or' ) {
            return shift @list;
        }
        else {
            # should not happen
            $RT::Logger->error(
                "Joins optimization failed when parsing '$string'. It's bug in RT, contact Best Practical"
            );
            die "Internal error. Contact your system administrator.";
        }
    }
    return undef;
}

RT::Base->_ImportOverlays();

1;
