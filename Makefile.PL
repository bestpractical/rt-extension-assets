use inc::Module::Install;

RTx 'RT-Extension-Assets';
all_from 'lib/RT/Extension/Assets.pm';
readme_from 'lib/RT/Extension/Assets.pm';
license  'gplv2';
perl_version 5.010001;

no_index package => "HTML::Mason::Commands";
no_index package => "RT::Transaction";
no_index package => "RT::CustomField";
no_index package => "RT::CustomFields";

requires_rt("4.2.5");
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

postamble(<<POSTAMBLE
snapshot: dist sign-dist dist-shasums

sign-dist:
	gpg -a --detach-sign \$(DISTVNAME).tar.gz

dist-shasums:
	sha1sum \$(DISTVNAME).tar.gz*

parallel-test: test-parallel

test-parallel:
	RT_TEST_PARALLEL=1 \$(FULLPERLRUN) "-MApp::Prove" -e 'my \$\$p = App::Prove->new(); \$\$p->process_args("-wlrj5","--state=slow,save", "xt"); exit( \$\$p->run() ? 0 : 1 )'
POSTAMBLE
);

sign;
WriteAll;
