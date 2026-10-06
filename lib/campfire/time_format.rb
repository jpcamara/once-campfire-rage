module Campfire
  # Rails stores datetimes in SQLite as UTC text: "2026-03-02 15:55:00" or with microseconds.
  module TimeFormat
    module_function

    def parse(text)
      return nil if text.nil?
      year, month, day = text[0, 4].to_i, text[5, 2].to_i, text[8, 2].to_i
      hour, minute, second = text[11, 2].to_i, text[14, 2].to_i, text[17, 2].to_i
      usec = text.size > 20 ? text[20, 6].ljust(6, "0").to_i : 0
      Time.utc(year, month, day, hour, minute, second, usec)
    end

    # What Rails writes: microsecond precision.
    def dump(time)
      time.utc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    end

    def now_text
      dump(Time.now)
    end

    # Time#iso8601 / TimeWithZone#iso8601: whole seconds, "Z" for UTC.
    def iso8601(text)
      "#{text[0, 10]}T#{text[11, 8]}Z"
    end

    # to_fs(:epoch): (time.to_f * 1000).to_i
    def epoch_ms(text)
      time = parse(text)
      (time.to_f * 1000).to_i
    end

    # to_fs(:number)
    def number(text)
      "#{text[0, 4]}#{text[5, 2]}#{text[8, 2]}#{text[11, 2]}#{text[14, 2]}#{text[17, 2]}"
    end
  end
end
