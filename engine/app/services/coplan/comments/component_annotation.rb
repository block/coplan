module CoPlan
  module Comments
    class ComponentAnnotation
      PNG_HEADER = "\x89PNG\r\n\x1a\n".b.freeze
      PNG_END = "\x00\x00\x00\x00IEND\xaeB\x60\x82".b.freeze

      def self.call(comment:, selection:, file:)
        new(comment, selection, file).call
      end

      def initialize(comment, selection, file)
        @comment, @selection, @file = comment, selection, file
      end

      def call
        invalid! unless @comment.comment_thread.anchor_kind == "component" && @selection.is_a?(String) && @selection.bytesize <= 2048
        data = JSON.parse(@selection)
        invalid! unless data.is_a?(Hash)
        region = data.slice("width", "height", "x", "y", "w", "h")
        invalid! unless region.size == 6 && region.values.all? { |v| v.is_a?(Integer) && v.between?(0, 32768) }
        invalid! if region["width"].zero? || region["height"].zero? ||
          region["x"] + region["w"] > region["width"] || region["y"] + region["h"] > region["height"]
        label = data["label"]
        invalid! unless label.nil? || (label.is_a?(String) && label.size <= 160)

        attach_png if @file
        @comment.component_selection = region.merge("label" => label, "image" => @file.present?, "revision" => @comment.comment_thread.plan_version.revision)
      rescue JSON::ParserError
        invalid!
      end

      private

      # Canvas exports a single RGB(A) frame. Keep the pixel stream, discarding
      # optional chunks such as EXIF before the upload reaches Active Storage.
      def attach_png
        invalid! unless @file.is_a?(ActionDispatch::Http::UploadedFile) && @file.size.between?(45, 4.megabytes)
        header = @file.read(33)
        width, height = header[16, 8].unpack("NN")
        depth, color, compression, filter, interlace = header[24, 5].bytes
        invalid! unless header.start_with?(PNG_HEADER + [ 13 ].pack("N") + "IHDR") &&
          width.between?(1, 1536) && height.between?(1, 1536) && depth == 8 &&
          [ 2, 6 ].include?(color) && [ compression, filter, interlace ].all?(&:zero?) &&
          Zlib.crc32(header[12, 17]) == header[29, 4].unpack1("N")

        bytes = header.dup
        expected = height * (1 + width * (color == 2 ? 3 : 4))
        inflater = Zlib::Inflate.new
        loop do
          prefix = @file.read(8)
          invalid! unless prefix&.bytesize == 8
          length, kind = prefix.unpack("Na4")
          invalid! if length > @file.size - @file.tempfile.pos - 4
          chunk = @file.read(length)
          checksum = @file.read(4)
          invalid! unless Zlib.crc32(kind + chunk) == checksum.unpack1("N")
          case kind
          when "IDAT"
            inflater.inflate(chunk) { |part| invalid! if (expected -= part.bytesize).negative? }
            bytes << prefix << chunk << checksum
          when "IEND"
            invalid! unless length.zero? && expected.zero? && inflater.finished? && @file.tempfile.eof?
            break
          else
            invalid! unless kind.match?(/\A[a-z][a-zA-Z]{3}\z/)
          end
        end
        @comment.component_snapshot.attach(io: StringIO.new(bytes << PNG_END), filename: "component.png", content_type: "image/png",
          identify: false, metadata: { analyzed: true, width:, height: })
      rescue Zlib::Error
        invalid!
      ensure
        inflater&.close
      end

      def invalid!
        @comment.errors.add(:base, "The component annotation is invalid. Select the area again.")
        raise ActiveRecord::RecordInvalid, @comment
      end
    end
  end
end
