use strict;
use warnings;

use lib 'xt/lib';
use RT::Extension::Assets::Test tests => undef;

diag "Create basic asset (no CFs)";
{
    my $asset = RT::Asset->new( RT->SystemUser );
    my ($id, $msg) = $asset->Create(
        Name        => 'Thinkpad T420s',
        Description => 'Laptop',
    );
    ok $id, "Created: $msg";
    is $asset->id, $id, "id matches";
    is $asset->Name, "Thinkpad T420s", "Name matches";
    is $asset->Description, "Laptop", "Description matches";
    ok !$asset->Disabled, "Default to enabled";

    # Create txn
    my @txns = @{$asset->Transactions->ItemsArrayRef};
    is scalar @txns, 1, "One transaction";
    is $txns[0]->Type, "Create", "... of type Create";

    # Update
    my ($txnid, $txnmsg) = $asset->SetName("Lenovo Thinkpad T420s");
    ok $txnid, "Updated Name: $txnmsg";
    is $asset->Name, "Lenovo Thinkpad T420s", "New Name matches";

    # Set txn
    @txns = @{$asset->Transactions->ItemsArrayRef};
    is scalar @txns, 2, "Two transactions";
    is $txns[1]->Type, "Set", "... the second of which is Set";
    is $txns[1]->Field, "Name", "... Field is Name";
    is $txns[1]->OldValue, "Thinkpad T420s", "... OldValue is correct";

    # Delete
    my ($ok, $err) = $asset->Delete;
    ok !$ok, "Deletes are prevented: $err";
    $asset->Load($id);
    ok $asset->id, "Asset not deleted";
}

diag "Create with CFs";
{
    my $height = create_cf( Name => 'Height' );
    ok $height->id, "Created CF";

    my $material = create_cf( Name => 'Material' );
    ok $material->id, "Created CF";

    ok apply_cfs($height, $material), "Applied CFs";

    ok $height->IsOnlyGlobal, "RT::Asset CFs are recognized as only global";

    my $asset = RT::Asset->new( RT->SystemUser );
    my ($id, $msg) = $asset->Create(
        Name                        => 'Standing desk',
        "CustomField-".$height->id  => '46"',
        "CustomField-Material"      => 'pine',
    );
    ok $id, "Created: $msg";
    is $asset->FirstCustomFieldValue('Height'), '46"', "Found height";
    is $asset->FirstCustomFieldValue('Material'), 'pine', "Found material";
    is $asset->Transactions->Count, 1, "Only a single txn";
}

note "Create/update with Roles";
{
    my $root = RT::User->new( RT->SystemUser );
    $root->Load("root");
    ok $root->id, "Found root";

    my $bps = RT::Test->load_or_create_user( Name => "BPS" );
    ok $bps->id, "Created BPS user";

    my $asset = RT::Asset->new( RT->SystemUser );
    my ($id, $msg) = $asset->Create(
        Name    => 'RT server',
        User                => $root->PrincipalId,
        Owner               => $bps->PrincipalId,
        TechnicalContact    => $bps->PrincipalId,
    );
    ok $id, "Created: $msg";
    is $asset->Users->UserMembersObj->First->Name, "root", "root is User";
    is $asset->Owners->UserMembersObj->First->Name, "BPS", "BPS is Owner";
    is $asset->TechnicalContacts->UserMembersObj->First->Name, "BPS", "BPS is TechnicalContact";

    my $sysadmins = RT::Group->new( RT->SystemUser );
    $sysadmins->CreateUserDefinedGroup( Name => 'Sysadmins' );
    ok $sysadmins->id, "Created group";
    is $sysadmins->Name, "Sysadmins", "Got group name";

    (my $ok, $msg) = $asset->AddRoleMember(
        Type        => 'TechnicalContact',
        Group       => 'Sysadmins',
    );
    ok $ok, "Added Sysadmins as TechnicalContact: $msg";
    is $asset->TechnicalContacts->MembersObj->Count, 2, "Found two members";

    ($ok, $msg) = $asset->DeleteRoleMember(
        Type        => 'TechnicalContact',
        PrincipalId => $bps->PrincipalId,
    );
    ok $ok, "Removed BPS user as TechnicalContact: $msg";
    is $asset->TechnicalContacts->MembersObj->Count, 1, "Now just one member";
    is $asset->TechnicalContacts->GroupMembersObj(Recursively => 0)->First->Name, "Sysadmins", "... it's Sysadmins";
}

done_testing;
