#!/usr/bin/env perl
use strict;
use warnings;
use feature ':5.10';
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Mojo::JSON qw/decode_json/;
use Infinitude::MQTT;

{
    package MockMQTTClient;

    sub new { bless { messages => [] }, shift }

    sub retain {
        my ($self, $topic, $message) = @_;
        push @{$self->{messages}}, [$topic, $message];
    }

    sub messages { shift->{messages} }

    sub message_for {
        my ($self, $topic) = @_;
        for my $message (reverse @{$self->{messages}}) {
            return $message->[1] if $message->[0] eq $topic;
        }
        return;
    }
}

sub make_mqtt {
    my (%args) = @_;
    my $client = MockMQTTClient->new;
    my $mqtt = bless {
        enabled          => 1,
        serial_telemetry => $args{serial} // 1,
        mqtt             => $client,
        prefix           => 'homeassistant',
        base             => 'infinitude',
    }, 'Infinitude::MQTT';
    return ($mqtt, $client);
}

sub frame {
    my (%args) = @_;
    return {
        cmd        => $args{cmd} // 'reply',
        src        => $args{src} // 'OutdoorUnit2',
        dst        => $args{dst} // 'Thermostat',
        reg_string => $args{register},
        payload    => $args{payload},
    };
}

subtest 'serial telemetry feature flag gates publishing' => sub {
    is(Infinitude::MQTT::_bool('0', 1), 0, 'numeric false config parsed');
    is(Infinitude::MQTT::_bool('false', 1), 0, 'text false config parsed');
    is(Infinitude::MQTT::_bool('1', 0), 1, 'true config parsed');

    my ($mqtt, $client) = make_mqtt(serial => 1);
    ok($mqtt->serial_telemetry_enabled, 'serial telemetry enabled');

    $mqtt->{serial_telemetry} = 0;
    $mqtt->publish_serial_telemetry(frame(
        register => '0303',
        payload  => { suction_pressure_psi => 114 },
    ));
    is(scalar @{$client->messages}, 0, 'serial publisher respects feature flag');
};

subtest 'availability heartbeat always republishes retained online state' => sub {
    my ($mqtt, $client) = make_mqtt();

    $mqtt->publish_availability;
    $mqtt->publish_availability;

    is_deeply(
        $client->messages,
        [
            ['infinitude/status', 'online'],
            ['infinitude/status', 'online'],
        ],
        'online state is not suppressed by an in-memory cache',
    );
};

subtest 'serial discovery can be refreshed after broker state is lost' => sub {
    my ($mqtt, $client) = make_mqtt();
    my $topic = 'homeassistant/sensor/infinitude_serial_indoor_unit_blower_rpm/config';

    $mqtt->publish_serial_telemetry(frame(
        src      => 'IndoorUnit',
        register => '0306',
        payload  => { blower_rpm => 566, airflow_cfm => 504 },
    ));
    my @before = grep { $_->[0] eq $topic } @{$client->messages};
    is(scalar @before, 1, 'discovery initially published once');

    $mqtt->refresh_serial_discovery;
    my @after = grep { $_->[0] eq $topic } @{$client->messages};
    is(scalar @after, 2, 'cached discovery is republished');
    is($after[1][1], $after[0][1], 'refresh preserves the original discovery payload');
};

subtest 'remaining confirmed outdoor and indoor metrics are mapped' => sub {
    my ($mqtt, $client) = make_mqtt();

    $mqtt->publish_serial_telemetry(frame(
        register => '0304',
        payload  => { line_voltage => 243 },
    ));
    $mqtt->publish_serial_telemetry(frame(
        register => '0604',
        payload  => { target_rpm => 3600, current_rpm => 3612 },
    ));
    $mqtt->publish_serial_telemetry(frame(
        register => '060e',
        payload  => { stage => 4, data => [] },
    ));
    $mqtt->publish_serial_telemetry(frame(
        register => '061f',
        payload  => {
            superheat_target  => 7.5,
            superheat_actual  => 10,
            subcooling_target => 14,
            subcooling_actual => 12,
            discharge_delta   => -5.25,
            unknown_constant  => 0.039,
        },
    ));
    $mqtt->publish_serial_telemetry(frame(
        src      => 'IndoorUnit',
        register => '0306',
        payload  => { blower_rpm => 566, airflow_cfm => 504 },
    ));
    $mqtt->publish_serial_telemetry(frame(
        cmd      => 'write',
        src      => 'Thermostat',
        dst      => 'OutdoorUnit2',
        register => '0605',
        payload  => { commanded_stage => 4 },
    ));

    is($client->message_for('infinitude/serial/outdoor_unit_2/line_voltage'), '243', 'line voltage published');
    is($client->message_for('infinitude/serial/outdoor_unit_2/compressor_target_rpm'), '3600', 'target compressor RPM published');
    is($client->message_for('infinitude/serial/outdoor_unit_2/compressor_rpm'), '3612', 'current compressor RPM published');
    is($client->message_for('infinitude/serial/outdoor_unit_2/compressor_stage'), '4', 'compressor stage published');
    is($client->message_for('infinitude/serial/outdoor_unit_2/superheat_target'), '7.5', 'superheat target published');
    is($client->message_for('infinitude/serial/outdoor_unit_2/superheat_actual'), '10', 'superheat actual published');
    is($client->message_for('infinitude/serial/outdoor_unit_2/subcooling_target'), '14', 'subcooling target published');
    is($client->message_for('infinitude/serial/outdoor_unit_2/subcooling_actual'), '12', 'subcooling actual published');
    ok(!defined $client->message_for('infinitude/serial/outdoor_unit_2/discharge_delta'), 'ambiguous discharge delta excluded');
    ok(!defined $client->message_for('infinitude/serial/outdoor_unit_2/unknown_constant'), 'unknown float excluded');
    is($client->message_for('infinitude/serial/indoor_unit/blower_rpm'), '566', 'blower RPM published');
    is($client->message_for('infinitude/serial/indoor_unit/blower_running'), 'ON', 'blower running state derived from RPM');
    is($client->message_for('infinitude/serial/indoor_unit/airflow_cfm'), '504', 'requested airflow published from status register');
    is($client->message_for('infinitude/serial/outdoor_unit_2/compressor_commanded_stage'), '4', 'commanded stage published from write frame');

    my $airflow = decode_json($client->message_for(
        'homeassistant/sensor/infinitude_serial_indoor_unit_airflow_cfm/config'
    ));
    is($airflow->{name}, 'Indoor Unit Requested Airflow', 'airflow discovery describes requested value');

    $mqtt->publish_serial_telemetry(frame(
        src      => 'IndoorUnit',
        register => '0306',
        payload  => { blower_rpm => 0, airflow_cfm => 0 },
    ));
    is($client->message_for('infinitude/serial/indoor_unit/blower_running'), 'OFF', 'zero RPM marks blower stopped');
};

subtest 'outdoor temperatures preserve bus resolution and exclude ambiguous fields' => sub {
    my ($mqtt, $client) = make_mqtt();
    my $payload = {
        outdoor_temp          => 1200,
        coil_temp             => 728,
        suction_temp          => 772,
        subcooling_degf_int   => 224,
        indoor_ambient        => 892,
        discharge_temp        => 2648,
        outdoor_threshold     => 999,
    };

    $mqtt->publish_serial_telemetry(frame(register => '0302', payload => $payload));

    is($client->message_for('infinitude/serial/outdoor_unit_2/outdoor_temperature'), '75', 'outdoor temperature converted to F');
    is($client->message_for('infinitude/serial/outdoor_unit_2/coil_temperature'), '45.5', 'fractional coil temperature retained');
    is($client->message_for('infinitude/serial/outdoor_unit_2/suction_temperature'), '48.25', 'fractional suction temperature retained');
    is($client->message_for('infinitude/serial/outdoor_unit_2/subcooling'), '14', 'subcooling converted to F');
    is($client->message_for('infinitude/serial/outdoor_unit_2/discharge_temperature'), '165.5', 'discharge temperature converted to F');
    ok(!defined $client->message_for('infinitude/serial/outdoor_unit_2/indoor_ambient'), 'ambiguous indoor ambient excluded');
    ok(!defined $client->message_for('infinitude/serial/outdoor_unit_2/outdoor_threshold'), 'constant threshold excluded');

    my $config = decode_json($client->message_for(
        'homeassistant/sensor/infinitude_serial_outdoor_unit_2_outdoor_temperature/config'
    ));
    is($config->{unique_id}, 'infinitude_serial_outdoor_unit_2_outdoor_temperature', 'stable unique ID');
    is($config->{device}{name}, 'Carrier Infinity RS485', 'single telemetry device');
    is($config->{device_class}, 'temperature', 'temperature device class');
    is($config->{state_class}, 'measurement', 'live value is a measurement');
    is($config->{unit_of_measurement}, '°F', 'temperature unit');

    # Subcooling is a ΔT: it must NOT carry a temperature device_class, and it
    # uses a plain-ASCII unit so the downstream Prometheus exporter serializes
    # it (the '°F' + no-device_class combination is silently dropped).
    my $subcool = decode_json($client->message_for(
        'homeassistant/sensor/infinitude_serial_outdoor_unit_2_subcooling/config'
    ));
    ok(!defined $subcool->{device_class}, 'subcooling has no device_class (delta, not absolute temp)');
    is($subcool->{unit_of_measurement}, 'F', 'subcooling uses a plain-ASCII unit');

    my $published = scalar @{$client->messages};
    $mqtt->publish_serial_telemetry(frame(register => '0302', payload => $payload));
    is(scalar @{$client->messages}, $published, 'identical values are suppressed');

    $payload->{outdoor_temp} = 1201;
    $mqtt->publish_serial_telemetry(frame(register => '0302', payload => $payload));
    is(scalar @{$client->messages}, $published + 1, 'only changed value is republished');
    is($client->message_for('infinitude/serial/outdoor_unit_2/outdoor_temperature'), '75.0625', '1/16 F change preserved');
};

subtest 'pressure, frequency, and running state use appropriate discovery types' => sub {
    my ($mqtt, $client) = make_mqtt();

    $mqtt->publish_serial_telemetry(frame(
        register => '0303',
        payload  => { suction_pressure_psi => 114 },
    ));
    is($client->message_for('infinitude/serial/outdoor_unit_2/suction_pressure'), '114', 'suction pressure published');
    my $pressure = decode_json($client->message_for(
        'homeassistant/sensor/infinitude_serial_outdoor_unit_2_suction_pressure/config'
    ));
    is($pressure->{unit_of_measurement}, 'psi', 'pressure unit');
    is($pressure->{device_class}, 'pressure', 'pressure device class');

    $mqtt->publish_serial_telemetry(frame(
        register => '0608',
        payload  => { compressor_frequency_hz => 50.3, saturation => 100 },
    ));
    is($client->message_for('infinitude/serial/outdoor_unit_2/compressor_frequency'), '50.3', 'frequency published');
    is($client->message_for('infinitude/serial/outdoor_unit_2/compressor_running'), 'ON', 'running state published');
    my $running = decode_json($client->message_for(
        'homeassistant/binary_sensor/infinitude_serial_outdoor_unit_2_compressor_running/config'
    ));
    is($running->{payload_on}, 'ON', 'binary payload on configured');
    is($running->{payload_off}, 'OFF', 'binary payload off configured');
    ok(!exists $running->{state_class}, 'binary sensor has no numeric state class');
};

subtest 'known lifetime counters publish and unknown counters do not' => sub {
    my ($mqtt, $client) = make_mqtt();

    $mqtt->publish_serial_telemetry(frame(
        register => '0310',
        payload  => { entry => [
            { name => 'heat_cycles', value => 201 },
            { name => 'unknown_0x99', value => 42 },
        ] },
    ));
    is($client->message_for('infinitude/serial/outdoor_unit_2/heat_cycles'), '201', 'known cycle counter published');
    ok(!defined $client->message_for('infinitude/serial/outdoor_unit_2/unknown_0x99'), 'unknown counter excluded');
    my $cycles = decode_json($client->message_for(
        'homeassistant/sensor/infinitude_serial_outdoor_unit_2_heat_cycles/config'
    ));
    is($cycles->{state_class}, 'total_increasing', 'cycles are total increasing');
    is($cycles->{unit_of_measurement}, 'cycles', 'cycle unit');

    $mqtt->publish_serial_telemetry(frame(
        register => '0311',
        payload  => { entry => [{ name => 'cool_hours', value => 8711 }] },
    ));
    my $hours = decode_json($client->message_for(
        'homeassistant/sensor/infinitude_serial_outdoor_unit_2_cool_hours/config'
    ));
    is($hours->{state_class}, 'total_increasing', 'runtime is total increasing');
    is($hours->{device_class}, 'duration', 'runtime uses duration device class');
    is($hours->{unit_of_measurement}, 'h', 'runtime unit');
};

subtest 'indoor and zone-controller metrics publish conditionally' => sub {
    my ($mqtt, $client) = make_mqtt();

    $mqtt->publish_serial_telemetry(frame(
        src      => 'IndoorUnit',
        register => '0316',
        payload  => { airflow_cfm => 940, unknown4 => 177, electric_heat => 1 },
    ));
    is($client->message_for('infinitude/serial/indoor_unit/airflow_cfm'), '940', 'requested indoor airflow published');
    is($client->message_for('infinitude/serial/indoor_unit/electric_heat_present'), 'ON', 'electric heat active state published');
    is($client->message_for(
        'homeassistant/sensor/infinitude_serial_indoor_unit_electric_heat_airflow_cfm/config'
    ), '', 'obsolete electric heat airflow discovery removed');
    is($client->message_for(
        'infinitude/serial/indoor_unit/electric_heat_airflow_cfm'
    ), '', 'obsolete electric heat airflow state removed');

    my $electric_heat = decode_json($client->message_for(
        'homeassistant/binary_sensor/infinitude_serial_indoor_unit_electric_heat_present/config'
    ));
    is($electric_heat->{name}, 'Indoor Unit Electric Heat Active', 'electric heat discovery describes current activity');

    $mqtt->publish_serial_telemetry(frame(
        src      => 'IndoorUnit',
        register => '031E',
        payload  => { minimum_airflow_cfm => 300 },
    ));
    is($client->message_for('infinitude/serial/indoor_unit/minimum_airflow_cfm'), '300', 'calculated minimum airflow published');

    $mqtt->publish_serial_telemetry(frame(
        src      => 'ZoneControl',
        register => '0302',
        payload  => {
            zone2 => { tag => 1, value => 1102 },
            zone3 => { tag => 0, value => 1200 },
            zone4 => { tag => 1, value => 1184 },
        },
    ));
    is($client->message_for('infinitude/serial/zone_control/zone_2_temperature'), '68.875', 'present zone temperature published');
    ok(!defined $client->message_for('infinitude/serial/zone_control/zone_3_temperature'), 'absent zone skipped');
    is($client->message_for('infinitude/serial/zone_control/zone_4_temperature'), '74', 'second present zone published');

    $mqtt->publish_serial_telemetry(frame(
        src      => 'ZoneControl',
        register => '0319',
        payload  => { zone1 => 15, zone2 => 10, zone3 => 0, zone4 => 7 },
    ));
    is($client->message_for('infinitude/serial/zone_control/zone_1_damper'), 'open', 'open damper published');
    is($client->message_for('infinitude/serial/zone_control/zone_2_damper'), 'transitioning', 'transitioning damper published');
    is($client->message_for('infinitude/serial/zone_control/zone_3_damper'), 'closed', 'closed damper published');
    ok(!defined $client->message_for('infinitude/serial/zone_control/zone_4_damper'), 'unknown damper status skipped');
};

subtest 'unsupported traffic is ignored' => sub {
    my ($mqtt, $client) = make_mqtt();
    $mqtt->publish_serial_telemetry(frame(cmd => 'read', register => '0303', payload => { suction_pressure_psi => 100 }));
    $mqtt->publish_serial_telemetry(frame(src => 'Thermostat', register => '0303', payload => { suction_pressure_psi => 100 }));
    $mqtt->publish_serial_telemetry(frame(cmd => 'write', src => 'Thermostat', dst => 'OutdoorUnit2', register => '0303', payload => { suction_pressure_psi => 100 }));
    $mqtt->publish_serial_telemetry(frame(register => '9999', payload => { value => 100 }));
    my $invalid = frame(register => '0303', payload => { suction_pressure_psi => 100 });
    $invalid->{valid} = 0;
    $mqtt->publish_serial_telemetry($invalid);
    is(scalar @{$client->messages}, 0, 'no messages published');
};

done_testing();
