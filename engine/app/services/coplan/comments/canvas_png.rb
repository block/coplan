module Coplan
  module Comments
    # Canvas exports an 8-bit RGB(A) PNG. Validate that limited format before
    # storage, discard metadata, and bound both compressed and inflated bytes.
    class CanvasPng
      class Invalid < StandardError; end
      SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
      END_CHUNK = "\x00\x00\x00\x00IEND\xaeB\x60\x82".b.freeze

      attr_reader :width, :height, :io

      def initialize(file)
        raise Invalid unless file.is_a?(ActionDispatch::Http::UploadedFile) && file.size.between?(45, 4.megabytes)
        @input = StringIO.new(file.read)
        raise Invalid unless @input.read(8) == SIGNATURE
        header = read_chunk
        raise Invalid unless header.first == "IHDR" && header.last.bytesize == 13
        @width, @height, depth, color, compression, filter, interlace = header.last.unpack("NNC5")
        raise Invalid unless width.between?(1, 1536) && height.between?(1, 1536) && depth == 8 &&
          [ 2, 6 ].include?(color) && [ compression, filter, interlace ].all?(&:zero?)

        pixels = read_pixel_stream
        validate_pixels(pixels, width * (color == 2 ? 3 : 4) + 1)
        @io = StringIO.new(SIGNATURE + encode_chunk(*header) + encode_chunk("IDAT", pixels) + END_CHUNK)
      end

      private

      def read_chunk
        prefix = @input.read(8)
        raise Invalid unless prefix&.bytesize == 8
        size, type = prefix.unpack("Na4")
        raise Invalid if size > @input.size - @input.pos - 4
        payload = @input.read(size)
        raise Invalid unless @input.read(4).unpack1("N") == Zlib.crc32(payload, Zlib.crc32(type))
        [ type, payload ]
      end

      def read_pixel_stream
        pixels = +"".b
        # A browser canvas needs few chunks. Bound per-chunk work as well as size.
        4096.times do
          type, payload = read_chunk
          case type
          when "IDAT" then pixels << payload
          when "IEND"
            raise Invalid unless payload.empty? && @input.eof?
            return pixels
          else
            raise Invalid unless type.match?(/\A[a-z][A-Za-z]{3}\z/)
          end
        end
        raise Invalid
      end

      def validate_pixels(pixels, stride)
        inflater = Zlib::Inflate.new
        count = 0
        inflater.inflate(pixels) do |part|
          raise Invalid if count + part.bytesize > stride * height
          # The first byte of each scanline selects a PNG filter (0..4).
          ((-count) % stride).step(part.bytesize - 1, stride) { |offset| raise Invalid if part.getbyte(offset) > 4 }
          count += part.bytesize
        end
        raise Invalid unless count == stride * height && inflater.finished? && inflater.total_in == pixels.bytesize
      rescue Zlib::Error
        raise Invalid
      ensure
        inflater&.close
      end

      def encode_chunk(type, payload)
        [ payload.bytesize ].pack("N") + type + payload + [ Zlib.crc32(payload, Zlib.crc32(type)) ].pack("N")
      end
    end
  end
end
