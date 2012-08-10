use inc::Module::Install;


RTx 'RT-Extension-Assets';
all_from 'lib/RT/Extension/Assets.pm';
readme_from 'lib/RT/Extension/Assets.pm';
license  'gplv2';

sign;
WriteAll;
