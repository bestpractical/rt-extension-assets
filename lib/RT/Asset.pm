use strict;
use warnings;

package RT::Asset;
use base 'RT::Record';

use RT::CustomField;
use RT::URI::asset;

=head1 NAME

RT::Asset - Represents a single asset record

=cut

# Assets are primarily built on custom fields
RT::CustomField->_ForObjectType( CustomFieldLookupType() => 'Assets' );
RT::CustomField->RegisterBuiltInGroupings(
    'RT::Asset' => [qw( Basics Dates People Links )]
);

# Setup rights
$RT::ACE::OBJECT_TYPES{'RT::Asset'} = 1;

RT::Asset->AddRights(
    ShowAsset           => 'See assets',        # loc_pair
    CreateAsset         => 'Create assets',     # loc_pair
    ModifyAsset         => 'Modify assets',     # loc_pair
);
RT::Asset->AddRightCategories(
    ShowAsset   => 'Staff',
    CreateAsset => 'Staff',
    ModifyAsset => 'Staff',
);

for my $role ('Owner', 'HeldBy', 'Contact') {
    RT::Asset->RegisterRole(
        Name    => $role,
        Single  => ($role eq "Owner" ? 1 : 0),
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

        Owner           => undef,
        HeldBy          => undef,
        Contact         => undef,

        Status          => undef,
        @_
    );
    my @non_fatal_errors;

    return (0, $self->loc("Permission Denied"))
        unless $self->CurrentUserHasRight('CreateAsset');

    return (0, $self->loc('Invalid Name (names may not be all digits)'))
        unless $self->ValidateName( $args{'Name'} );

    my $cycle = $self->Lifecycle;
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
        map { $_ => $args{$_} } qw(Name Description Status),
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

    # XXX TODO: Handle Links

    # Create transaction
    my ( $txn_id, $txn_msg, $txn ) = $self->_NewTransaction( Type => 'Create' );
    unless ($txn_id) {
        RT->DatabaseHandle->Rollback();
        return (0, $self->loc( 'Asset Create txn failed: [_1]', $txn_msg ));
    }

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

=head2 ValidateStatus STATUS

Takes a string. Returns true if that status is a valid status for this asset.
Returns false otherwise.

=cut

sub ValidateStatus {
    my $self   = shift;
    return $self->Lifecycle->IsValid(@_);
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

=head2 AddLink

Checks I<ModifyAsset> before calling L<RT::Record/_AddLink>.

=cut

sub AddLink {
    my $self = shift;
    my %args = (@_);

    return (0, $self->loc("Permission Denied"))
        unless $self->CurrentUserHasRight("ModifyAsset");

    return $self->_AddLink(%args);
}

=head2 DeleteLink

Checks I<ModifyAsset> before calling L<RT::Record/_DeleteLink>.

=cut

sub DeleteLink {
    my $self = shift;
    my %args = (@_);

    return (0, $self->loc("Permission Denied"))
        unless $self->CurrentUserHasRight("ModifyAsset");

    return $self->_DeleteLink(%args);
}

=head2 URI

Returns this asset's URI

=cut

sub URI {
    my $self = shift;
    my $uri = RT::URI::asset->new($self->CurrentUser);
    return $uri->URIForObject($self);
}

=head2 Lifecycle

Returns an R<RT::Lifecycle> object for this asset.

=cut

sub Lifecycle {
    return RT::Lifecycle->Load( Name => 'assets', Type => 'asset' );
}

=head2 SetStatus STATUS

Set this asset's status.

=cut

sub SetStatus {
    my $self = shift;

    my ($new) = @_;
    my $old = $self->__Value('Status');

    my $lifecycle = $self->Lifecycle;
    unless ( $lifecycle->IsValid( $new ) ) {
        return (0, $self->loc("Status '[_1]' isn't a valid status for assets.", $self->loc($new)));
    }

    unless ( $lifecycle->IsTransition( $old => $new ) ) {
        return (0, $self->loc("You can't change status from '[_1]' to '[_2]'.", $self->loc($old), $self->loc($new)));
    }

    my $check_right = $lifecycle->CheckRight( $old => $new );
    unless ( $self->CurrentUserHasRight( $check_right ) ) {
        return ( 0, $self->loc('Permission Denied') );
    }

    # Actually update the status
    my ($val, $msg) = $self->_Set(
        Field           => 'Status',
        Value           => $new,
        CheckACL        => 0,
        TransactionType => 'Status',
    );
    return ($val, $msg);
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

Checks I<ModifyAsset> before calling L<RT::Record/AddRoleMember>.

=cut

sub AddRoleMember {
    my $self = shift;

    return (0, $self->loc("No permission to modify this asset"))
        unless $self->CurrentUserHasRight("ModifyAsset");

    return $self->SUPER::AddRoleMember(@_);
}

=head2 DeleteRoleMember

Checks I<ModifyAsset> before calling L<RT::Record/DeleteRoleMember>.

=cut

sub DeleteRoleMember {
    my $self = shift;

    return (0, $self->loc("No permission to modify this asset"))
        unless $self->CurrentUserHasRight("ModifyAsset");

    return $self->SUPER::DeleteRoleMember(@_);
}

=head2 RoleGroup

An ACL'd version of L<RT::Record/RoleGroup>.  Checks I<ShowAsset>.

=cut

sub RoleGroup {
    my $self = shift;
    if ($self->CurrentUserCanSee) {
        return $self->SUPER::RoleGroup(@_);
    } else {
        return RT::Group->new( $self->CurrentUser );
    }
}

=head1 INTERNAL METHODS

Public methods, but you shouldn't need to call these unless you're
extending Assets.

=head2 CustomFieldLookupType

=cut

sub CustomFieldLookupType { "RT::Asset" }

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

    my ($txn_id, $txn_msg, $txn) = $self->_NewTransaction(
        Type     => "Set",
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

sub Table { "RTxAssets" }

sub _CoreAccessible {
    {
        id            => { read => 1, type => 'int(11)',        default => '' },
        Name          => { read => 1, type => 'varchar(255)',   default => '',  write => 1 },
        Status        => { read => 1, type => 'varchar(64)',    default => '',  write => 1 },
        Description   => { read => 1, type => 'varchar(255)',   default => '',  write => 1 },
        Creator       => { read => 1, type => 'int(11)',        default => '0', auto => 1 },
        Created       => { read => 1, type => 'datetime',       default => '',  auto => 1 },
        LastUpdatedBy => { read => 1, type => 'int(11)',        default => '0', auto => 1 },
        LastUpdated   => { read => 1, type => 'datetime',       default => '',  auto => 1 },
    }
}

RT::Base->_ImportOverlays();

1;
