# frozen_string_literal: true

require_relative "test_helper"

class PortsTest < Minitest::Test
  SAMPLE = <<~OUT
    LISTEN 0      1024         0.0.0.0:1313       0.0.0.0:*    users:(("ruby.ruby3.4",pid=1550,fd=8))
    LISTEN 0      4096       127.0.0.1:3000       0.0.0.0:*    users:(("rootlessport",pid=5525,fd=10))
    LISTEN 0      4096         0.0.0.0:3002       0.0.0.0:*
    LISTEN 0      128            [::1]:8080          [::]:*    users:(("node",pid=42,fd=3))
    State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
  OUT

  def test_parses_ports_pids_and_wildcard_addresses
    ports = Switchyard::Core::Ports.parse(SAMPLE)

    assert_equal 1313, ports[1313][:port]
    assert_equal 1550, ports[1313][:pid]
    assert_equal "ruby.ruby3.4", ports[1313][:command]
    assert_equal "127.0.0.1", ports[1313][:host]
  end

  # A socket whose owner is not readable (another uid) must still list its port;
  # dropping it would silently hide a service the operator can see in `ss`.
  def test_socket_without_an_owner_still_reports_the_port
    ports = Switchyard::Core::Ports.parse(SAMPLE)

    assert_equal 3002, ports[3002][:port]
    assert_nil ports[3002][:pid]
  end

  def test_parses_ipv6_loopback
    ports = Switchyard::Core::Ports.parse(SAMPLE)

    assert_equal 8080, ports[8080][:port]
    assert_equal "127.0.0.1", ports[8080][:host]
    assert_equal 42, ports[8080][:pid]
  end

  def test_header_line_is_not_a_port
    ports = Switchyard::Core::Ports.parse(SAMPLE)

    assert_equal [1313, 3000, 3002, 8080], ports.keys.sort
  end

  def test_wildcard_detection
    assert Switchyard::Core::Ports.wildcard?("0.0.0.0")
    assert Switchyard::Core::Ports.wildcard?("::")
    refute Switchyard::Core::Ports.wildcard?("127.0.0.1")
  end

  # `unit_pids` is keyed by the full unit name; appending ".service" internally
  # made every lookup miss and blanked every port in the snapshot.
  def test_unit_pids_uses_the_full_unit_name
    assert_equal [], Switchyard::Core::Ports.unit_pids("definitely-not-a-real-unit.service")
  end
end
