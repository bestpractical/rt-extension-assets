use strict;
use warnings;
package RT::Extension::Assets;

our $VERSION = '0.01';

use RT::Asset;  # Load so it's available and rights are injected
use RT::Assets;

=head1 NAME

RT-Extension-Assets - Asset management for RT

=cut

RT->AddStyleSheets("RTx-Assets.css");
RT->AddJavaScript("RTx-Assets.js");

{
    use RT::CustomField;
    my $ORIGINAL = RT::CustomField->can('ApplyGlobally');
    no warnings 'redefine';
    *RT::CustomField::ApplyGlobally = sub {
        my $self = shift;
        return 1 if lc($self->LookupType) eq lc("RT::Asset");
        return $ORIGINAL->($self);
    };
}

{
    require RT::Interface::Web;
    package HTML::Mason::Commands;

    sub LoadAsset {
        my $id = shift
            or Abort(loc("No asset ID specified."));

        my $asset = RT::Asset->new( $session{CurrentUser} );
        $asset->Load($id);

        Abort(loc("Unable to find asset #[_1]", $id))
            unless $asset->id;

        Abort(loc("You don't have permission to modify this asset."))
            unless $asset->CurrentUserHasRight("ModifyAsset");

        return $asset;
    }

    sub ProcessAssetPeople {
        my $asset = shift;
        my %ARGS  = (@_);
        my @results;

        for my $arg (keys %ARGS) {
            if ($arg =~ /^AddRoleMember-(User|Group)$/) {
                next unless $ARGS{$arg} and $ARGS{"$arg-Type"};

                my ($ok, $msg) = $asset->AddRoleMember(
                    Type => $ARGS{"$arg-Type"},
                    $1   => $ARGS{$arg},
                );
                push @results, $msg;
            }
            elsif ($arg =~ /^RemoveRoleMember-(.+)$/) {
                my ($ok, $msg) = $asset->DeleteRoleMember(
                    Type        => $1,
                    PrincipalId => $ARGS{$arg},
                );
                push @results, $msg;
            }
        }
        return @results;
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
