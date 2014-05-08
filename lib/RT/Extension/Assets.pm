# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2014 Best Practical Solutions, LLC
#                                          <sales@bestpractical.com>
#
# (Except where explicitly superseded by other copyright notices)
#
#
# LICENSE:
#
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
#
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
#
#
# CONTRIBUTION SUBMISSION POLICY:
#
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
#
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
#
# END BPS TAGGED BLOCK }}}

use strict;
use warnings;
package RT::Extension::Assets;

our $VERSION = '1.01rc1';

# Loaded so they're available and rights are injected.
use RT::Catalog;
use RT::Catalogs;
use RT::Asset;
use RT::Assets;

=head1 NAME

RT-Extension-Assets - Asset management for RT

=cut

RT->AddStyleSheets("RTx-Assets.css");
RT->AddJavaScript("RTx-Assets.js");

{
    package RT::Transaction;
    our %_BriefDescriptions;

    $_BriefDescriptions{"RT::Asset-Set-Catalog"} = sub {
        my $self = shift;
        return ("[_1] changed from [_2] to [_3]",   #loc
                $self->loc($self->Field), map {
                    my $c = RT::Catalog->new($self->CurrentUser);
                    $c->Load($_);
                    $c->Name || $self->loc("~[a hidden catalog~]")
                } $self->OldValue, $self->NewValue);
    };
}

{
    require RT::Interface::Web;
    package HTML::Mason::Commands;

    sub LoadCatalog {
        my $id = shift
            or Abort(loc("No catalog specified."));

        my $catalog = RT::Catalog->new( $session{CurrentUser} );
        $catalog->Load($id);

        Abort(loc("Unable to find catalog [_1]", $id))
            unless $catalog->id;

        Abort(loc("You don't have permission to view this catalog."))
            unless $catalog->CurrentUserCanSee;

        return $catalog;
    }

    sub LoadAsset {
        my $id = shift
            or Abort(loc("No asset ID specified."));

        my $asset = RT::Asset->new( $session{CurrentUser} );
        $asset->Load($id);

        Abort(loc("Unable to find asset #[_1]", $id))
            unless $asset->id;

        Abort(loc("You don't have permission to view this asset."))
            unless $asset->CurrentUserCanSee;

        return $asset;
    }

    sub ProcessRoleMembers {
        my $object = shift;
        my %ARGS   = (@_);
        my @results;

        for my $arg (keys %ARGS) {
            if ($arg =~ /^AddRoleMember-(User|Group)$/) {
                next unless $ARGS{$arg} and $ARGS{"$arg-Type"};

                my ($ok, $msg) = $object->AddRoleMember(
                    Type => $ARGS{"$arg-Type"},
                    $1   => $ARGS{$arg},
                );
                push @results, $msg;
            }
            elsif ($arg =~ /^SetRoleMember-(.+)$/) {
                my $type = $1;
                my $group = $object->RoleGroup($type);
                next unless $group->id and $group->SingleMemberRoleGroup;
                next if $ARGS{$arg} eq $group->UserMembersObj->First->Name;
                my ($ok, $msg) = $object->AddRoleMember(
                    Type => $type,
                    User => $ARGS{$arg} || 'Nobody',
                );
                push @results, $msg;
            }
            elsif ($arg =~ /^RemoveRoleMember-(.+)$/) {
                my ($ok, $msg) = $object->DeleteRoleMember(
                    Type        => $1,
                    PrincipalId => $ARGS{$arg},
                );
                push @results, $msg;
            }
        }
        return @results;
    }


    # If provided a catalog, load it and return the object.
    # If no catalog is passed, load the first active catalog.

    sub LoadDefaultCatalog {
        my $catalog = shift;
        my $catalog_obj = RT::Catalog->new($session{CurrentUser});

        if ( $catalog ){
            $catalog_obj->Load($catalog);
            RT::Logger->error("Unable to load catalog: " . $catalog)
                unless $catalog_obj->Id;
        }
        elsif ( $session{'DefaultCatalog'} ){
            $catalog_obj->Load($session{'DefaultCatalog'});
            RT::Logger->error("Unable to load remembered catalog: " .
                              $session{'DefaultCatalog'})
                unless $catalog_obj->Id;
        }
        elsif ( RT->Config->Get("DefaultCatalog") ){
            $catalog_obj->Load( RT->Config->Get("DefaultCatalog") );
            RT::Logger->error("Unable to load default catalog: "
                              . RT->Config->Get("DefaultCatalog"))
                unless $catalog_obj->Id;
        }
        else {
            # If no catalog, default to the first active catalog
            my $catalogs = RT::Catalogs->new($session{CurrentUser});
            $catalogs->UnLimit;
            $catalog_obj = $catalogs->First();
            RT::Logger->error("No active catalogs.")
                unless $catalog_obj and $catalog_obj->Id;
        }

        return $catalog_obj;
    }

    sub ProcessAssetsSearchArguments {
        my %args = (
            Catalog => undef,
            Assets => undef,
            ARGSRef => undef,
            @_
        );
        my $ARGSRef = $args{'ARGSRef'};

        my @PassArguments;

        if ($ARGSRef->{q}) {
            $args{'Assets'}->SimpleSearch( Term => $ARGSRef->{q}, Catalog => $args{Catalog} );
            push @PassArguments, "q";
        } elsif ( $ARGSRef->{'SearchAssets'} ){
            for my $key (keys %$ARGSRef) {
                my $value = ref $ARGSRef->{$key} ? $ARGSRef->{$key}[0] : $ARGSRef->{$key};
                next unless defined $value and length $value;

                my $orig_key = $key;
                my $negative = ($key =~ s/^!// ? 1 : 0);
                if ($key =~ /^(Name|Description)$/) {
                    $args{'Assets'}->Limit(
                        FIELD => $key,
                        OPERATOR => ($negative ? 'NOT LIKE' : 'LIKE'),
                        VALUE => $value,
                        ENTRYAGGREGATOR => "AND",
                    );
                } elsif ($key =~ /^(Catalog|Status)$/) {
                    $args{'Assets'}->Limit(
                        FIELD => $key,
                        OPERATOR => ($negative ? '!=' : '='),
                        VALUE => $value,
                        ENTRYAGGREGATOR => "AND",
                    );
                } elsif ($key =~ /^Role\.(.+)/) {
                    my $role = $1;
                    $args{'Assets'}->RoleLimit(
                        TYPE      => $role,
                        FIELD     => $_,
                        OPERATOR  => ($negative ? '!=' : '='),
                        VALUE     => $value,
                        SUBCLAUSE => $role,
                        ENTRYAGGREGATOR => ($negative ? "AND" : "OR"),
                        CASESENSITIVE   => 0,
                    ) for qw/EmailAddress Name/;
                } elsif ($key =~ /^CF\.\{(.+?)\}$/ or $key =~ /^CF\.(.*)/) {
                    my $cf = RT::Asset->new( $session{CurrentUser} )
                      ->LoadCustomFieldByIdentifier( $1 );
                    next unless $cf->id;
                    $args{'Assets'}->LimitCustomField(
                        CUSTOMFIELD => $cf->Id,
                        OPERATOR    => ($negative ? "NOT LIKE" : "LIKE"),
                        VALUE       => $value,
                        ENTRYAGGREGATOR => "AND",
                    );
                }
                else {
                    next;
                }
                push @PassArguments, $orig_key;
            }
            push @PassArguments, 'SearchAssets';
        }

        my $Format = RT->Config->Get('AssetSearchFormat') || q[
            '<b><a href="__WebPath__/Asset/Display.html?id=__id__">__id__</a></b>/TITLE:#',
            '<b><a href="__WebPath__/Asset/Display.html?id=__id__">__Name__</a></b>/TITLE:Name',
            Description,
            Status,
        ];

        $ARGSRef->{OrderBy} ||= 'id';
        if ($ARGSRef->{OrderBy} =~ /^CF\.(?:\{(.*)\}|(.*))$/) {
            my $name = $1 || $2;
            my $cf = RT::CustomField->new( $session{'CurrentUser'} );
            $cf->LoadByNameAndCatalog(
                Name => $name,
                Catalog => $args{'Catalog'}->id,
            );
            $ARGSRef->{OrderBy} = [ $cf ];
            $ARGSRef->{Order}   = [ $ARGSRef->{Order} ];
        }

        push @PassArguments, qw/OrderBy Order Page/;

        return (
            OrderBy         => 'id',
            Order           => 'ASC',
            Rows            => 50,
            (map { $_ => $ARGSRef->{$_} } grep { defined $ARGSRef->{$_} } @PassArguments),
            PassArguments   => \@PassArguments,
            Format          => $Format,
        );
    }
}

{
    package RT::CustomField;

    # To someday be merged into RT::CustomField::LoadByName
    sub LoadByNameAndCatalog {
        my $self = shift;
        my %args = (
                    Catalog => undef,
                    Name  => undef,
                    @_,
                   );

        unless ( defined $args{'Name'} && length $args{'Name'} ) {
            $RT::Logger->error("Couldn't load Custom Field without Name");
            return wantarray ? (0, $self->loc("No name provided")) : 0;
        }

        # if we're looking for a catalog by name, make it a number
        if ( defined $args{'Catalog'} && ($args{'Catalog'} =~ /\D/ || !$self->ContextObject) ) {
            my $CatalogObj = RT::Catalog->new( $self->CurrentUser );
            my ($ok, $msg) = $CatalogObj->Load( $args{'Catalog'} );
            if ( $ok ){
                $args{'Catalog'} = $CatalogObj->Id;
            }
            elsif ($args{'Catalog'}) {
                RT::Logger->error("Unable to load catalog " . $args{'Catalog'} . $msg);
                return (0, $msg);
            }
            $self->SetContextObject( $CatalogObj )
              unless $self->ContextObject;
        }

        my $CFs = RT::CustomFields->new( $self->CurrentUser );
        $CFs->SetContextObject( $self->ContextObject );
        my $field = $args{'Name'} =~ /\D/? 'Name' : 'id';
        $CFs->Limit( FIELD => $field, VALUE => $args{'Name'}, CASESENSITIVE => 0);

        # Limit to catalog, if provided. This will also limit to RT::Asset types.
        $CFs->LimitToCatalog( $args{'Catalog'} );

        # When loading by name, we _can_ load disabled fields, but prefer
        # non-disabled fields.
        $CFs->FindAllRows;
        $CFs->OrderByCols(
                          {
                           FIELD => "Disabled", ORDER => 'ASC' },
                         );

        # We only want one entry.
        $CFs->RowsPerPage(1);

        return (0, $self->loc("Not found")) unless my $first = $CFs->First;
        return $self->LoadById( $first->id );
    }

}

{
    package RT::CustomFields;

    sub LimitToCatalog  {
        my $self = shift;
        my $catalog = shift;

        $self->Limit (ALIAS => $self->_OCFAlias,
                      ENTRYAGGREGATOR => 'OR',
                      FIELD => 'ObjectId',
                      VALUE => "$catalog")
          if defined $catalog;

        $self->LimitToLookupType( RT::Asset->CustomFieldLookupType );
        $self->ApplySortOrder;

        unless ($self->ContextObject) {
            my $obj = RT::Catalog->new( $self->CurrentUser );
            $obj->Load( $catalog );
            $self->SetContextObject( $obj );
        }
    }
}

=head1 INSTALLATION

Assets requires version 4.2.1 or higher of RT.

=over

=item perl Makefile.PL

=item make

=item make install

This step may require root permissions.

=item Patch your RT

Assets requires a small patch to work on versions of RT prior to 4.2.3.
To patch RT, run:

    patch -d /opt/rt4 -p1 < patches/rt-4.2.1-4.2.2.patch

RT version 4.2.3 and above already contain this patch.

=item Edit your /opt/rt4/etc/RT_SiteConfig.pm

Add this line:

    Plugin( "RT::Extension::Assets" );

=item make initdb

Only run this the first time you install this module.

If you run this twice, you will end up with duplicate data
in your database.

If you are upgrading this module, check for upgrading instructions
in case changes need to be made to your database.

=item Configure portlets for RT's Homepage and User Summary

If you would like the MyAssets or FindAsset portlets to be available on
RT at a Glance and Dashboards, you will need to copy $HomepageComponents
from RT_Config.pm to RT_SiteConfig.pm and add them to the list.

If you would like the UserAssets portlet to show up on the User
Summary page, you will need to copy @UserSummaryPortlets from RT_Config.pm to
RT_SiteConfig.pm and add UserAssets to the list.

=item Clear your mason cache

    rm -rf /opt/rt4/var/mason_data/obj

=item Restart your webserver


=back

=encoding utf8

=head1 CONFIGURATION

=head2 C<$DefaultCatalog>

Use this to define the default catalog name that will be used when first
searching for assets; thereafter, it will default to the last-searched
catalog. You may use either the catalog's name or its ID. This only
affects the catalog selection on the asset search interface.

=head1 USAGE

Assets start as a small set of fundamental record data upon which you build
custom fields (CFs) of any type you like to describe the assets you want to
track.  By themselves, before you setup any CFs, assets are not very useful.

Just like tickets are assigned to queues, assets are assigned to B<catalogs>.
The default catalog is named "General assets", but we suggest you rename it and
add additional catalogs to better fit your organization.

You may want to use catalogs to separate assets into departments, general type
of asset, hardware vs. software, etc.  Catalogs, like queues, are generally
easiest to work with when there's more than few but less than many dozen.  The
catalog of an asset should represent some fundamental quality of it (and many
other assets!), that could just as easily be expressed as a custom field, but
which is more important than other qualities for categorizing, sorting, and
searching.

=head2 Managing catalogs

Catalogs are managed by RT administrators, or anyone with the L</AdminCatalog>
right.  You can find the list of catalogs, create new catalogs, and manage
existing ones under the Tools → Configuration → Assets → Catalogs menu.

Currently you need to log out and log back in to see changes to catalogs in any
of the catalog selection dropdowns.  This doesn't affect the catalog name
displayed on individual asset pages.

=head2 Adding fields

You can see the current asset CFs by navigating to Admin >
Assets > Custom Fields.  From there you can use the "Create" link to create a
new asset CF.  If you know you want to create a new CF right away, you can do
so via Admin > Assets > Custom Fields > Create.

When creating a CF, be sure to select "Assets" in the "Applies To" dropdown.
You'll also need to grant rights to the groups and/or roles which need to see
the fields, otherwise they'll be hidden.  See the following section.

Similar to ticket CFs, asset custom fields are added globally or to specific
catalogs.  Only assets within those specific catalogs will have the CFs
available.  After creating a CF, you'll need to visit the "Applies To" page to
add it to the catalogs you want or make it global.

=head2 Rights

There are three rights controlling basic access to assets and two for
catalogs.  Each right is grantable at the global level or individual catalog
level, and grantable to system groups, asset roles, user groups, and individual
users (just like ticket and queue rights).

=head3 ShowAsset

Allows viewing an asset record and it's core fields (but not CFs).  Without
it, no assets can be seen.  Similar to ShowTicket.

=head3 CreateAsset

Allows creating assets and filling in the core fields (but not CFs).  Without
it, no assets can be created.  Similar to CreateTicket.

=head3 ModifyAsset

Allows modifying existing assets and their core fields (but not CFs).  Without
it, basic asset data cannot be modified after creation.  Similar to
ModifyTicket.

Most of your rights configuration will be on the CFs, and will likely need to
be done for each CF.  This lets you fine tune which fields are visible to
individual groups and/or roles of users.  Relevant CF rights are
B<SeeCustomField> and B<ModifyCustomField>.

Rights related to assets may also come from the L</Lifecycle statuses>
configuration and restrict status transitions.

=head3 ShowCatalog

Allows seeing a catalog's name and other details when associated with assets.
Without it, users will see "[a hidden catalog]" or a blank space where the
catalog name would normally be.  Similar to SeeQueue.

=head3 AdminCatalog

Allows creating new catalogs and modifying all aspects of existing catalogs,
including changing the CFs associated with the catalog, granting/revoking
rights, and adding/removing role members.  This right should only be granted to
administrators of RT.  Similar to AdminQueue.

=head3 Typical configuration

A typical configuration grants the system Privileged group the following:
B<ShowAsset>, B<CreateAsset>, B<ModifyAsset>, and B<ShowCatalog> globally, and
B<SeeCustomField> and B<ModifyCustomField> globally on all asset CFs.

If you want self service users (Unprivileged) to be able to view the assets
they hold, grant the Held By role B<ShowAsset> and B<ShowCatalog> globally and
B<SeeCustomField> on the necessary asset CFs.

=head2 People and Roles

Just like tickets, assets have various roles which users and groups may be
assigned to.  The intended usages of these roles are described below, but
you're free to use them for whatever you'd like, of course.

The roles provide ways to keep track of who is involved with each asset, as
well as providing a place to grant rights that depend on the user's association
with each asset.

In addition to adding people to individual asset roles, you can also add role
members at an entire catalog level.  These catalog-level roles are useful in
cases when you might have an entire catalog of assets for which the same people
should be the Contacts, or which are Held By the same group.  Unlike tickets
where the queue watchers are invisible, catalog role members are visible
because assets are generally much longer lived than tickets.  When a problem
with an asset arises, it's easier to see who to create a ticket for.  On
individual asset pages, catalog role members are shown with the text "(via this
asset's catalog)" following each name.

=head3 Owner

The person responsible for the asset, perhaps the purchaser or manager.

Restricted to a single user.  Not available at a catalog level.

=head3 Held By

The person or people who physically possess the asset or are actively using the
asset (if it isn't physical).  This may be the same as the Contacts or may be
different.  For example, a computer workstation may be "held by" a university
professor, but the contact may be the IT staff member responsible for all
assets in the professor's department.  This role is most similar to Requestor
on tickets, although not equivalent.

May be multiple users and/or groups.

=head3 Contact

The person or people who should be contacted with questions, problems,
notifications, etc. about the asset.  Contacts share some of the same intended
usages of both Requestors and Ccs on tickets.

May be multiple users and/or groups.

=head2 Lifecycle statuses

One of the basic asset fields is "Status".  Similar to tickets, the valid
statuses and their transitions and actions can be customized via RT's standard
Lifecycles configuration (see "Lifecycles" in F<RT_Config.pm>).  The default
lifecycle is named "assets".  You're free to modify it as much as you'd like,
or add your own lifecycles.  Each catalog may have its own lifecycle.

For the default "assets" configuration, see F<etc/Assets_Config.pm>.

=head2 Field organization

=head3 Groupings

You can organize your asset CFs into visual and logical "groupings" as you see
fit.  These groupings appear as separate boxes on the asset display page and
become separate pages for editing (showing up in the per-asset menu).

By default your CFs will appear in a B<Custom Fields> box on the asset display
page and will be editable from a box of the same name on the B<Basics> editing
page.

Using the C<%CustomFieldGroupings> option (documented in F<etc/RT_Config.pm>),
you can move individual CFs by name into one of the four built-in groupings
(B<Basics>, B<People>, B<Dates>, and B<Links>) or create your own just by
naming it.  An example, assuming a date CF named "Purchased" and two "enter one
value" CFs named "Weight" and "Color":

    # In etc/RT_SiteConfig.pm
    Set(%CustomFieldGroupings,
        'RT::Asset' => {
            'Dates'                 => ['Purchased'],
            'Physical Properties'   => ['Weight', 'Color'],
        },
    );

This configuration snippet will move all three CFs out of the generic B<Custom
Fields> box and into the B<Dates> box and a new box titled B<Physical
Properties>.  The "Purchased" CF will be editable from the Dates page and a new
page titled "Physical Properties" will appear in the menu to allow editing of
the "Weight" and "Color" CFs.

=head3 Ordering

Within a box, CFs come after any built-in asset fields such as Name,
Description, Created, Last Updated, etc.  The CFs themselves are ordered
according to the sorting seen (and adjustable) on the global Asset Custom
Fields page (Tools → Configuration → Global → Custom Fields → Assets) and the
individual catalog Custom Fields pages (Tools → Configuration → Assets →
Catalogs → (Pick one) → Custom Fields).

Global asset CFs may be intermixed with per-catalog CFs with ordering.

=head2 Importing existing data

Another extension, L<RT::Extension::Assets::Import::CSV> provides tools
to import new and update existing assets from a CSV dump.  Its
configuration lets you map the fields in the CSV to the asset fields
you've already created in RT.  L<RT::Extension::Assets::AppleGSX> also
provides tools for looking up data associated with an Apple product.

=head1 METHODS ADDED TO OTHER CLASSES

=head2 L<RT::CustomField>

=head3 LoadByNameAndCatalog

Loads the described asset custom field, if one is found, into the current
object.  This method only consults custom fields applied to L<RT::Catalog> for
L<RT::Asset> objects.

Takes a hash with the keys:

=over

=item Name

A L<RT::CustomField> ID or Name which applies to L<assets|RT::Asset>.

=item Catalog

Optional.  An L<RT::Catalog> ID or Name.

=back

If Catalog is specified, only a custom field added to that Catalog will be loaded.

If Catalog is C<0>, only global asset custom fields will be loaded.

If no Catalog is specified, all asset custom fields are searched including
global and catalog-specific CFs.

Please note that this method may load a Disabled custom field if no others
matching the same criteria are found.  Enabled CFs are preferentially loaded.

=head2 RT::CustomFields

=head3 LimitToCatalog

Takes a numeric L<RT::Catalog> ID.  Limits the L<RT::CustomFields> collection
to only those fields applied directly to the specified catalog.  This limit is
OR'd with other L</LimitToCatalog> and C<LimitToGlobal> calls.

Note that this will cause the collection to only return asset CFs.

=head1 BUGS

Please report bugs to assets-bugs@bestpractical.com; if you're not sure
if what you've discovered is a bug, please discuss it on
rt-users@lists.bestpractical.com before reporting it.

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2014 by Best Practical Solutions

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

1;
