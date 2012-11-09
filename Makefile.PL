use inc::Module::Install;

RTx 'RT-Extension-Assets';
all_from 'lib/RT/Extension/Assets.pm';
readme_from 'lib/RT/Extension/Assets.pm';
license  'gplv2';

no_index package => "HTML::Mason::Commands";

requires_rt("4.0.0");
test_requires "Test::Warn";

my ($loaded) = ($INC{'RT.pm'} =~ /^(.*)[\\\/]/);
my $lib_path = join( ' ', "$RT::LocalPath/lib", $loaded );

substitute(
    {
        RT_LIB_PATH  => $lib_path,
    },
    {
        sufix => '.in'
    },
    q(xt/lib/RT/Extension/Assets/Test.pm),
);

sign;
WriteAll;
