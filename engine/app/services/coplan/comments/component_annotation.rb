module Coplan
  module Comments
    class ComponentAnnotation
      class UploadError < StandardError; end

      def self.call(comment:, selection:, file:, &block)
        return yield unless selection || file
        new(comment, selection, file).call(&block)
      end

      def initialize(comment, selection, file)
        @comment, @selection, @file = comment, selection, file
      end

      def call
        thread = @comment.comment_thread
        raise ActiveRecord::RecordInvalid, thread unless thread.valid?
        invalid! unless thread.anchor_kind == "component" && @selection.is_a?(String) && @selection.bytesize <= 2048
        @comment.component_selection = parse_selection.merge("image" => @file.present?, "revision" => thread.plan_version.revision)
        attach_png if @file
        yield
      ensure
        @blob&.purge_later unless @comment.persisted?
      end

      private

      def parse_selection
        data = JSON.parse(@selection, max_nesting: 2, create_additions: false)
        invalid! unless data.is_a?(Hash)
        region = data.slice("width", "height", "x", "y", "w", "h")
        invalid! unless region.size == 6 && region.values.all? { |v| v.is_a?(Integer) && v.between?(0, 32768) }
        invalid! if region["width"].zero? || region["height"].zero? ||
          region["x"] + region["w"] > region["width"] || region["y"] + region["h"] > region["height"]
        label = data["label"]
        invalid! unless label.nil? || (label.is_a?(String) && label.size <= 160)
        region.merge("label" => label)
      rescue JSON::ParserError
        invalid!
      end

      def attach_png
        png = CanvasPng.new(@file)
        # Keep the blob handle even if upload fails so the ensure can purge it.
        @blob = ActiveStorage::Blob.create_after_unfurling!(io: png.io, filename: "component.png", content_type: "image/png",
          identify: false, metadata: { analyzed: true, width: png.width, height: png.height })
        begin
          @blob.upload_without_unfurling(png.io)
        rescue StandardError => error
          Rails.error.report(error, handled: true)
          raise UploadError, "Could not save the component image. Your draft is still here. Try again."
        end
        @comment.component_snapshot.attach(@blob)
      rescue CanvasPng::Invalid
        invalid!
      end

      def invalid!
        @comment.errors.add(:base, "The component annotation is invalid. Select the area again.")
        raise ActiveRecord::RecordInvalid, @comment
      end
    end
  end
end
