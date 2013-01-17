use strict;
use warnings;

package RT::Catalog;
use base 'RT::Record';

use Role::Basic 'with';
with "RT::Role::Record::Lifecycle",
     "RT::Role::Record::Roles" => {
         -rename => {
             # We provide ACL'd wraps of these.
             AddRoleMember    => "_AddRoleMember",
             DeleteRoleMember => "_DeleteRoleMember",
             RoleGroup        => "_RoleGroup",
         },
     };

=head1 NAME

RT::Catalog - A logical set of assets

=cut

# For the Lifecycle role
sub LifecycleType { "asset" }

# Setup rights
$RT::ACE::OBJECT_TYPES{'RT::Catalog'} = 1;

RT::Catalog->AddRights(
    ShowCatalog         => 'See catalogs',                          # loc_pair
    AdminCatalog        => 'Create, modify, and disable catalogs',  # loc_pair

    ShowAsset           => 'See assets',        # loc_pair
    CreateAsset         => 'Create assets',     # loc_pair
    ModifyAsset         => 'Modify assets',     # loc_pair
);
RT::Catalog->AddRightCategories(
    ShowCatalog     => 'Staff',
    AdminCatalog    => 'Admin',

    ShowAsset   => 'Staff',
    CreateAsset => 'Staff',
    ModifyAsset => 'Staff',
);

=head1 DESCRIPTION

Catalogs are for assets what queues are for tickets or classes are for
articles.

It announces the rights for assets, and rights are granted at the catalog or
global level.  Asset custom fields are either applied globally to all Catalogs
or individually to specific Catalogs.

=over 4

=item id

=item Name

Limited to 255 characters.

=item Description

Limited to 255 characters.

=item Lifecycle

=item Disabled

=item Creator

=item Created

=item LastUpdatedBy

=item LastUpdated

=back

All of these are readable through methods of the same name and mutable through
methods of the same name with C<Set> prefixed.  The last four are automatically
managed.

=head1 METHODS

=head2 Load ID or NAME

Loads the specified Catalog into the current object.

=cut

sub Load {
    my $self = shift;
    my $id   = shift;
    return unless $id;

    if ( $id =~ /\D/ ) {
        return $self->LoadByCols( Name => $id );
    }
    else {
        return $self->SUPER::Load($id);
    }
}

=head2 Create PARAMHASH

Create takes a hash of values and creates a row in the database.  Available keys are:

=over 4

=item Name

=item Description

=item Lifecycle

=item HeldBy, Contact

A single principal ID or array ref of principal IDs to add as members of the
respective role groups for the new catalog.

User Names and EmailAddresses may also be used, but Groups must be referenced
by ID.

=item Disabled

=back

Returns a tuple of (status, msg) on failure and (id, msg, non-fatal errors) on
success, where the third value is an array reference of errors that occurred
but didn't prevent creation.

=cut

sub Create {
    my $self = shift;
    my %args = (
        Name            => '',
        Description     => '',
        Lifecycle       => 'assets',

        HeldBy          => undef,
        Contact         => undef,

        Disabled        => 0,

        @_
    );
    my @non_fatal_errors;

    return (0, $self->loc("Permission Denied"))
        unless $self->CurrentUserHasRight('AdminCatalog');

    return (0, $self->loc('Invalid Name (names must be unique and may not be all digits)'))
        unless $self->ValidateName( $args{'Name'} );

    $args{'Lifecycle'} ||= 'assets';

    return (0, $self->loc('[_1] is not a valid lifecycle', $args{'Lifecycle'}))
        unless $self->ValidateLifecycle( $args{'Lifecycle'} );

    RT->DatabaseHandle->BeginTransaction();

    my ( $id, $msg ) = $self->SUPER::Create(
        map { $_ => $args{$_} } qw(Name Description Lifecycle Disabled),
    );
    unless ($id) {
        RT->DatabaseHandle->Rollback();
        return (0, $self->loc("Catalog create failed: [_1]", $msg));
    }

    # Create role groups
    unless ($self->_CreateRoleGroups()) {
        RT->Logger->error("Couldn't create role groups for catalog ". $self->id);
        RT->DatabaseHandle->Rollback();
        return (0, $self->loc("Couldn't create role groups for catalog"));
    }

    # Figure out users for roles
    my $roles = {};
    push @non_fatal_errors, $self->_ResolveRoles( $roles, %args );
    push @non_fatal_errors, $self->_AddRolesOnCreate( $roles, map { $_ => sub {1} } $self->Roles );

    # Create transaction
    my ( $txn_id, $txn_msg, $txn ) = $self->_NewTransaction( Type => 'Create' );
    unless ($txn_id) {
        RT->DatabaseHandle->Rollback();
        return (0, $self->loc( 'Catalog Create txn failed: [_1]', $txn_msg ));
    }

    $self->CacheNeedsUpdate(1);
    RT->DatabaseHandle->Commit();

    return ($id, $self->loc('Catalog #[_1] created: [_2]', $self->id, $args{'Name'}), \@non_fatal_errors);
}

=head2 ValidateName NAME

Requires that Names contain at least one non-digit and doesn't already exist.

=cut

sub ValidateName {
    my $self = shift;
    my $name = shift;
    return 0 unless defined $name and length $name;
    return 0 unless $name =~ /\D/;

    my $catalog = RT::Catalog->new( RT->SystemUser );
    $catalog->Load($name);
    return 0 if $catalog->id;

    return 1;
}

=head2 Delete

Catalogs may not be deleted.  Always returns failure.

You should disable the catalog instead using C<< $catalog->SetDisabled(1) >>.

=cut

sub Delete {
    my $self = shift;
    return (0, $self->loc("Catalogs may not be deleted"));
}

=head2 CurrentUserHasRight RIGHTNAME

Returns true if the current user has the right for this catalog, or globally if
this is called on an unloaded object.

=cut

sub CurrentUserHasRight {
    my $self  = shift;
    my $right = shift;

    return (
        $self->CurrentUser->HasRight(
            Right        => $right,
            Object       => ($self->id ? $self : RT->System),
        )
    );
}

=head2 CurrentUserCanSee

Returns true if the current user can see the catalog via the I<ShowCatalog> or
I<AdminCatalog> rights.

=cut

sub CurrentUserCanSee {
    my $self = shift;
    return $self->CurrentUserHasRight('ShowCatalog')
        || $self->CurrentUserHasRight('AdminCatalog');
}

=head2 Owner

Returns an L<RT::User> object for this catalog's I<Owner> role group.  On error,
returns undef.

=head2 HeldBy

Returns an L<RT::Group> object for this catalog's I<HeldBy> role group.  The object
may be unloaded if permissions aren't satisified.

=head2 Contacts

Returns an L<RT::Group> object for this catalog's I<Contact> role
group.  The object may be unloaded if permissions aren't satisified.

=cut

sub Owner {
    my $self  = shift;
    my $group = $self->RoleGroup("Owner");
    return unless $group and $group->id;
    return $group->UserMembersObj->First;
}
sub HeldBy   { $_[0]->RoleGroup("HeldBy")  }
sub Contacts { $_[0]->RoleGroup("Contact") }

=head2 AddRoleMember

Checks I<AdminCatalog> before calling L<RT::Role::Record::Roles/_AddRoleMember>.

=cut

sub AddRoleMember {
    my $self = shift;

    return (0, $self->loc("No permission to modify this catalog"))
        unless $self->CurrentUserHasRight("AdminCatalog");

    return $self->_AddRoleMember(@_);
}

=head2 DeleteRoleMember

Checks I<AdminCatalog> before calling L<RT::Role::Record::Roles/_DeleteRoleMember>.

=cut

sub DeleteRoleMember {
    my $self = shift;

    return (0, $self->loc("No permission to modify this catalog"))
        unless $self->CurrentUserHasRight("AdminCatalog");

    return $self->_DeleteRoleMember(@_);
}

=head2 RoleGroup

An ACL'd version of L<RT::Role::Record::Roles/_RoleGroup>.  Checks I<ShowCatalog>.

=cut

sub RoleGroup {
    my $self = shift;
    if ($self->CurrentUserCanSee) {
        return $self->_RoleGroup(@_);
    } else {
        return RT::Group->new( $self->CurrentUser );
    }
}

=head2 AssetCustomFields

Returns an L<RT::CustomFields> object containing all global and
catalog-specific B<asset> custom fields.

=cut

sub AssetCustomFields {
    my $self = shift;
    my $cfs  = RT::CustomFields->new( $self->CurrentUser );
    if ($self->CurrentUserCanSee) {
        $cfs->SetContextObject( $self );
        $cfs->LimitToGlobalOrObjectId( $self->Id );
        $cfs->LimitToLookupType( RT::Asset->CustomFieldLookupType );
        $cfs->ApplySortOrder;
    } else {
        $cfs->Limit( FIELD => 'id', VALUE => 0, SUBCLAUSE => 'acl' );
    }
    return ($cfs);
}

=head1 INTERNAL METHODS

Public methods, but you shouldn't need to call these unless you're
extending Assets and Catalogs.

=head2 AddRights C<< RIGHT => DESCRIPTION >> [, ...]

Adds the given rights to the list of possible rights.  This method
should be called during server startup, not at runtime.

=cut

my (%RIGHTS, %RIGHT_CATEGORIES);

sub AddRights {
    my $self = shift;
    my %new = @_;
    %RIGHTS = ( %RIGHTS, %new );
    %RT::ACE::LOWERCASERIGHTNAMES = ( %RT::ACE::LOWERCASERIGHTNAMES,
                                      map { lc($_) => $_ } keys %new);
    return;
}

=head2 AddRightCategories C<< RIGHT => CATEGORY>> [, ...]

Adds the given right and category pairs to the list of right categories.
This method should be called during server startup, not at runtime.

=cut

sub AddRightCategories {
    my $self = shift;
    %RIGHT_CATEGORIES = ( %RIGHT_CATEGORIES, @_ );
    return;
}

=head2 AvailableRights

Returns a hashref of available rights for this object. The keys are the
right names and the values are a description of what the rights do.

=cut

sub AvailableRights {
    return { %RIGHTS };
}

=head2 RightCategories

Returns a hashref of C<Right> and C<Category> pairs, as added with
L</AddRightCategories>.

=cut

sub RightCategories {
    return { %RIGHT_CATEGORIES };
}

=head2 CacheNeedsUpdate

Takes zero or one arguments.

If a true argument is provided, marks any Catalog caches as needing an update.
This happens when catalogs are created, disabled/enabled, or modified.  Returns
nothing.

If no arguments are provided, returns an epoch time that any catalog caches
should be newer than.

May be called as a class or object method.

=cut

sub CacheNeedsUpdate {
    my $class  = shift;
    my $update = shift;

    if ($update) {
        RT->System->SetAttribute(Name => 'CatalogCacheNeedsUpdate', Content => time);
        return;
    } else {
        my $attribute = RT->System->FirstAttribute('CatalogCacheNeedsUpdate');
        return $attribute ? $attribute->Content : 0;
    }
}

=head1 PRIVATE METHODS

Documented for internal use only, do not call these from outside RT::Catalog
itself.

=head2 _Set

Checks if the current user can I<AdminCatalog> before calling C<SUPER::_Set>
and records a transaction against this object if C<SUPER::_Set> was
successful.

=cut

sub _Set {
    my $self = shift;
    my %args = (
        Field => undef,
        Value => undef,
        @_
    );

    return (0, $self->loc("Permission Denied"))
        unless $self->CurrentUserHasRight('AdminCatalog');

    my $old = $self->_Value( $args{'Field'} );

    my ($ok, $msg) = $self->SUPER::_Set(@_);

    # Only record the transaction if the _Set worked
    return ($ok, $msg) unless $ok;

    my $txn_type = "Set";
    if ($args{'Field'} eq "Disabled") {
        if (not $old and $args{'Value'}) {
            $txn_type = "Disabled";
        }
        elsif ($old and not $args{'Value'}) {
            $txn_type = "Enabled";
        }
    }

    $self->CacheNeedsUpdate(1);

    my ($txn_id, $txn_msg, $txn) = $self->_NewTransaction(
        Type     => $txn_type,
        Field    => $args{'Field'},
        NewValue => $args{'Value'},
        OldValue => $old,
    );
    return ($txn_id, scalar $txn->BriefDescription);
}

=head2 _Value

Checks L</CurrentUserCanSee> before calling C<SUPER::_Value>.

=cut

sub _Value {
    my $self = shift;
    return unless $self->CurrentUserCanSee;
    return $self->SUPER::_Value(@_);
}

sub Table { "RTxCatalogs" }

sub _CoreAccessible {
    {
        id            => { read => 1, type => 'int(11)',        default => '' },
        Name          => { read => 1, type => 'varchar(255)',   default => '',          write => 1 },
        Description   => { read => 1, type => 'varchar(255)',   default => '',          write => 1 },
        Lifecycle     => { read => 1, type => 'varchar(32)',    default => 'assets',    write => 1 },
        Disabled      => { read => 1, type => 'int(2)',         default => '0',         write => 1 },
        Creator       => { read => 1, type => 'int(11)',        default => '0', auto => 1 },
        Created       => { read => 1, type => 'datetime',       default => '',  auto => 1 },
        LastUpdatedBy => { read => 1, type => 'int(11)',        default => '0', auto => 1 },
        LastUpdated   => { read => 1, type => 'datetime',       default => '',  auto => 1 },
    }
}

RT::Base->_ImportOverlays();

1;
