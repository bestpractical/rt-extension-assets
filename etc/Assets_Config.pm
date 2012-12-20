Set(%Lifecycles,
    assets => {
        type     => "asset",
        initial  => [ 'new' ],
        active   => [ 'allocated', 'in-use' ],
        inactive => [ 'recycled', 'stolen', 'deleted' ],

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

        actions => {
            '* -> allocated' => { label => "Allocate" },
            '* -> in-use'    => { label => "Now in-use" },
            '* -> recycled'  => { label => "Recycle" },
            '* -> stolen'    => { label => "Report stolen" },
        },
    },
);
