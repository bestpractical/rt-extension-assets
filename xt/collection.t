use strict;
use warnings;

use lib 'xt/lib';
use RT::Extension::Assets::Test tests => undef;

my $user = RT::Test->load_or_create_user( Name => 'testuser' );
ok $user->id, "Created user";

my $location = create_cf( Name => 'Location' );
ok $location->id, "Created CF";
ok apply_cfs($location), "Applied CF";

ok(
    create_assets(
        { Name => "Thinkpad T420s", "CustomField-Location" => "Home" },
        { Name => "Standing desk",  "CustomField-Location" => "Office" },
        { Name => "Chair",          "CustomField-Location" => "Office", Disabled => 1 },
    ),
    "Created assets"
);

diag "Basic types of limits";
{
    my $assets = RT::Assets->new( RT->SystemUser );
    $assets->Limit( FIELD => 'Name', OPERATOR => 'LIKE', VALUE => 'thinkpad' );
    is $assets->Count, 1, "Found 1 like thinkpad";
    is $assets->First->Name, "Thinkpad T420s";

    $assets = RT::Assets->new( RT->SystemUser );
    $assets->UnLimit;
    is $assets->Count, 2, "Found 2 total";
    ok((!grep { $_->Name eq "Chair" } @{$assets->ItemsArrayRef}), "No chair (disabled)");

    $assets = RT::Assets->new( RT->SystemUser );
    $assets->LimitToDeleted;
    is $assets->Count, 1, "Found 1 disabled";
    is $assets->First->Name, "Chair", "Found chair";

    $assets = RT::Assets->new( RT->SystemUser );
    $assets->UnLimit;
    $assets->LimitCustomField(
        CUSTOMFIELD => $location->id,
        VALUE       => "Office",
    );
    is $assets->Count, 1, "Found 1 in Office";
    ok $assets->First, "Got record";
    is $assets->First->Name, "Standing desk", "Found standing desk";
}

diag "Test ACLs";
{
    my $assets = RT::Assets->new( RT::CurrentUser->new($user) );
    $assets->UnLimit;
    is scalar @{$assets->ItemsArrayRef}, 0, "Found none";
}

done_testing;
