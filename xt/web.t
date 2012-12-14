use strict;
use warnings;

use lib 'xt/lib';
use RT::Extension::Assets::Test tests => undef;

RT->Config->Set("CustomFieldGroupings",
    "RT::Asset" => {
        Dates => [qw(Purchased)],
    },
);

my $purchased = create_cf( Name => 'Purchased', Pattern => '(?#Year)^(?:19|20)\d{2}$' );
ok $purchased->id, "Created CF";

my $height = create_cf( Name => 'Height', Pattern => '(?#Inches)^\d+"?$' );
ok $height->id, "Created CF";

my $material = create_cf( Name => 'Material' );
ok $material->id, "Created CF";

my %CF = (
    Height      => ".CF-" . $height->id    . "-Edit",
    Material    => ".CF-" . $material->id  . "-Edit",
    Purchased   => ".CF-" . $purchased->id . "-Edit",
);

my ($base, $m) = RT::Extension::Assets::Test->started_ok;
ok $m->login, "Logged in agent";

diag "Create basic asset (no CFs)";
{
    $m->follow_link_ok({ id => "assets-create" }, "Asset create link");
    $m->submit_form_ok({
        with_fields => {
            id          => 'new',
            Name        => 'Thinkpad T420s',
            Description => 'A laptop',
        },
    }, "submited create form");
    $m->content_like(qr/Asset .* created/, "Found created message");
    my ($id) = $m->uri =~ /id=(\d+)/;

    my $asset = RT::Asset->new( RT->SystemUser );
    $asset->Load($id);
    is $asset->id, $id, "id matches";
    is $asset->Name, "Thinkpad T420s", "Name matches";
    is $asset->Description, "A laptop", "Description matches";
}

diag "Create with CFs";
{
    ok apply_cfs($height, $material), "Applied CFs";

    $m->follow_link_ok({ id => "assets-create" }, "Asset create link");
    ok $m->form_with_fields(qw(id Name Description)), "Found form";
    $m->submit_form_ok({
        fields => {
            id              => 'new',
            Name            => 'Standing desk',
            $CF{Height}     => 'forty-six inches',
            $CF{Material}   => 'pine',
        },
    }, "submited create form");
    $m->content_unlike(qr/Asset .* created/, "Lacks created message");
    $m->content_like(qr/must match .*?Inches/, "Found validation error");

    # Intentionally fix only the invalid CF to test the other fields are
    # preserved across errors
    ok $m->form_with_fields(qw(id Name Description)), "Found form again";
    $m->set_fields( $CF{Height} => '46"' );
    $m->submit_form_ok({}, "resubmitted form");

    $m->content_like(qr/Asset .* created/, "Found created message");
    my ($id) = $m->uri =~ /id=(\d+)/;

    my $asset = RT::Asset->new( RT->SystemUser );
    $asset->Load($id);
    is $asset->id, $id, "id matches";
    is $asset->FirstCustomFieldValue('Height'), '46"', "Found height";
    is $asset->FirstCustomFieldValue('Material'), 'pine', "Found material";
}

diag "Create with CFs in other groups";
{
    ok apply_cfs($purchased), "Applied CF";

    $m->follow_link_ok({ id => "assets-create" }, "Asset create link");
    ok $m->form_with_fields(qw(id Name Description)), "Found form";

    my $has_purchased = $m->current_form->find_input($CF{Purchased});

    $m->submit_form_ok({
        fields => {
            id          => 'new',
            Name        => 'Chair',
            $CF{Height} => '23',
        },
    }, "submited create form");

    TODO: {
        local $TODO = "We validate too much on create, even CFs which aren't displayed.";
        if ($has_purchased) {
            $m->content_unlike(qr/Asset .* created/, "Lacks created message");
            $m->content_like(qr/Purchased.*?must match .*?Year/, "Has validation error for Purchased");
        } else {
            $m->content_like(qr/Asset .* created/, "Found created message");
            $m->content_unlike(qr/Purchased.*?must match .*?Year/, "Lacks validation error for Purchased");
        }
    }
}

# XXX TODO: test other modify pages

undef $m;
done_testing;
