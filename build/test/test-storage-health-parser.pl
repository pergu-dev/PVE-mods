#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use File::Spec;
use Test::More;

BEGIN {
    my $parser_path = File::Spec->catfile(
        $FindBin::Bin,
        '..',
        '..',
        'src',
        'modules',
        'node_info',
        'files',
        'StorageHealth',
        'Parser.pm',
    );

    require $parser_path;

    PVE::PVEMods::StorageHealth::Parser->import(
        qw(
            parse_smart_json
            parse_zpool_status
            aggregate_health
        )
    );
}

sub read_fixture {
    my ($name) = @_;
    my $path = File::Spec->catfile($FindBin::Bin, '..', '..', 'tests', 'fixtures', 'storage_health', $name);
    open my $fh, '<', $path or die "Failed to open fixture $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

my $ata = parse_smart_json(read_fixture('smart-ata-hdd-healthy.json'));
is($ata->{severity}, 'ok', 'healthy ATA HDD is OK');
is($ata->{issue_count}, 0, 'healthy ATA HDD has no issues');
is($ata->{details}{power_on_hours}, 77889, 'high power-on hours remain informational');

my $sas = parse_smart_json(read_fixture('smart-sas-uncorrected-read.json'));
is($sas->{severity}, 'warning', 'SAS uncorrected reads produce a warning');
is($sas->{issue_count}, 1, 'SAS fixture produces one normalized issue');
is($sas->{issues}[0]{details}{uncorrected_read_errors}, 9, 'SAS uncorrected read count is preserved');
is($sas->{issues}[0]{details}{grown_defects}, 259, 'SAS grown defect count is preserved');
like($sas->{message}, qr/9 uncorrected read errors/, 'SAS message identifies uncorrected reads');

my $zfs = parse_zpool_status(read_fixture('zpool-online-vdev-read-error.txt'));
is($zfs->{severity}, 'warning', 'online ZFS pool with vdev errors is a warning');
is($zfs->{issue_count}, 1, 'ZFS fixture produces one normalized issue');
is($zfs->{issues}[0]{details}{read_errors}, 1, 'ZFS read error count is preserved');
like($zfs->{message}, qr/POOL_01: device errors READ=1/, 'ZFS message identifies READ counter');

my $aggregate = aggregate_health($ata, $sas, $zfs);
is($aggregate->{severity}, 'warning', 'aggregate selects warning severity');
is($aggregate->{issue_count}, 2, 'aggregate contains SMART and ZFS issues');
is($aggregate->{issues}[0]{rank}, 85, 'higher-ranked ZFS issue is first');
like($aggregate->{message}, qr/POOL_01/, 'aggregate message uses highest-ranked issue');

done_testing();
