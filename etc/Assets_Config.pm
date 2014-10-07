=head1 NAME

Assets configuration

=head1 Base configuration

=over 4

=item C<Lifecycles>

Each asset catalog uses a lifecycle, exactly as queues for tickets do --
and the configuration is the same.  See L<RT_Config/Lifecycles> for
documentation on them.  Asset lifecycles are differentiated from dicket
lifecycles by their type:

    assets => {
        type     => "asset",     # Note the type, here
        initial  => [ 'new' ],
        active   => [ 'allocated', 'in-use' ],
        inactive => [ 'recycled', 'stolen', 'deleted' ],
        # ...
    }

=cut

Set(%Lifecycles,
    assets => {
        type     => "asset",
        initial  => [ 
            'new' # loc
        ],
        active   => [ 
            'allocated', # loc
            'in-use' # loc
        ],
        inactive => [ 
            'recycled', # loc
            'stolen', # loc
            'deleted' # loc
        ],

        defaults => {
            on_create => 'new',
        },

        transitions => {
            ''        => [qw(new allocated in-use)],
            new       => [qw(allocated in-use stolen deleted)],
            allocated => [qw(in-use recycled stolen deleted)],
            "in-use"  => [qw(allocated recycled stolen deleted)],
            recycled  => [qw(allocated)],
            stolen    => [qw(allocated)],
            deleted   => [qw(allocated)],
        },
        rights => {
            '* -> *'        => 'ModifyAsset',
        },
        actions => {
            '* -> allocated' => { 
                label => "Allocate" # loc
            },
            '* -> in-use'    => { 
                label => "Now in-use" # loc
            },
            '* -> recycled'  => { 
                label => "Recycle" # loc
            },
            '* -> stolen'    => { 
                label => "Report stolen" # loc
            },
        },
    },
) unless $Lifecycles{assets};

=item C<@AssetQueues>

This should be a list of names of queues whose tickets should always
display the "Assets" box.  This is useful for queues which deal
primarily with assets, as it provides a ready box to link an asset to
the ticket, even when the ticket has no related assets yet.

=cut

# Set(@AssetQueues, ());

=item C<$DefaultCatalog>

This provides the default catalog after a user initially logs in.
However, the default catalog is "sticky," and so will remember the
last-selected catalog thereafter.

=cut

# Set($DefaultCatalog, 'General assets');

=item C<$AssetSearchFields>

Specifies which fields of L<RT::Asset> to match against and how to match
each field when performing a quick search on assets.  Valid match
methods are LIKE, STARTSWITH, ENDSWITH, =, and !=.  Valid search fields
are id, Name, Description, or custom fields, which are specified as
"CF.1234" or "CF.Name"

=cut

Set($AssetSearchFields, {
    id          => '=',
    Name        => 'LIKE',
    Description => 'LIKE',
}) unless $AssetSearchFields;

=item C<$AssetSearchFormat>

The format that results of the asset search are displayed with.  This is
either a string, which will be used for all catalogs, or a hash
reference, keyed by catalog's name/id.  If a hashref and neither name or
id is found therein, falls back to the key ''.

If you wish to use the multiple catalog format, your configuration would look
something like:

    Set($AssetSearchFormat, {
        'General assets' => q[Format String for the General Assets Catalog],
        8                => q[Format String for Catalog 8],
        ''               => q[Format String for any catalogs not listed explicitly],
    });

=cut

# loc('Related tickets')
Set($AssetSearchFormat, q[
    '<a href="__WebHomePath__/Asset/Display.html?id=__id__">__Name__</a>/TITLE:Name',
    Description,
    '__Status__ (__Catalog__)/TITLE:Status',
    Owner,
    HeldBy,
    Contacts,
    '__ActiveTickets__ __InactiveTickets__/TITLE:Related tickets',
]) unless $AssetSearchFormat;

=item C<$AssetSummaryFormat>

The information that is displayed on ticket display pages about assets
related to the ticket.  This is displayed in a table beneath the asset
name.

=cut

Set($AssetSummaryFormat, q[
    '<a href="__WebHomePath__/Asset/Display.html?id=__id__">__Name__</a>/TITLE:Name',
    Description,
    '__Status__ (__Catalog__)/TITLE:Status',
    Owner,
    HeldBy,
    Contacts,
    '__ActiveTickets__ __InactiveTickets__/TITLE:Related tickets',
]) unless $AssetSummaryFormat;

=item C<$AssetSummaryRelatedTicketsFormat>

The information that is displayed on ticket display pages about tickets
related to assets related to the ticket.  This is displayed as a list of
tickets underneath the asset properties.

=cut

Set($AssetSummaryRelatedTicketsFormat, q[
    '<a href="__WebPath__/Ticket/Display.html?id=__id__">__id__</a>',
    '(__OwnerName__)',
    '<a href="__WebPath__/Ticket/Display.html?id=__id__">__Subject__</a>',
    QueueName,
    Status,
]) unless $AssetSummaryRelatedTicketsFormat;

=item C<%AdminSearchResultFormat>

The C<Catalogs> key of this standard RT configuration option (see
L<RT_Config/%AdminSearchResultFormat>) controls how catalogs are
displayed in their list in the admin pages.

=cut

Set(%AdminSearchResultFormat,
    Catalogs =>
        q{'<a href="__WebPath__/Admin/Assets/Catalogs/Modify.html?id=__id__">__id__</a>/TITLE:#'}
        .q{,'<a href="__WebPath__/Admin/Assets/Catalogs/Modify.html?id=__id__">__Name__</a>/TITLE:Name'}
        .q{,__Description__,__Lifecycle__,__Disabled__},
) unless $AdminSearchResultFormat{Catalogs};

=item C<$AssetBasicCustomFieldsOnCreate>

Specify a list of Asset custom fields to show in "Basics" widget on create.

e.g.

Set( $AssetBasicCustomFieldsOnCreate, [ 'foo', 'bar' ] );

=cut

# Set($AssetBasicCustomFieldsOnCreate, undef );



=back

=cut

1;
