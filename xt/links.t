use strict;
use warnings;

use lib 'xt/lib';
use RT::Extension::Assets::Test tests => undef;

ok(
    create_assets(
        { Name => "Thinkpad T420s" },
        { Name => "Standing desk" },
        { Name => "Chair" },
    ),
    "Created assets"
);

my $ticket = RT::Test->create_ticket(
    Queue   => 1,
    Subject => 'a test ticket',
);
ok $ticket->id, "Created ticket";

diag "RT::URI::asset";
{
    my %uris = (
        # URI                   => Asset Name
        "asset:1"               => { id => 1, Name => "Thinkpad T420s" },
        "asset://example.com/2" => { id => 2, Name => "Standing desk" },
        "asset:13"              => undef,
    );

    while (my ($url, $expected) = each %uris) {
        my $uri = RT::URI->new( RT->SystemUser );
        my $parsed = $uri->FromURI($url);
        if ($expected) {
            ok $parsed, "Parsed $url";

            my $asset = $uri->Object;
            ok $asset, "Got object";
            is ref($asset), "RT::Asset", "... it's a RT::Asset";

            while (my ($field, $value) = each %$expected) {
                is $asset->$field, $value, "... $field is $value";
            }
        } else {
            ok !$parsed, "Failed to parse $url, as expected";
        }
    }
}

diag "RT::Asset link support";
{
    my $chair = RT::Asset->new( RT->SystemUser );
    $chair->LoadByCols( Name => "Chair" );
    ok $chair->id, "Loaded asset";
    is $chair->URI, "asset://example.com/".$chair->id, "->URI works";

    my ($link_id, $msg) = $chair->AddLink( Type => 'MemberOf', Target => 'asset:2' );
    ok $link_id, "Added link: $msg";

    my $parents = $chair->MemberOf;
    my $desk    = $parents->First->TargetObj;
    is $parents->Count, 1, "1 parent";
    is $desk->Name, "Standing desk", "Correct parent asset";

    for my $asset ($chair, $desk) {
        my $txns = $asset->Transactions;
        $txns->Limit( FIELD => 'Type', VALUE => 'AddLink' );
        is $txns->Count, 1, "1 AddLink txn on asset ".$asset->Name;
    }

    my ($ok, $err) = $chair->DeleteLink( Type => 'MemberOf', Target => 'asset:1' );
    ok !$ok, "Delete link failed on non-existent: $err";

    my ($deleted, $delete_msg) = $chair->DeleteLink( Type => 'MemberOf', Target => $parents->First->Target );
    ok $deleted, "Deleted link: $delete_msg";

    for my $asset ($chair, $desk) {
        my $txns = $asset->Transactions;
        $txns->Limit( FIELD => 'Type', VALUE => 'DeleteLink' );
        is $txns->Count, 1, "1 DeleteLink txn on asset ".$asset->Name;
    }
};

diag "Linking to tickets";
{
    my $laptop = RT::Asset->new( RT->SystemUser );
    $laptop->LoadByCols( Name => "Thinkpad T420s" );

    my ($ok, $msg) = $ticket->AddLink( Type => 'RefersTo', Target => $laptop->URI );
    ok $ok, "Ticket refers to asset: $msg";

    my $links = $laptop->ReferredToBy;
    is $links->Count, 1, "Found a ReferredToBy link via asset";

    ($ok, $msg) = $laptop->DeleteLink( Type => 'RefersTo', Base => $ticket->URI );
    ok $ok, "Deleted link from opposite side: $msg";
}

done_testing;
