use strict;
use warnings;

package RT::URI::asset;
use base qw/RT::URI::base/;

use RT::Asset;

=head1 NAME

RT::URI::asset - Internal URIs for linking to an L<RT::Asset>

=head1 DESCRIPTION

This class should rarely be used directly, but via L<RT::URI> instead.

Represents, parses, and generates internal RT URIs such as:

    asset:42
    asset://example.com/42

These URIs are used to link between objects in RT such as associating an asset
with a ticket or an asset with another asset.

=head1 METHODS

Much of the interface below is dictated by L<RT::URI> and L<RT::URI::base>.

=head2 Scheme

Return the URI scheme for assets

=cut

sub Scheme { "asset" }

=head2 LocalURIPrefix

Returns the site-specific prefix for a local asset URI

=cut

sub LocalURIPrefix {
    my $self = shift;
    return $self->Scheme . "://" . RT->Config->Get('Organization') . "/";
}

=head2 IsLocal

Returns a true value, the asset ID, if this object represents a local asset,
undef otherwise.

=cut

sub IsLocal {
    my $self   = shift;
    my $prefix = $self->LocalURIPrefix;
    return $1 if $self->{uri} =~ /^\Q$prefix\E(\d+)/i;
    return undef;
}

=head2 URIForObject RT::Asset

Returns the URI for a local L<RT::Asset> object

=cut

sub URIForObject {
    my $self = shift;
    my $obj  = shift;
    return $self->LocalURIPrefix . $obj->Id;
}

=head2 ParseURI URI

Primarily used by L<RT::URI> to set internal state.

Figures out from an C<asset:> URI whether it refers to a local asset and the
asset ID.

Returns the asset ID if local, otherwise returns false.

=cut

sub ParseURI {
    my $self = shift;
    my $uri  = shift;

    my $scheme = $self->Scheme;

    # canonicalize "42" and "asset:42" -> asset://example.com/42
    if ($uri =~ /^(?:\Q$scheme\E:)?(\d+)$/i) {
        $self->{'uri'} = $self->LocalURIPrefix . $1;
    }
    else {
        $self->{'uri'} = $uri;
    }

    my $asset = RT::Asset->new( $self->CurrentUser );
    if ( my $id = $self->IsLocal ) {
        $asset->Load($id);

        if ($asset->id) {
            $self->{'object'} = $asset;
        } else {
            RT->Logger->error("Can't load Asset #$id by URI '$uri'");
            return;
        }
    }
    return $asset->id;
}

=head2 Object

Returns the object for this URI, if it's local. Otherwise returns undef.

=cut

sub Object {
    my $self = shift;
    return $self->{'object'};
}

=head2 HREF

If this is a local asset, return an HTTP URL for it.

Otherwise, return its URI.

=cut

sub HREF {
    my $self = shift;
    if ($self->IsLocal and $self->Object) {
        return RT->Config->Get('WebURL')
             . "Asset/Display.html?id="
             . $self->Object->Id;
    } else {
        return $self->URI;
    }
}

=head2 AsString

Returns a description of this object

=cut

sub AsString {
    my $self = shift;
    if ($self->IsLocal and $self->Object) {
        return $self->loc('Asset [_1]', $self->Object->id);
    } else {
        return $self->SUPER::AsString(@_);
    }
}

1;
