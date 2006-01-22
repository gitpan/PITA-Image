use inc::Module::Install;

name           'PITA-Image';
abstract       'PITA Image Startup and Task Manager';
all_from       'lib/PITA/Image/Manager.pm';
requires       'Carp'             => 0;
requires       'File::Spec'       => '0.80';
requires       'File::Which'      => '0.05';
requires       'File::Remove'     => '0.21';
requires       'Params::Util'     => '0.10';
requires       'Config::Tiny'     => '2.00';
requires       'PITA::Scheme'     => '0.13';
requires       'URI'              => 0;
requires       'LWP'              => '5.69';
build_requires 'Test::More'       => '0.47';

auto_install;
WriteAll;
