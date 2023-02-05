use strict;
use warnings;
use autodie;

use Config;

use ExtUtils::MakeMaker::CPANfile;
use ExtUtils::PkgConfig;
use File::Temp;

my $ASAN = 0;

my $PC_MODULE = 'libmongoc-1.0';

my $version = ExtUtils::PkgConfig->modversion($PC_MODULE);

if (!$version) {
    die "pkg-config did not find $PC_MODULE; is it installed?$/";
}

my $libs = ExtUtils::PkgConfig->libs($PC_MODULE);
my $cflags = ExtUtils::PkgConfig->cflags($PC_MODULE) || q<>;

my $lddlflags = $Config{'lddlflags'};

if ($ASAN) {
    $cflags .= " -fsanitize=address";
    $lddlflags .= " -fsanitize=address";
}

print "Fetching error strings from your MongoC …\n";
system $^X, 'extract_errors.pl' and exit 1;
print "Got error strings. Proceeding …\n";

# The following should compile & link:
my $check_c = <<END;
#include <mongoc/mongoc.h>

int main() {
    void* foo = mongoc_client_pool_new_with_error;
    return 0;
}
END

{
    print "Verifying that your mongoc is recent enough …$/";

    my $dir = File::Temp::tempdir( CLEANUP => 1 );

    my $source_path = File::Spec->catfile($dir, 'test.c');
    my $target_path = File::Spec->catfile($dir, 'test');

    {
        open my $cfh, '>', $source_path;
        syswrite $cfh, $check_c;
    }

    system( "$Config{'cc'} $cflags $source_path -o $target_path $libs" ) and do {
        die "Failed to build test binary: Is your mongoc recent enough?\n";
    };
}

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

    LDDLFLAGS => $lddlflags,

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
