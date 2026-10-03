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
    thread = Thread.new do
      Switchyard::Runtime::Store.scan_effect(path)
      order << :scanner
    end
    Switchyard::Runtime::State.with_scan_lock(Switchyard::Core::Config.load_config(path)) { order << :holder }
    thread.join

    assert_equal %i[holder scanner], order
  end
end
