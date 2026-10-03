# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# The daemon runs as a systemd --user service, which inherits no locale. Under a
# C/POSIX locale Ruby tags file content US-ASCII, and JSON's C parser then raises
# InvalidByteSequenceError on the first non-ASCII byte in a state file — every
# snapshot read failed for any process started outside an interactive shell.
#
# These tests exercise the tool as a *subprocess* with a minimal environment,
# because the failure only exists there: inside the test process the locale is
# whatever the developer's shell set, which is exactly how it went unnoticed.
class LocaleTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  BIN = File.join(ROOT, "bin", "switchyard")

  # "C" and "POSIX" are the locales a service manager actually hands a process.
  def with_c_locale(env = {})
    base = { "PATH" => "/usr/local/bin:/usr/bin:/bin", "HOME" => Dir.home, "LC_ALL" => "C", "LANG" => "C" }
    yield base.merge(env)
  end

  def run_cli(env, *argv)
    Open3.capture3(env, "/usr/bin/ruby", BIN, *argv)
  end

  # The config is written in-process with an explicit state dir so the test never
  # touches ~/.local/state/switchyard.
  def write_config(dir)
    path = File.join(dir, "config.json")
    config = Switchyard::Core::Config.normalize_config(runtime: { stateDir: File.join(dir, "state") })
    Switchyard::Core::Config.save_config(config, path)
    path
  end

  def test_config_round_trips_under_a_c_locale
    Dir.mktmpdir do |dir|
      path = write_config(dir)
      with_c_locale do |env|
        out, err, status = run_cli(env, "config", "show", "--json", "--config", path)

        assert_equal 0, status.exitstatus, "config show failed: #{err}"
        refute_match(/US-ASCII|InvalidByteSequence/, err)
        assert_equal 1, JSON.parse(out, encoding: Encoding::UTF_8)["version"]
      end
    end
  end

  def test_snapshot_with_non_ascii_content_is_readable_under_a_c_locale
    Dir.mktmpdir do |dir|
      path = write_config(dir)
      with_c_locale do |env|
        # The presenter writes the dot separator into the chip tooltip, so any
        # real snapshot carries non-ASCII bytes.
        _out, err, status = run_cli(env, "daemon", "--once", "--config", path)
        assert_equal 0, status.exitstatus, "one scan failed: #{err}"
        refute_match(/US-ASCII|InvalidByteSequence/, err)
      end

      snapshot = File.join(dir, "state", "snapshot.json")
      assert File.file?(snapshot), "no snapshot written"

      payload = JSON.parse(File.read(snapshot, encoding: Encoding::UTF_8))
      assert payload["view"]["summary"]
      assert_includes payload["view"]["chip"]["tooltipLines"].join("\n"), "\u00b7"
    end
  end

  def test_repos_json_is_readable_under_a_c_locale
    Dir.mktmpdir do |dir|
      path = write_config(dir)
      with_c_locale do |env|
        run_cli(env, "daemon", "--once", "--config", path)
        out, err, status = run_cli(env, "repos", "--json", "--config", path)

        assert_equal 0, status.exitstatus, "repos --json failed: #{err}"
        refute_match(/US-ASCII|InvalidByteSequence/, err)
        view = JSON.parse(out, encoding: Encoding::UTF_8)
        assert view.key?("summary"), "no summary in the projection"
        assert view.key?("units")
      end
    end
  end

  def test_waybar_render_is_readable_under_a_c_locale
    Dir.mktmpdir do |dir|
      path = write_config(dir)
      with_c_locale do |env|
        run_cli(env, "daemon", "--once", "--config", path)
        out, err, status = run_cli(env, "waybar", "render", "--config", path)

        assert_equal 0, status.exitstatus, "waybar render failed: #{err}"
        assert JSON.parse(out, encoding: Encoding::UTF_8)["text"]
      end
    end
  end

  # The non-ASCII the tool ships must survive the round trip, not be stripped.
  def test_non_ascii_survives_the_round_trip
    Dir.mktmpdir do |dir|
      path = write_config(dir)
      with_c_locale do |env|
        run_cli(env, "daemon", "--once", "--config", path)
        out, _err, _status = run_cli(env, "waybar", "render", "--config", path)

        assert_includes out, "\u00b7", "the dot separator was lost or transcoded"
      end
    end
  end

  # The regression itself: an interactive-shell run of the same command worked,
  # a service-manager run did not.
  def test_the_original_repro_is_gone
    Dir.mktmpdir do |dir|
      path = write_config(dir)
      with_c_locale do |env|
        run_cli(env, "daemon", "--once", "--config", path)
        _out, err, status = run_cli(env, "repos", "--config", path)

        assert_equal 0, status.exitstatus
        refute_equal "switchyard: \"\\xC2\" on US-ASCII", err.strip
      end
    end
  end
end

