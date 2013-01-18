use strict;
use warnings;
use 5.10.1;

package RT::Asset;
use base 'RT::Record';

use Role::Basic "with";
with "RT::Role::Record::Status",
     "RT::Role::Record::Links",
     "RT::Role::Record::Roles" => {
         -rename => {
             # We provide ACL'd wraps of these.
             AddRoleMember    => "_AddRoleMember",
             DeleteRoleMember => "_DeleteRoleMember",
             RoleGroup        => "_RoleGroup",
         },
     };

use RT::Catalog;
use RT::CustomField;
use RT::URI::asset;

=head1 NAME

RT::Asset - Represents a single asset record

=cut

sub LifecycleColumn { "Catalog" }

# Assets are primarily built on custom fields
RT::CustomField->_ForObjectType( CustomFieldLookupType() => 'Assets' );
RT::CustomField->RegisterBuiltInGroupings(
    'RT::Asset' => [qw( Basics Dates People Links )]
);

for my $role ('Owner', 'HeldBy', 'Contact') {
    state $i = 1;
    RT::Asset->RegisterRole(
        Name            => $role,
        EquivClasses    => ["RT::Catalog"],
        SortOrder       => $i++,
        ( $role eq "Owner"
            ? ( Single         => 1,
                ACLOnlyInEquiv => 1, )
            : () ),
    );
}

=head1 DESCRIPTION

An Asset is a small record object upon which zero to many custom fields are
applied.  The core fields are:

=over 4

=item id

=item Name

Limited to 255 characters.

=item Description

Limited to 255 characters.

=item Catalog

=item Status

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

Loads the specified Asset into the current object.

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

=item Catalog

Name or numeric ID

=item CustomField-<ID>

Sets the value for this asset of the custom field specified by C<< <ID> >>.

C<< <ID> >> should be a numeric ID, but may also be a Name if and only if your
custom fields have unique names.  Without unique names, the behaviour is
undefined.

=item Status

=item Owner, HeldBy, Contact

A single principal ID or array ref of principal IDs to add as members of the
respective role groups for the new asset.

User Names and EmailAddresses may also be used, but Groups must be referenced
by ID.

=item RefersTo, ReferredToBy, DependsOn, DependedOnBy, Parents, Children, and aliases

Any of these link types accept either a single value or arrayref of values
parseable by L<RT::URI>.

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
        Catalog         => undef,

        Owner           => undef,
        HeldBy          => undef,
        Contact         => undef,

        Status          => undef,
        @_
    );
    my @non_fatal_errors;

    return (0, $self->loc("Invalid Catalog"))
        unless $self->ValidateCatalog( $args{'Catalog'} );

    my $catalog = RT::Catalog->new( $self->CurrentUser );
    $catalog->Load($args{'Catalog'});

    $args{'Catalog'} = $catalog->id;

    return (0, $self->loc("Permission Denied"))
        unless $catalog->CurrentUserHasRight('CreateAsset');

    return (0, $self->loc('Invalid Name (names may not be all digits)'))
        unless $self->ValidateName( $args{'Name'} );

    my $cycle = $catalog->LifecycleObj;
    unless ( defined $args{'Status'} && length $args{'Status'} ) {
        $args{'Status'} = $cycle->DefaultOnCreate;
    }

    unless ( $cycle->IsValid( $args{'Status'} ) ) {
        return ( 0,
            $self->loc("Status '[_1]' isn't a valid status for assets.",
                $self->loc($args{'Status'}))
        );
    }

    unless ( $cycle->IsTransition( '' => $args{'Status'} ) ) {
        return ( 0,
            $self->loc("New assets cannot have status '[_1]'.",
                $self->loc($args{'Status'}))
        );
    }

    RT->DatabaseHandle->BeginTransaction();

    my ( $id, $msg ) = $self->SUPER::Create(
        map { $_ => $args{$_} } qw(Name Description Catalog Status),
    );
    unless ($id) {
        RT->DatabaseHandle->Rollback();
        return (0, $self->loc("Asset create failed: [_1]", $msg));
    }

    # Let users who just created an asset see it until the end of this method.
    $self->{_object_is_readable} = 1;

    # Create role groups
    unless ($self->_CreateRoleGroups()) {
        RT->Logger->error("Couldn't create role groups for asset ". $self->id);
        RT->DatabaseHandle->Rollback();
        return (0, $self->loc("Couldn't create role groups for asset"));
    }

    # Figure out users for roles
    my $roles = {};
    push @non_fatal_errors, $self->_ResolveRoles( $roles, %args );
    push @non_fatal_errors, $self->_AddRolesOnCreate( $roles, map { $_ => sub {1} } $self->Roles );

    # Add CFs
    foreach my $key (keys %args) {
        next unless $key =~ /^CustomField-(.+)$/i;
        my $cf   = $1;
        my @vals = ref $args{$key} eq 'ARRAY' ? @{ $args{$key} } : $args{$key};
        foreach my $value (@vals) {
            next unless defined $value;

            my ( $cfid, $cfmsg ) = $self->AddCustomFieldValue(
                (ref($value) eq 'HASH'
                    ? %$value
                    : (Value => $value)),
                Field             => $cf,
                RecordTransaction => 0
            );
            unless ($cfid) {
                RT->DatabaseHandle->Rollback();
                return (0, $self->loc("Couldn't add custom field value on create: [_1]", $cfmsg));
            }
        }
    }

    # Create transaction
    my ( $txn_id, $txn_msg, $txn ) = $self->_NewTransaction( Type => 'Create' );
    unless ($txn_id) {
        RT->DatabaseHandle->Rollback();
        return (0, $self->loc( 'Asset Create txn failed: [_1]', $txn_msg ));
    }

    # Add links
    push @non_fatal_errors, $self->_AddLinksOnCreate(\%args);

    RT->DatabaseHandle->Commit();

    # Let normal ACLs take over.
    delete $self->{_object_is_readable};

    return ($id, $self->loc('Asset #[_1] created: [_2]', $self->id, $args{'Name'}), \@non_fatal_errors);
}

=head2 ValidateName NAME

Requires that Names contain at least one non-digit.  Empty names are OK.

=cut

sub ValidateName {
    my $self = shift;
    my $name = shift;
    return 1 unless defined $name and length $name;
    return 0 unless $name =~ /\D/;
    return 1;
}

=head2 ValidateCatalog

Takes a catalog name or ID.  Returns true if the catalog exists and is not
disabled, otherwise false.

=cut

sub ValidateCatalog {
    my $self    = shift;
    my $name    = shift;
    my $catalog = RT::Catalog->new( $self->CurrentUser );
    $catalog->Load($name);
    return 1 if $catalog->id and not $catalog->Disabled;
    return 0;
}

=head2 Delete

Assets may not be deleted.  Always returns failure.

You should disable the asset instead with C<< $asset->SetStatus('deleted') >>.

=cut

sub Delete {
    my $self = shift;
    return (0, $self->loc("Assets may not be deleted"));
}

=head2 CurrentUserHasRight RIGHTNAME

Returns true if the current user has the right for this asset, or globally if
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

Returns true if the current user can see the asset, either because they just
created it or they have the I<ShowAsset> right.

=cut

sub CurrentUserCanSee {
    my $self = shift;
    return $self->{_object_is_readable} || $self->CurrentUserHasRight('ShowAsset');
}

=head2 URI

Returns this asset's URI

=cut

sub URI {
    my $self = shift;
    my $uri = RT::URI::asset->new($self->CurrentUser);
    return $uri->URIForObject($self);
}

=head2 CatalogObj

Returns the L<RT::Catalog> object for this asset's catalog.

=cut

sub CatalogObj {
    my $self = shift;
    my $catalog = RT::Catalog->new($self->CurrentUser);
    $catalog->Load( $self->__Value("Catalog") );
    return $catalog;
}

=head2 SetCatalog

Validates the supplied catalog and updates the column if valid.  Transitions
Status if necessary.  Returns a (status, message) tuple.

=cut

sub SetCatalog {
    my $self  = shift;
    my $value = shift;

    return (0, $self->loc("Permission Denied"))
        unless $self->CurrentUserHasRight("ModifyAsset");

    my ($ok, $msg, $status) = $self->_SetLifecycleColumn(
        Value           => $value,
        RequireRight    => "CreateAsset"
    );
    return ($ok, $msg);
}


=head2 Owner

Returns an L<RT::User> object for this asset's I<Owner> role group.  On error,
returns undef.

=head2 HeldBy

Returns an L<RT::Group> object for this asset's I<HeldBy> role group.  The object
may be unloaded if permissions aren't satisified.

=head2 Contacts

Returns an L<RT::Group> object for this asset's I<Contact> role
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

Checks I<ModifyAsset> before calling L<RT::Role::Record::Roles/_AddRoleMember>.

=cut

sub AddRoleMember {
    my $self = shift;

    return (0, $self->loc("No permission to modify this asset"))
        unless $self->CurrentUserHasRight("ModifyAsset");

    return $self->_AddRoleMember(@_);
}

=head2 DeleteRoleMember

Checks I<ModifyAsset> before calling L<RT::Role::Record::Roles/_DeleteRoleMember>.

=cut

sub DeleteRoleMember {
    my $self = shift;

    return (0, $self->loc("No permission to modify this asset"))
        unless $self->CurrentUserHasRight("ModifyAsset");

    return $self->_DeleteRoleMember(@_);
}

=head2 RoleGroup

An ACL'd version of L<RT::Role::Record::Roles/_RoleGroup>.  Checks I<ShowAsset>.

=cut

sub RoleGroup {
    my $self = shift;
    if ($self->CurrentUserCanSee) {
        return $self->_RoleGroup(@_);
    } else {
        return RT::Group->new( $self->CurrentUser );
    }
}

=head1 INTERNAL METHODS

Public methods, but you shouldn't need to call these unless you're
extending Assets.

=head2 CustomFieldLookupType

=cut

sub CustomFieldLookupType { "RT::Catalog-RT::Asset" }

=head2 ACLEquivalenceObjects

=cut

sub ACLEquivalenceObjects {
    my $self = shift;
    return $self->CatalogObj;
}

=head2 ModifyLinkRight

=cut

# Used for StrictLinkACL and RT::Role::Record::Links.
#
# Historically StrictLinkACL has only applied between tickets, but
# if you care about it enough to turn it on, you probably care when
# linking an asset to an asset or an asset to a ticket.

sub ModifyLinkRight { "ModifyAsset" }

=head1 PRIVATE METHODS

Documented for internal use only, do not call these from outside RT::Asset
itself.

=head2 _Set

Checks if the current user can I<ModifyAsset> before calling C<SUPER::_Set>
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
        unless $self->CurrentUserHasRight('ModifyAsset');

    my $old = $self->_Value( $args{'Field'} );

    my ($ok, $msg) = $self->SUPER::_Set(@_);

    # Only record the transaction if the _Set worked
    return ($ok, $msg) unless $ok;

    my $txn_type = $args{Field} eq "Status" ? "Status" : "Set";

    my ($txn_id, $txn_msg, $txn) = $self->_NewTransaction(
        Type     => $txn_type,
        Field    => $args{'Field'},
        NewValue => $args{'Value'},
        OldValue => $old,
    );

    # Ensure that we can read the transaction, even if the change just made
    # the asset unreadable to us.  This is only in effect for the lifetime of
    # $txn, i.e. as soon as this method returns.
    $txn->{ _object_is_readable } = 1;

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

sub Table { "RTxAssets" }

sub _CoreAccessible {
    {
        id            => { read => 1, type => 'int(11)',        default => '' },
        Name          => { read => 1, type => 'varchar(255)',   default => '',  write => 1 },
        Status        => { read => 1, type => 'varchar(64)',    default => '',  write => 1 },
        Description   => { read => 1, type => 'varchar(255)',   default => '',  write => 1 },
        Catalog       => { read => 1, type => 'int(11)',        default => '0', write => 1 },
        Creator       => { read => 1, type => 'int(11)',        default => '0', auto => 1 },
        Created       => { read => 1, type => 'datetime',       default => '',  auto => 1 },
        LastUpdatedBy => { read => 1, type => 'int(11)',        default => '0', auto => 1 },
        LastUpdated   => { read => 1, type => 'datetime',       default => '',  auto => 1 },
    }
}

RT::Base->_ImportOverlays();

1;
