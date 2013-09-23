use strict;
use warnings;
package RT::Extension::Assets;

our $VERSION = '0.01';

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
            $args{'Assets'}->SimpleSearch( Term => $ARGSRef->{q} );
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

        unless ($self->ContextObject) {
            my $obj = RT::Catalog->new( $self->CurrentUser );
            $obj->Load( $catalog );
            $self->SetContextObject( $obj );
        }
    }
}

=head1 INSTALLATION

=over

=item perl Makefile.PL

=item make

=item make install

May need root permissions

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

=head1 CONFIGURATION

=head2 C<$DefaultCatalog>

Use this to define the default catalog name that will be used when first
searching for assets; thereafter, it will defaultto the last-searched
catalog. You may use either the catalog's name or its ID. This only
affects the catalog selection on the asset search interface.

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
OR'd with other L</LimitToCatalog> and L</LimitToGlobal> calls.

Note that this will cause the collection to only return asset CFs.

=head1 AUTHOR

Thomas Sibley <trs@bestpractical.com>

=head1 BUGS

All bugs should be reported via
L<http://rt.cpan.org/Public/Dist/Display.html?Name=RT-Extension-Assets>
or L<bug-RT-Extension-Assets@rt.cpan.org>.


=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2012 by Best Practical Solutions

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

1;
