use ExtUtils::MakeMaker;
WriteMakefile(
    NAME              => 'CCCP::SQLiteWrap',
    VERSION_FROM      => 'lib/CCCP/SQLiteWrap.pm',
    PREREQ_PM         => {
                           DBI => 0,
                           File::Temp => 0,
                           File::Copy => 0,
                           Data::UUID => 0,
                           Digest::MD5 => 0
    },
    AUTHOR         => 'mr.Rico <catamoose@yandex.ru>'
);
