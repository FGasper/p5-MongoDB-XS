use strict;
use warnings;

use Config;

use ExtUtils::MakeMaker::CPANfile;
use ExtUtils::PkgConfig;
use File::Temp;

my $PC_MODULE = 'libmongoc-1.0';

my $version = ExtUtils::PkgConfig->modversion($PC_MODULE);

if (!$version) {
    die "pkg-config did not find $PC_MODULE; is it installed?$/";
}

my $libs = ExtUtils::PkgConfig->libs($PC_MODULE);
my $cflags = ExtUtils::PkgConfig->cflags($PC_MODULE) || q<>;

print "Fetching error strings from your MongoC …\n";
system $^X, 'extract_errors.pl' and exit 1;
print "Got error strings. Proceeding …\n";

#----------------------------------------------------------------------

WriteMakefile(
    NAME              => 'MongoDB::XS',
    VERSION_FROM      => 'lib/MongoDB/XS.pm', # finds $VERSION
    ABSTRACT_FROM  => 'lib/MongoDB/XS.pm', # retrieve abstract from module
    AUTHOR         => [
        'Felipe Gasper (FELIPE)',
    ],

    LICENSE => "perl_5",

    INC => join(
        q< >,
        '-Wall',
        '-std=c99',
        $cflags,
    ),

    OBJECT => [
        '$(BASEEXT)$(OBJ_EXT)',
        'courier.o',
    ],

    LIBS => $libs,

    PMLIBDIRS => ['lib'],

    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources => {
            repository => {
                type => 'git',
                url => 'git://github.com/FGasper/p5-MongoDB-XS.git',
                web => 'https://github.com/FGasper/p5-MongoDB-XS',
            },
            bugtracker => {
                web => 'https://github.com/FGasper/p5-MongoDB-XS/issues',
            },
        },
    },
);

#----------------------------------------------------------------------
