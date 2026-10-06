require "zlib"

module Campfire
  # A cached HTML fragment that can also hand out its own gzip-ready deflate block, so pages built
  # from cached messages don't recompress them on every request.
  class Fragment
    attr_reader :html, :key

    def initialize(html, key)
      @html, @key = html.freeze, key
    end

    def bytesize = @html.bytesize
  end

  # A run of consecutive fragments (and the whitespace between them), compressed together once:
  # every view of the same page of messages reuses the block until a message in it changes.
  Run = Data.define(:parts, :key) do
    def html = parts.map { it.is_a?(Fragment) ? it.html : it }.join
  end

  class RunCache
    Entry = Data.define(:deflated, :crc, :bytesize)

    def initialize(limit = 512)
      @limit, @entries = limit, {}
    end

    def fetch(run)
      if (entry = @entries.delete(run.key))
        @entries[run.key] = entry
      else
        html = run.html
        entry = @entries[run.key] = Entry.new(FragmentBody.deflate_block(html), Zlib.crc32(html), html.bytesize)
        @entries.delete(@entries.first[0]) while @entries.size > @limit
        entry
      end
    end

    def self.instance = (@instance ||= new)
  end

  # The page's own text between fragments (layout, nav, composer), compressed once per distinct
  # segment: most of it repeats from request to request.
  class SegmentCache
    Entry = Data.define(:deflated, :crc, :bytesize)

    def initialize(limit = 2048)
      @limit, @entries = limit, {}
    end

    def fetch(segment)
      if (entry = @entries.delete(segment))
        @entries[segment] = entry
      else
        entry = @entries[segment.frozen? ? segment : segment.dup.freeze] =
          Entry.new(FragmentBody.deflate_block(segment), Zlib.crc32(segment), segment.bytesize)
        @entries.delete(@entries.first[0]) while @entries.size > @limit
        entry
      end
    end

    def self.instance = (@instance ||= new)
  end

  # A response body made of literal segments and cached fragments, in order. Plain clients get the
  # pieces as they are; gzip clients get the cached deflate blocks of each run of fragments and of
  # each literal segment.
  class FragmentBody
    MARKER = /\u0001(\d+)\u0002/

    def self.deflate_block(string)
      deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
      block = deflater.deflate(string, Zlib::SYNC_FLUSH)
      deflater.close
      block
    end

    # Splits rendered HTML on the markers View#render_message_cached left for each fragment. Byte
    # offsets: the page has multi-byte characters, so character offsets walk it from the start on
    # every slice.
    def self.from(html, fragments)
      parts = []
      last = 0
      html.scan(MARKER) do
        match = Regexp.last_match
        start, finish = match.byteoffset(0)
        parts << html.byteslice(last, start - last) if start > last
        parts << fragments[match[1].to_i]
        last = finish
      end
      parts << html.byteslice(last, html.bytesize - last) if last < html.bytesize
      new(parts)
    end

    def initialize(parts)
      @parts = parts
    end

    # Groups each maximal sequence of fragments separated only by whitespace into a Run.
    def runs
      grouped = []
      current = []
      flush = lambda do
        trailing = []
        trailing.unshift(current.pop) while current.any? && !current.last.is_a?(Fragment)
        grouped << Run.new(current, current.map { it.is_a?(Fragment) ? it.key : it }) if current.any?
        grouped.concat(trailing)
        current = []
      end
      @parts.each do |part|
        if part.is_a?(Fragment) || (current.any? && part.match?(/\A\s*\z/))
          current << part
        else
          flush.call
          grouped << part
        end
      end
      flush.call
      grouped
    end

    def each
      @parts.each { yield(it.is_a?(Fragment) ? it.html : it) }
    end

    def bytesize
      @parts.sum(&:bytesize)
    end

    def to_s
      @parts.map { it.is_a?(Fragment) ? it.html : it }.join
    end

    # gzip member: header, the concatenated deflate blocks, an empty final block, CRC32 and size.
    def gzip
      out = +"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03".b
      crc = 0
      size = 0
      runs.each do |part|
        if part.is_a?(Run)
          entry = RunCache.instance.fetch(part)
          out << entry.deflated
          crc = Zlib.crc32_combine(crc, entry.crc, entry.bytesize)
          size += entry.bytesize
        else
          entry = SegmentCache.instance.fetch(part)
          out << entry.deflated
          crc = Zlib.crc32_combine(crc, entry.crc, entry.bytesize)
          size += entry.bytesize
        end
      end
      out << "\x03\x00".b
      out << [ crc, size & 0xffffffff ].pack("VV")
    end
  end
end
