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
                    User => $ARGS{$arg},
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
            else{
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
    }
}

=head1 INSTALLATION

=over

=item perl Makefile.PL

=item make

=item make install

May need root permissions

=item make initdb

Only run this the first time you install this module.

If you run this twice, you will end up with duplicate data
in your database.

If you are upgrading this module, check for upgrading instructions
in case changes need to be made to your database.

=item Edit your /opt/rt4/etc/RT_SiteConfig.pm

Add this line:

    Set(@Plugins, qw(RT::Extension::Assets));

or add C<RT::Extension::Assets> to your existing C<@Plugins> line.

=item Clear your mason cache

    rm -rf /opt/rt4/var/mason_data/obj

=item Restart your webserver

=back

=head1 METHODS ADDED TO OTHER CLASSES

=head2 RT::CustomField::LoadByNameAndCatalog (Catalog => CATALOGID, Name => NAME)

Loads the Custom field named NAME.

Will load a Disabled Custom Field even if there is a non-disabled Custom Field
with the same Name.

If a Catalog parameter is specified, only look for asset custom fields tied to that Catalog.

If the Catalog parameter is '0', look for global asset custom fields.

If no Catalog parameter is specified, look for any and all custom fields
with this name, limiting the results to catalog/asset CFs.

=head2 RT::CustomFields::LimitToCatalog (CATALOGID)

Takes a numeric C<CATALOGID>, and limits the Custom Field collection to
those only applied directly to it; this limit is OR'd with other
L</LimitToCatalog> and L</LimitToGlobal> limits.

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
