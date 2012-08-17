use strict;
use warnings;

use lib 'xt/lib';
use RT::Extension::Assets::Test tests => undef;

my $user = RT::Test->load_or_create_user( Name => 'testuser' );
ok $user->id, "Created user";

my $asset = RT::Asset->new( RT::CurrentUser->new($user) );

diag "CreateAsset";
{
    my ($id, $msg) = $asset->Create( Name => 'Thinkpad T420s' );
    ok !$id, "Create denied: $msg";

    ok(RT::Test->set_rights({
        Principal   => 'Privileged',
        Right       => 'CreateAsset',
        Object      => RT->System,
    }), "Granted CreateAsset");

    ($id, $msg) = $asset->Create( Name => 'Thinkpad T420s' );
    ok $id, "Created: $msg";
    is $asset->id, $id, "id matches";
};

diag "ShowAsset";
{
    is $asset->Name, undef, "Can't see Name without ShowAsset";

    ok(RT::Test->add_rights({
        Principal   => 'Privileged',
        Right       => 'ShowAsset',
        Object      => RT->System,
    }), "Granted ShowAsset");

    is $asset->Name, "Thinkpad T420s", "Got Name";
}

diag "ModifyAsset";
{
    my ($txnid, $txnmsg) = $asset->SetName("Lenovo Thinkpad T420s");
    ok !$txnid, "Update failed: $txnmsg";
    is $asset->Name, "Thinkpad T420s", "Name didn't change";

    # It doesn't matter that ticket #1 doesn't exist for ACLs to refuse us
    my ($ok, $msg) = $asset->AddLink( Type => 'RefersTo', Target => 't:1' );
    ok !$ok, "No rights to AddLink: $msg";

    ($ok, $msg) = $asset->DeleteLink( Type => 'RefersTo', Target => 't:1' );
    ok !$ok, "No rights to DeleteLink: $msg";

    ok(RT::Test->add_rights({
        Principal   => 'Privileged',
        Right       => 'ModifyAsset',
        Object      => RT->System,
    }), "Granted ModifyAsset");
    
    ($txnid, $txnmsg) = $asset->SetName("Lenovo Thinkpad T420s");
    ok $txnid, "Updated Name: $txnmsg";
    is $asset->Name, "Lenovo Thinkpad T420s", "Name changed";
}

done_testing;
