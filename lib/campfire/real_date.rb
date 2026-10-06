require "time"

module Campfire
  # The Date header from the real clock when the process clock is faked (the parity harness runs
  # servers under libfaketime, FAKETIME). The reference's Date comes from Thruster, a static Go
  # binary on the real clock; here Iodine is the front server and would stamp the faked one, months
  # old, which makes every cached asset stale on arrival. libfaketime leaves the monotonic clock
  # real, so the real time is the real time at boot plus the monotonic time since.
  class RealDate
    def self.wrap?(env = ENV) = !env["FAKETIME"].to_s.empty?

    def initialize(app)
      @app = app
      @booted_at = Float(IO.popen([ "env", "-u", "LD_PRELOAD", "date", "+%s.%N" ], &:read))
      @booted_at_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def call(env)
      status, headers, body = @app.call(env)
      return [ status, headers, body ] if status == 101 || status == 0 # 0: Iodine's WebSocket upgrade
      headers["date"] = Time.at(@booted_at + Process.clock_gettime(Process::CLOCK_MONOTONIC) - @booted_at_monotonic).httpdate
      [ status, headers, body ]
    end
  end
end
