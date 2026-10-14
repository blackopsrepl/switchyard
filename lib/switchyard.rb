# frozen_string_literal: true

require_relative "switchyard/core/format"
require_relative "switchyard/core/process"
require_relative "switchyard/core/config"
require_relative "switchyard/core/systemd"
require_relative "switchyard/core/detect"
require_relative "switchyard/core/ports"
require_relative "switchyard/core/probe"
require_relative "switchyard/runtime/state"
require_relative "switchyard/runtime/store"
require_relative "switchyard/runtime/presenter"
require_relative "switchyard/runtime/daemon"
require_relative "switchyard/runtime/quickshell"
require_relative "switchyard/runtime/waybar"
require_relative "switchyard/cli"

module Switchyard
  VERSION = "0.2.0"
end
