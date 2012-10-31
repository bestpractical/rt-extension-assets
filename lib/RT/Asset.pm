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

for my $role ('Owner', 'User', 'TechnicalContact') {
    RT::Asset->RegisterRole( Name => $role );
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

=item Disabled

=item Owner, User, TechnicalContact

A single principal ID or array ref of principal IDs to add as members of the
respective role groups for the new asset

=back

=cut

sub Create {
    my $self = shift;
    my %args = (
        Name            => '',
        Description     => '',
        Disabled        => 0,

        Owner               => undef,
        User                => undef,
        TechnicalContact    => undef,
        @_
    );

    return (0, $self->loc("Permission Denied"))
        unless $self->CurrentUserHasRight('CreateAsset');

    return (0, $self->loc('Invalid Name (names may not be all digits)'))
        unless $self->ValidateName( $args{'Name'} );

    RT->DatabaseHandle->BeginTransaction();

    my ( $id, $msg ) = $self->SUPER::Create(
        map { $_ => $args{$_} } qw(Name Description Disabled),
    );
    unless ($id) {
        RT->DatabaseHandle->Rollback();
        return (0, $self->loc("Asset create failed: [_1]", $msg));
    }

    # Create role groups
    foreach my $type ($self->Roles) {
        my $group = RT::Group->new( $self->CurrentUser );
        my ($id, $msg) = $group->CreateRoleGroup( Object => $self, Type => $type );
        unless ($id) {
            RT->Logger->error("Couldn't create role group '$type' for asset ". $self->id .": $msg");
            RT->DatabaseHandle->Rollback();
            return (0, $self->loc("Couldn't create role group [_1]: [_2]", $type, $msg));
        }
    }

    # Add members to roles
    for my $role ($self->Roles) {
        next unless $args{$role};

        my $group = $self->RoleGroup($role);

        my @members = ref($args{$role}) eq 'ARRAY'
            ? @{$args{$role}}
            : $args{$role};

        for my $member (@members) {
            my ($ok, $msg) = $group->_AddMember(
                PrincipalId         => $member,
                InsideTransaction   => 1,
            );
            unless ($ok) {
                RT->Logger->error("Couldn't add $member as $role: $msg");
                RT->DatabaseHandle->Rollback();
                return (0, $self->loc("Couldn't add [_1] as [_2]: [_3]", $member, $role, $msg));
            }
        }
    }

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

    return ($id, $self->loc('Asset #[_1] created: [_2]', $self->id, $self->Name));
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

=head2 Delete

Assets may not be deleted.  Always returns failure.

You should disable the asset instead with C<< $asset->SetDisabled(1) >>.

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

Returns true if the current user can see the asset.

=cut

sub CurrentUserCanSee {
    my $self = shift;
    return $self->CurrentUserHasRight('ShowAsset');
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

=head2 Owners

Returns an L<RT::Group> object for this asset's I<Owner> role group.  The
object may be unloaded if permissions aren't satisified.

=head2 Users

Returns an L<RT::Group> object for this asset's I<User> role group.  The object
may be unloaded if permissions aren't satisified.

=head2 TechnicalContacts

Returns an L<RT::Group> object for this asset's I<TechnicalContact> role
group.  The object may be unloaded if permissions aren't satisified.

=cut

sub Owners              { $_[0]->RoleGroup("Owner") }
sub Users               { $_[0]->RoleGroup("User")  }
sub TechnicalContacts   { $_[0]->RoleGroup("TechnicalContact") }

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
    if ($self->CurrentUserHasRight("ShowAsset")) {
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
        Type     => 'Set',
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
        Description   => { read => 1, type => 'varchar(255)',   default => '',  write => 1 },
        Disabled      => { read => 1, type => 'int(2)',         default => '0', write => 1 },
        Creator       => { read => 1, type => 'int(11)',        default => '0', auto => 1 },
        Created       => { read => 1, type => 'datetime',       default => '',  auto => 1 },
        LastUpdatedBy => { read => 1, type => 'int(11)',        default => '0', auto => 1 },
        LastUpdated   => { read => 1, type => 'datetime',       default => '',  auto => 1 },
    }
}

RT::Base->_ImportOverlays();

1;
