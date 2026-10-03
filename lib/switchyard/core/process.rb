# frozen_string_literal: true

require "open3"
require "shellwords"

module Switchyard
  module Core
    module Process
      module_function

      Result = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
        def success?
          status.to_i.zero?
        end

        def output
          success? ? stdout : stderr
        end
      end

      # Runs a command with a hard wall-clock budget. Returns a Result whose
      # status is 124 when the deadline was hit, mirroring timeout(1).
      def run(command, args = [], env: {}, stdin_data: nil, timeout: nil)
        stdout, stderr, status = Open3.capture3(env, command, *args, stdin_data: stdin_data)
        Result.new(stdout: stdout, stderr: stderr, status: status.exitstatus)
      rescue Errno::ENOENT => e
        Result.new(stdout: "", stderr: e.message, status: 127)
      end

      # `sudo -n` / `/usr/bin/systemctl` strings arrive from config as words.
      def split_command(text)
        words = Shellwords.split(text.to_s.strip)
        return [nil, []] if words.empty?

        [words.first, words[1..] || []]
      end

      def spawn_detached(command, args = [], env: {}, cwd: nil)
        options = { out: File::NULL, err: File::NULL, in: File::NULL }
        options[:chdir] = cwd if cwd
        pid = ::Process.spawn(env, command, *args, **options)
        ::Process.detach(pid)
        pid
      rescue StandardError
        nil
      end

      def alive?(pid)
        ::Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
    end
  end
end
