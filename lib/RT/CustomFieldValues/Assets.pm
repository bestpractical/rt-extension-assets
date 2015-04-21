package RT::CustomFieldValues::Assets; # Replace Assets with Correct Asset Catalog Name

# Activate this CFSource via RT_SiteConfig.pm
# Set(@CustomFieldValuesSources, (qw(RT::CustomFieldValues::Assets))); # Replace Assets with Correct Asset Catalog Name

use base qw(RT::CustomFieldValues::External);
use RT;
use RT::Asset;
use RT::Catalog;

RT::LoadConfig();
RT::Init();
my $at = RT::Asset->new(RT->SystemUser);
my $attype = RT::Catalog->new(RT->SystemUser);

sub SourceDescription {
        return 'Server Assets'; # Replace Servers with Correct Asset Type Name
}

sub ExternalValues {
        my $self = shift;
        my @res;
        my $i = 0;
        my $assets = RT::Assets->new($RT::SystemUser);
        $assets->OrderBy( FIELD => "Name", ORDER => "ASC" );
        $assets->LimitCatalog(
                FIELD    => 'Catalog',
                OPERATOR => '=',
                VALUE       => '1', # Replace by correct Catalog ID
        );
        while (my $asset = $assets->Next) {
                my $assname = $asset->Name;
                push @res,
                        {
                              name => $assname,
                              sortorder   => $i++,
                        };
                }

return \@res;
}

RT::Base->_ImportOverlays();

1;
