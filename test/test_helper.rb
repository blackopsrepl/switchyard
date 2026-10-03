# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tmpdir"
require "switchyard"

module SwitchyardTestHelpers
  def build_config(overrides = {})
    Switchyard::Core::Config.normalize_config(
      { runtime: { stateDir: Dir.mktmpdir },
        localProjects: {} }.merge(overrides)
    )
  end

  def write_test_config(overrides = {})
    dir = Dir.mktmpdir
    path = File.join(dir, "config.json")
    config = Switchyard::Core::Config.normalize_config(
      { runtime: { stateDir: File.join(dir, "state") } }.merge(overrides)
    )
    Switchyard::Core::Config.save_config(config, path)
    path
  end

  # A `systemctl show` field hash as Core::Systemd.parse_show produces it.
  def unit_fields(unit, active: "active", sub: "running", exec_start: nil, workdir: "/srv/lab/dev/app", environment: "RAILS_ENV=development", extra: {})
    {
      "Id" => unit,
      "Description" => "#{unit} description",
      "ActiveState" => active,
      "SubState" => sub,
      "LoadState" => "loaded",
      "UnitFileState" => "enabled",
      "MainPID" => "1000",
      "NRestarts" => "0",
      "ActiveEnterTimestamp" => "Sat 2026-10-03 08:00:00 CEST",
      "ExecMainStartTimestampMonotonic" => "0",
      "WorkingDirectory" => workdir,
      "User" => "pvd",
      "Group" => "",
      "FragmentPath" => "/etc/systemd/system/#{unit}",
      "ExecStart" => exec_start || "{ path=/usr/bin/bundle ; argv[]=/usr/bin/bundle exec rails server -p 3004 ; ignore_errors=no }",
      "Environment" => environment,
      "MemoryCurrent" => "1024",
      "CPUUsageNSec" => "1000000000"
    }.merge(extra)
  end
end

class Minitest::Test
  include SwitchyardTestHelpers
end
