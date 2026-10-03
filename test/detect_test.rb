# frozen_string_literal: true

require_relative "test_helper"

class DetectTest < Minitest::Test
  def classify(fields, config = build_config)
    Switchyard::Core::Detect.classify(config, fields)
  end

  def test_rails_env_service_is_detected
    result = classify(unit_fields("solverforge-ai.service", exec_start: "{ path=/bin/bash ; argv[]=/bin/bash -lc bundle exec puma -C config/puma.rb ; }"))

    refute_nil result
    assert_equal "rails", result[:kind]
    assert_includes result[:signals], "RAILS_ENV"
    assert_includes result[:signals], "exec:puma"
  end

  def test_bridgetown_service_is_a_site
    result = classify(unit_fields("solverforge-site.service", workdir: "/srv/lab/sites/solverforge.org",
                                                       environment: "",
                                                       exec_start: "{ path=/usr/bin/bundle ; argv[]=/usr/bin/bundle exec bridgetown start --port 1313 ; }"))

    refute_nil result
    assert_equal "site", result[:kind]
  end

  def test_sidekiq_service_is_a_worker
    result = classify(unit_fields("worker.service", exec_start: "{ path=/usr/bin/bundle ; argv[]=/usr/bin/bundle exec sidekiq ; }"))

    assert_equal "worker", result[:kind]
  end

  def test_stopped_rails_unit_is_still_detected
    result = classify(unit_fields("elphame.service", active: "inactive", sub: "dead"))

    refute_nil result
    assert_equal "elphame.service", result[:unit]
  end

  # A Rails app is identified by config/application.rb existing, which also gives
  # the panel an app root to display.
  def test_app_root_requires_config_application_rb
    Dir.mktmpdir do |dir|
      result = classify(unit_fields("app.service", workdir: dir))
      assert_nil result[:appRoot]

      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "")
      result = classify(unit_fields("app.service", workdir: dir))
      assert_equal dir, result[:appRoot]
      assert_includes result[:signals], "rails:config/application.rb"
    end
  end

  def test_excluded_globs_win_over_every_marker
    config = build_config(excludeUnits: ["systemd-*"])
    result = classify(unit_fields("systemd-foo.service"), config)

    assert_nil result
  end

  # A unit that merely runs a Ruby script with no Rails marker is not an
  # environment; one unit of "everything that mentions bundle" would be noise.
  def test_unrelated_ruby_unit_is_skipped
    result = classify(unit_fields("cronbar.service", workdir: "/srv/lab/tools/cronbar",
                                                    environment: "",
                                                    exec_start: "{ path=/usr/bin/ruby ; argv[]=/usr/bin/ruby /home/pvd/.local/bin/cronbar daemon ; }"))

    assert_nil result
  end

  def test_explicit_override_pins_a_unit_with_no_marker
    config = build_config(kinds: { "strange.service" => "rails" }, workdirMarkers: ["/nowhere"])
    result = classify(unit_fields("strange.service", environment: "", exec_start: "{ path=/bin/true ; }"), config)

    refute_nil result
    assert_equal "rails", result[:kind]
    assert result[:override]
  end

  # A working directory under a development root is a location, not a signal.
  # Without this rule a game-server or container stack that happens to live under
  # the same tree is reported as a Rails environment.
  def test_a_dev_root_workdir_alone_is_not_enough
    result = classify(unit_fields("cmangos-classic.service",
                                  workdir: "/srv/lab/hack/cmangos-vanilla",
                                  environment: "HOME=/home/pvd USER=pvd",
                                  exec_start: "{ path=/srv/lab/hack/cmangos-vanilla/scripts/linux/up.sh ; argv[]=/srv/lab/hack/cmangos-vanilla/scripts/linux/up.sh --proxy ; }"))

    assert_nil result
  end

  def test_a_worker_client_is_detected_and_classified
    %w[sidekiq good_job solid_queue delayed_job resque shoryuken].each do |client|
      result = classify(unit_fields("worker.service", exec_start: "{ path=/usr/bin/bundle ; argv[]=/usr/bin/bundle exec #{client} ; }"))

      refute_nil result, "#{client} was not detected"
      assert_equal "worker", result[:kind], "#{client} was classified as #{result[:kind]}"
    end
  end

  def test_a_site_server_is_detected_and_classified
    %w[bridgetown hugo jekyll].each do |client|
      result = classify(unit_fields("site.service", workdir: "/srv/lab/sites/x",
                                                   environment: "",
                                                   exec_start: "{ path=/usr/local/bin/#{client} ; argv[]=/usr/local/bin/#{client} server ; }"))

      refute_nil result, "#{client} was not detected"
      assert_equal "site", result[:kind], "#{client} was classified as #{result[:kind]}"
    end
  end

  def test_sort_puts_rails_before_sites_and_workers
    config = build_config
    rails = classify(unit_fields("z-rails.service"), config)
    site = classify(unit_fields("a-site.service", workdir: "/srv/lab/sites/x", environment: "",
                                                        exec_start: "{ path=/usr/bin/bundle ; argv[]=/usr/bin/bundle exec bridgetown start ; }"), config)
    worker = classify(unit_fields("m-worker.service", exec_start: "{ path=/usr/bin/bundle ; argv[]=/usr/bin/bundle exec sidekiq ; }"), config)

    sorted = Switchyard::Core::Detect.sort([site, worker, rails])

    assert_equal %w[z-rails.service a-site.service m-worker.service], sorted.map { |row| row[:unit] }
  end
end
