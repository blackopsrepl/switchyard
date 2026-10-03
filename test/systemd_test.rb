# frozen_string_literal: true

require_relative "test_helper"

class SystemdTest < Minitest::Test
  def test_show_parses_blocks_separated_by_a_blank_line
    text = <<~OUT
      Id=elphame.service
      ActiveState=inactive
      SubState=dead

      Id=sabbatic.service
      ActiveState=active
      SubState=running
    OUT

    fields = Switchyard::Core::Systemd.parse_show(text)

    assert_equal %w[elphame.service sabbatic.service], fields.keys
    assert_equal "inactive", fields["elphame.service"]["ActiveState"]
  end

  def test_exec_argv_splits_the_argv_field
    argv = Switchyard::Core::Systemd.exec_argv("{ path=/usr/bin/bundle ; argv[]=/usr/bin/bundle exec rails server -p 3004 ; ignore_errors=no ; }")

    assert_equal ["/usr/bin/bundle", "exec", "rails", "server", "-p", "3004"], argv
  end

  # `sudo -n` + `systemctl` must become `sudo -n systemctl …`. Treating the
  # prefix as flags-only ran `systemctl -n …`, which fails silently and reads
  # as "this host has no units".
  def test_privilege_prefix_contributes_its_executable
    config = Switchyard::Core::Config.normalize_config(systemctlPrefix: "sudo -n", systemctlBin: "systemctl")
    bin, args = Switchyard::Core::Systemd.command_parts(config)

    assert_equal "sudo", bin
    assert_equal ["-n", "systemctl"], args
  end

  def test_empty_prefix_runs_the_binary_directly
    config = Switchyard::Core::Config.normalize_config(systemctlPrefix: "", systemctlBin: "systemctl")
    bin, args = Switchyard::Core::Systemd.command_parts(config)

    assert_equal "systemctl", bin
    assert_equal [], args
  end

  def test_journal_uses_the_journalctl_pair
    config = Switchyard::Core::Config.normalize_config(journalctlPrefix: "sudo -n", journalctlBin: "journalctl")
    bin, args = Switchyard::Core::Systemd.command_parts(config, journal: true)

    assert_equal "sudo", bin
    assert_equal ["-n", "journalctl"], args
  end

  def test_show_args_uses_the_double_dash_for_multiple_units
    config = Switchyard::Core::Config.default_config
    args = Switchyard::Core::Systemd.show_args(config, %w[a.service b.service])

    assert_includes args, "--"
    assert_equal %w[a.service b.service], args.last(2)
  end

  def test_show_args_has_no_double_dash_for_one_unit
    config = Switchyard::Core::Config.default_config
    args = Switchyard::Core::Systemd.show_args(config, ["a.service"])

    refute_includes args, "--"
    assert_equal "a.service", args.last
  end

  # systemd restarts a crash-looping unit so fast that ActiveEnterTimestamp can
  # be empty in the `show` output; the monotonic stamp is the fallback.
  def test_start_timestamp_falls_back_to_the_monotonic_stamp
    now = Time.now
    uptime_us = Switchyard::Core::Systemd.monotonic_uptime_us
    fields = { "ActiveEnterTimestamp" => "", "ExecMainStartTimestampMonotonic" => (uptime_us - 5_000_000).to_i.to_s }

    stamp = Switchyard::Core::Systemd.start_timestamp(fields, now: now)
    parsed = Time.parse(stamp)

    assert_in_delta 5, now - parsed, 2
  end

  def test_start_timestamp_prefers_the_explicit_timestamp
    fields = { "ActiveEnterTimestamp" => "Sat 2026-10-03 08:00:00 CEST", "ExecMainStartTimestampMonotonic" => "1" }

    assert_equal "Sat 2026-10-03 08:00:00 CEST", Switchyard::Core::Systemd.start_timestamp(fields)
  end
end
