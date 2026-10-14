# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < Minitest::Test
  def test_ui_state_round_trip_through_the_store
    path = write_test_config
    config = Switchyard::Core::Config.load_config(path)

    Switchyard::Runtime::Store.open_panel(path, "app.service")
    state = Switchyard::Runtime::State.read_ui_state(config)

    assert state[:open]
    assert_equal "app.service", state[:selectedUnit]
  end

  def test_filter_and_query_are_normalized
    path = write_test_config
    config = Switchyard::Core::Config.load_config(path)

    Switchyard::Runtime::Store.set_filter(path, "nonsense")
    assert_equal "all", Switchyard::Runtime::State.read_ui_state(config)[:filter]

    Switchyard::Runtime::Store.set_filter(path, "failed")
    assert_equal "failed", Switchyard::Runtime::State.read_ui_state(config)[:filter]

    Switchyard::Runtime::Store.set_query(path, "rails")
    assert_equal "rails", Switchyard::Runtime::State.read_ui_state(config)[:query]
  end

  def test_detail_tab_is_normalized
    path = write_test_config
    config = Switchyard::Core::Config.load_config(path)

    Switchyard::Runtime::Store.set_detail_tab(path, "logs")
    assert_equal "logs", Switchyard::Runtime::State.read_ui_state(config)[:detailTab]

    Switchyard::Runtime::Store.set_detail_tab(path, "whatever")
    assert_equal "overview", Switchyard::Runtime::State.read_ui_state(config)[:detailTab]
  end

  def test_close_panel_keeps_the_selection
    path = write_test_config
    config = Switchyard::Core::Config.load_config(path)

    Switchyard::Runtime::Store.select_unit(path, "app.service")
    Switchyard::Runtime::Store.close_panel(path)
    state = Switchyard::Runtime::State.read_ui_state(config)

    refute state[:open]
    assert_equal "app.service", state[:selectedUnit]
  end

  def test_scan_writes_a_snapshot_with_a_view
    path = write_test_config(servicePatterns: ["switchyard-no-such-unit.service"])
    snapshot = Switchyard::Runtime::Store.scan_effect(path)

    assert_equal 1, snapshot[:snapshotVersion]
    assert snapshot[:view][:summary]
    assert_equal 0, snapshot[:view][:summary][:total]
  end

  def test_state_event_is_written_on_every_notification
    path = write_test_config
    config = Switchyard::Core::Config.load_config(path)
    Switchyard::Runtime::State.ensure_ui_state(config)
    first = File.read(Switchyard::Runtime::State.state_event_path(config))

    sleep 0.01
    Switchyard::Runtime::State.notify_state_change(config)
    second = File.read(Switchyard::Runtime::State.state_event_path(config))

    refute_equal first, second
  end

  # The event file is the inotify target, so it must be rewritten in place; an
  # atomic rename would drop Quickshell's watch and freeze the panel.
  def test_state_event_file_is_never_renamed
    path = write_test_config
    config = Switchyard::Core::Config.load_config(path)
    Switchyard::Runtime::State.ensure_ui_state(config)
    inode = File.stat(Switchyard::Runtime::State.state_event_path(config)).ino

    Switchyard::Runtime::State.notify_state_change(config)

    assert_equal inode, File.stat(Switchyard::Runtime::State.state_event_path(config)).ino
  end

  def test_scan_lock_is_reentrant_within_a_process_but_serializes_work
    path = write_test_config
    order = []
    mutex = Mutex.new
    started = ConditionVariable.new
    scanner_done = false
    thread = nil

    # Start the scanner only while the lock is held. :started is appended before
    # the scanner reaches the lock, so the holder then has a bounded window to
    # observe that a excluded scan cannot complete: a lock that fails to exclude
    # lets the scan finish under the holder and fails loudly here, while the
    # real flock cannot. The original form raced :holder against thread start-up
    # and flaked in CI.
    Switchyard::Runtime::State.with_scan_lock(Switchyard::Core::Config.load_config(path)) do
      order << :holder
      thread = Thread.new do
        mutex.synchronize do
          order << :started
          started.signal
        end
        Switchyard::Runtime::Store.scan_effect(path)
        mutex.synchronize do
          order << :scanner
          scanner_done = true
        end
      end
      mutex.synchronize { started.wait(mutex, 5) }
      refute mutex.synchronize { scanner_done }, "the scan completed while the scan lock was still held"
    end
    thread.join

    assert_equal %i[holder started scanner], order
  end

  # The chip is a cached renderer with its own poll interval, so without this the
  # bar would lag a restart by up to that interval.
  def test_the_bar_is_signalled_when_the_chip_changes
    path = write_test_config(servicePatterns: ["switchyard-no-such-unit.service"])
    config = Switchyard::Core::Config.load_config(path)
    signals = []

    Switchyard::Runtime::Store.stub(:signal_waybar, ->(c) { signals << c }) do
      # First scan: no previous chip, so the bar is told.
      Switchyard::Runtime::Store.scan_effect(path)
      assert_equal 1, signals.length, "the bar was not signalled on the first scan"

      # Same result again: nothing the chip displays has changed, so no wake-up.
      Switchyard::Runtime::Store.scan_effect(path)
      assert_equal 1, signals.length, "the bar was signalled for an unchanged chip"
    end
  end

  def test_an_unchanged_chip_does_not_signal
    path = write_test_config
    config = Switchyard::Core::Config.load_config(path)
    snapshot = Switchyard::Runtime::State.read_snapshot(config) || Switchyard::Runtime::Store.scan_effect(path)
    signals = []

    Switchyard::Runtime::Store.stub(:signal_waybar, ->(c) { signals << c }) do
      Switchyard::Runtime::Store.notify_bar(config, snapshot, snapshot)
    end

    assert_empty signals
  end
end
