package PVE::PVEMods::Collector::StorageHealth;

use strict;
use warnings;
use Exporter 'import';
use Cwd qw(abs_path);
use File::Path qw(make_path);
use JSON qw(decode_json);

use PVE::PVEMods::Config qw(
    %config $process_type
    $storage_health_state_file
    $storage_health_cache_dir
    $storage_health_smart_cache
);
use PVE::PVEMods::Utils qw(
    debug setup_collector_signals
    safe_read_json safe_write_json_atomic
);
use PVE::PVEMods::StorageHealth::Parser qw(
    parse_smart_json parse_zpool_status aggregate_health
);

our @EXPORT_OK = qw(
    collector_for_storage_health
    collect_storage_health_once
);

sub _run_command {
    my (@command) = @_;

    # Collector processes inherit the worker's SIGCHLD handler. Restore
    # default child handling locally so close() can reap this command and
    # report its actual exit status.
    local $SIG{CHLD} = 'DEFAULT';

    my $pid = open(my $fh, '-|');
    return {
        output      => '',
        exit_status => 255,
    } unless defined $pid;

    if ($pid == 0) {
        open STDERR, '>', '/dev/null';
        exec @command;
        exit 127;
    }

    local $/;
    my $output = <$fh> // '';

    close $fh;
    my $status = $?;

    my $exit_status;

    if ($status == -1) {
        $exit_status = 255;
    } elsif ($status & 127) {
        $exit_status = 128 + ($status & 127);
    } else {
        $exit_status = $status >> 8;
    }

    return {
        output      => $output,
        exit_status => $exit_status,
    };
}

sub _discover_devices {
    my $result = _run_command('/usr/sbin/smartctl', '--scan');
    my @devices;

    for my $line (split /\n/, $result->{output}) {
        next unless $line =~ m{^(/dev/[A-Za-z0-9._/-]+)(?:\s+-d\s+(\S+))?};
        push @devices, {
            path      => $1,
            scan_type => $2,
        };
    }

    return \@devices;
}

sub _sysfs_path {
    my ($device_path) = @_;

    return ''
        unless $device_path =~ m{^/dev/([A-Za-z0-9._-]+)$};

    my $path = abs_path(
        "/sys/class/block/$1/device"
    );

    return defined $path ? $path : '';
}

sub _is_ata_device {
    my ($device) = @_;
    return 1 if ($device->{scan_type} // '') =~ /^(?:ata|sat)$/;
    return _sysfs_path($device->{path}) =~ m{/ata\d+/};
}

sub _smart_command {
    my ($device, $no_wake) = @_;
    my @command = ('/usr/sbin/smartctl', '-a', '-j');
    push @command, ('-n', 'standby') if $no_wake && _is_ata_device($device);
    push @command, $device->{path};
    return @command;
}

sub _decode_smart_json {
    my ($text) = @_;
    my $data;
    eval { $data = decode_json($text); };
    return $@ || ref($data) ne 'HASH' ? undef : $data;
}

sub _identity_for {
    my ($data, $path) = @_;
    return $path unless ref($data) eq 'HASH';
    return $data->{serial_number}
        // $data->{nvme_eui64}
        // $data->{nvme_nguid}
        // $data->{logical_unit_id}
        // $path;
}

sub _cache_entry_for_path {
    my ($cache, $path) = @_;
    for my $identity (keys %{$cache->{devices} // {}}) {
        my $entry = $cache->{devices}{$identity};
        return ($identity, $entry) if ($entry->{last_path} // '') eq $path;
    }
    return;
}

sub _collect_smart {
    my ($now, $cache) = @_;
    my @results;
    my @drives;
    my $interval = $config{storage_health}{smart_interval} + 0;
    my $stale_after = $config{storage_health}{smart_stale_after} + 0;

    for my $device (@{_discover_devices()}) {
        my ($cached_identity, $cached) = _cache_entry_for_path($cache, $device->{path});
        my $last_success = $cached ? ($cached->{last_success} // 0) : 0;
        my $due = !$cached || ($now - $last_success >= $interval);
        my $collection_state = $cached ? 'cached' : 'never_collected';
        my $smart_json = $cached ? $cached->{smart_json} : undef;
        my $exit_status = $cached ? $cached->{exit_status} : undef;

        if ($due) {
            my $initial = !$cached;
            my $wake = $initial
                ? $config{storage_health}{wake_for_initial_baseline}
                : $config{storage_health}{wake_for_periodic_check};
            my $no_wake = _is_ata_device($device) && !$wake;
            my $query = _run_command(_smart_command($device, $no_wake));
            my $decoded = _decode_smart_json($query->{output});

            if ($decoded && $decoded->{device}) {
                my $power = $decoded->{power_mode}{name} // '';
                my $skipped = $no_wake && $power =~ /STANDBY|SLEEP/i
                    && !exists $decoded->{smart_status};

                if ($skipped) {
                    $collection_state = 'sleeping';
                } else {
                    my $identity = _identity_for($decoded, $device->{path});
                    $smart_json = $query->{output};
                    $exit_status = $query->{exit_status};
                    $last_success = $now;
                    $collection_state = 'queried';

                    delete $cache->{devices}{$cached_identity}
                        if defined $cached_identity && $cached_identity ne $identity;
                    $cache->{devices}{$identity} = {
                        last_path    => $device->{path},
                        protocol     => $decoded->{device}{protocol} // $decoded->{device}{type},
                        last_success => $last_success,
                        exit_status  => $exit_status,
                        smart_json   => $smart_json,
                    };
                    $cached_identity = $identity;
                }
            } else {
                $collection_state = $cached ? 'query_failed_cached' : 'query_failed';
            }
        }

        my $parsed = defined $smart_json
            ? parse_smart_json($smart_json)
            : parse_smart_json(undef);

        $parsed->{details}{smartctl_exit_status} =
            $exit_status
            if defined $exit_status;

        push @results, $parsed;

        push @drives, {
            identity         => $cached_identity // $device->{path},
            path             => $device->{path},
            scan_type        => $device->{scan_type},
            ata_no_wake      => _is_ata_device($device) ? 1 : 0,
            collection_state => $collection_state,
            last_success     => $last_success + 0,
            stale            => $last_success && ($now - $last_success > $stale_after) ? 1 : 0,
            exit_status      => $exit_status,
            health           => $parsed,
        };
    }

    return (\@results, \@drives);
}

sub collect_storage_health_once {
    my $now = time();
    make_path($storage_health_cache_dir, { mode => 0755 })
        unless -d $storage_health_cache_dir;

    my $cache = safe_read_json($storage_health_smart_cache, 0);
    $cache = { version => 1, devices => {} } unless ref($cache) eq 'HASH';
    $cache->{devices} = {} unless ref($cache->{devices}) eq 'HASH';

    my $zpool = _run_command('/usr/sbin/zpool', 'status', '-gLP');
    my $zfs = parse_zpool_status($zpool->{output});
    my ($smart_results, $drives) = _collect_smart($now, $cache);
    my $aggregate = aggregate_health($zfs, @$smart_results);

    $cache->{updated_at} = $now;
    safe_write_json_atomic($storage_health_smart_cache, $cache, 1);

    my $state = {
        generated_at => $now,
        severity     => $aggregate->{severity},
        message      => $aggregate->{message},
        issue_count  => $aggregate->{issue_count},
        issues       => $aggregate->{issues},
        zfs          => $zfs,
        drives       => $drives,
    };

    safe_write_json_atomic($storage_health_state_file, $state, 1);
    return $state;
}

sub collector_for_storage_health {
    $process_type = 'collector';
    $0 = 'collector-storage-health';

    my $shutdown = 0;
    setup_collector_signals('storage-health', \$shutdown);
    my $last_zfs = 0;
    my $interval = $config{storage_health}{zfs_interval} + 0;
    $interval = 15 if $interval < 1;

    while (!$shutdown) {
        my $now = time();
        if (!$last_zfs || $now - $last_zfs >= $interval) {
            eval { collect_storage_health_once(); };
            debug(__LINE__, "Storage health collection failed: $@") if $@;
            $last_zfs = $now;
        }
        select(undef, undef, undef, 0.5) unless $shutdown;
    }

    exit 0;
}

1;
