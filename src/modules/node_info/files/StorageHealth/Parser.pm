package PVE::PVEMods::StorageHealth::Parser;

use strict;
use warnings;
use Exporter 'import';
use JSON qw(decode_json);

our @EXPORT_OK = qw(
    parse_smart_json
    parse_zpool_status
    aggregate_health
);

my %SEVERITY_WEIGHT = (
    ok       => 0,
    warning  => 1,
    critical => 2,
);

sub _result {
    my ($issues, $details) = @_;
    $issues //= [];
    $details //= {};

    my @sorted = sort { ($b->{rank} // 0) <=> ($a->{rank} // 0) } @$issues;
    my $severity = 'ok';

    for my $issue (@sorted) {
        my $candidate = $issue->{severity} // 'warning';
        if (($SEVERITY_WEIGHT{$candidate} // 0) > ($SEVERITY_WEIGHT{$severity} // 0)) {
            $severity = $candidate;
        }
    }

    return {
        ok          => @sorted ? 0 : 1,
        severity    => $severity,
        issue_count => scalar(@sorted),
        message     => @sorted ? $sorted[0]{message} : 'OK',
        issues      => \@sorted,
        details     => $details,
    };
}

sub parse_smart_json {
    my ($json_text) = @_;

    return _result([{
        severity => 'warning', rank => 20, source => 'smart',
        message => 'SMART data unavailable', details => { reason => 'empty input' },
    }]) unless defined $json_text && length $json_text;

    my $data;
    eval { $data = decode_json($json_text); };
    if ($@ || ref($data) ne 'HASH') {
        return _result([{
            severity => 'warning', rank => 20, source => 'smart',
            message => 'SMART data unavailable', details => { reason => 'invalid JSON' },
        }]);
    }

    my $device = $data->{device} // {};
    my $protocol = $device->{protocol} // $device->{type} // 'unknown';
    my $serial = $data->{serial_number} // $device->{name} // 'unknown device';
    my @issues;

    my $smart_passed =
        exists $data->{smart_status}
        && ref($data->{smart_status}) eq 'HASH'
        && exists $data->{smart_status}{passed}
        ? $data->{smart_status}{passed}
        : undef;

    if (defined $smart_passed && !$smart_passed) {
        push @issues, {
            severity => 'critical', rank => 90, source => 'smart', device => $serial,
            message => "$serial: SMART health check failed",
            details => { protocol => $protocol },
        };
    }

    my $grown_defects = $data->{scsi_grown_defect_list} // 0;
    my $scsi_errors = ref($data->{scsi_error_counter_log}) eq 'HASH'
        ? $data->{scsi_error_counter_log} : {};
    my $read_errors = ref($scsi_errors->{read}) eq 'HASH'
        ? ($scsi_errors->{read}{total_uncorrected_errors} // 0) : 0;
    my $write_errors = ref($scsi_errors->{write}) eq 'HASH'
        ? ($scsi_errors->{write}{total_uncorrected_errors} // 0) : 0;

    if ($read_errors > 0 || $write_errors > 0) {
        my @parts;
        push @parts, "$read_errors uncorrected read " . ($read_errors == 1 ? 'error' : 'errors')
            if $read_errors > 0;
        push @parts, "$write_errors uncorrected write " . ($write_errors == 1 ? 'error' : 'errors')
            if $write_errors > 0;

        push @issues, {
            severity => 'warning', rank => 80, source => 'smart', device => $serial,
            message => "$serial: " . join(', ', @parts),
            details => {
                protocol => $protocol,
                grown_defects => $grown_defects + 0,
                uncorrected_read_errors => $read_errors + 0,
                uncorrected_write_errors => $write_errors + 0,
            },
        };
    }

    return _result(\@issues, {
        device => $serial,
        protocol => $protocol,
        smart_passed => $smart_passed,
        grown_defects => $grown_defects + 0,
        power_on_hours => ref($data->{power_on_time}) eq 'HASH'
            ? $data->{power_on_time}{hours} : undef,
    });
}

sub parse_zpool_status {
    my ($status_text) = @_;

    return _result([{
        severity => 'warning', rank => 20, source => 'zfs',
        message => 'ZFS status unavailable', details => { reason => 'empty input' },
    }]) unless defined $status_text && length $status_text;

    my (@issues, @pools);
    my $current;
    my $in_config = 0;

    for my $line (split /\n/, $status_text) {
        if ($line =~ /^\s*pool:\s+(\S+)/) {
            $current = {
                name => $1, state => 'UNKNOWN', max_read => 0,
                max_write => 0, max_checksum => 0,
            };
            push @pools, $current;
            $in_config = 0;
            next;
        }
        next unless $current;

        if ($line =~ /^\s*state:\s+(\S+)/) {
            $current->{state} = uc($1);
            next;
        }
        if ($line =~ /^config:/) {
            $in_config = 1;
            next;
        }
        if ($line =~ /^errors:\s+(.+)/) {
            $current->{errors_text} = $1;
            $in_config = 0;
            next;
        }
        next unless $in_config;

        if ($line =~ /^\s+(\S+)\s+(ONLINE|DEGRADED|FAULTED|OFFLINE|REMOVED|UNAVAIL)\s+(\d+)\s+(\d+)\s+(\d+)/) {
            my ($name, $state, $read, $write, $checksum) = ($1, $2, $3, $4, $5);
            $current->{max_read} = $read if $read > $current->{max_read};
            $current->{max_write} = $write if $write > $current->{max_write};
            $current->{max_checksum} = $checksum if $checksum > $current->{max_checksum};
            if ($state =~ /^(REMOVED|FAULTED|UNAVAIL|OFFLINE)$/) {
                push @{$current->{device_states}}, { name => $name, state => $state };
            }
        }
    }

    for my $pool (@pools) {
        my ($pool_name, $state) = @{$pool}{qw(name state)};

        if ($state eq 'FAULTED' || $state eq 'UNAVAIL') {
            push @issues, {
                severity => 'critical', rank => 95, source => 'zfs', pool => $pool_name,
                message => "$pool_name $state", details => { state => $state },
            };
        } elsif ($state eq 'DEGRADED') {
            push @issues, {
                severity => 'warning', rank => 90, source => 'zfs', pool => $pool_name,
                message => "$pool_name DEGRADED", details => { state => $state },
            };
        }

        for my $device (@{$pool->{device_states} // []}) {
            push @issues, {
                severity => 'warning', rank => 90, source => 'zfs',
                pool => $pool_name, device => $device->{name},
                message => "$pool_name: $device->{name} $device->{state}",
                details => { state => $device->{state} },
            };
        }

        my ($read, $write, $checksum) = @{$pool}{qw(max_read max_write max_checksum)};
        if ($read > 0 || $write > 0 || $checksum > 0) {
            my @parts;
            push @parts, "READ=$read" if $read > 0;
            push @parts, "WRITE=$write" if $write > 0;
            push @parts, "CKSUM=$checksum" if $checksum > 0;
            push @issues, {
                severity => 'warning', rank => 85, source => 'zfs', pool => $pool_name,
                message => "$pool_name: device errors " . join(', ', @parts),
                details => {
                    read_errors => $read + 0,
                    write_errors => $write + 0,
                    checksum_errors => $checksum + 0,
                    state => $state,
                },
            };
        }

        if (defined $pool->{errors_text} && $pool->{errors_text} !~ /^No known data errors$/i) {
            push @issues, {
                severity => 'critical', rank => 100, source => 'zfs', pool => $pool_name,
                message => "$pool_name: permanent data errors",
                details => { errors => $pool->{errors_text} },
            };
        }
    }

    return _result(\@issues, { pools => \@pools });
}

sub aggregate_health {
    my (@results) = @_;
    my (@issues, @sources);

    for my $result (@results) {
        next unless ref($result) eq 'HASH';
        push @sources, $result;
        push @issues, @{$result->{issues}} if ref($result->{issues}) eq 'ARRAY';
    }

    return _result(\@issues, { sources => \@sources });
}

1;
