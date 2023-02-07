on configure => sub {

    # These are core in modern perls:
    requires 'JSON::PP';
    requires 'HTTP::Tiny';

    # Non-core:
    requires 'ExtUtils::PkgConfig';
    requires 'ExtUtils::MakeMaker::CPANfile';
    requires 'File::Which';
};

on test => sub {
    requires 'Test::FailWarnings';
    requires 'Test::Fatal';
};

on develop => sub {
    requires 'AnyEvent';
};
