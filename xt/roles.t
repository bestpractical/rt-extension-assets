use strict;
use warnings;

use lib 'xt/lib';
use RT::Extension::Assets::Test tests => undef;

my $asset = create_asset( Name => "Test asset" );
ok $asset && $asset->id, "Created asset";

for my $object ($asset, RT->System) {
    for my $role (RT::Asset->Roles) {
        my $group = $object->RoleGroup($role);
        ok $group->id, "Loaded role group $role for " . ref($object);

        my $principal = $group->PrincipalObj;
        ok $principal && $principal->id, "Found PrincipalObj for role group"
            or next;

        my ($ok, $msg) = $principal->GrantRight(
            Object  => $object,
            Right   => "ShowAsset",
        );
        ok $ok, "Granted right" or diag "Error: $msg";
    }
}

done_testing;
