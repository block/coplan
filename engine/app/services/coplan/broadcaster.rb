module CoPlan
  module Broadcaster
    class << self
      def prepend_to(streamable, target:, partial:, locals: {})
        Turbo::StreamsChannel.broadcast_prepend_to(streamable, target: target, html: render(partial:, locals:))
      end

      def append_to(streamable, target:, partial:, locals: {})
        Turbo::StreamsChannel.broadcast_append_to(streamable, target: target, html: render(partial:, locals:))
      end

      def replace_to(streamable, target:, html: nil, partial: nil, locals: {})
        html ||= render(partial:, locals:)
        Turbo::StreamsChannel.broadcast_replace_to(streamable, target: target, html: html)
      end

      def update_to(streamable, target:, html:)
        Turbo::StreamsChannel.broadcast_update_to(streamable, target: target, html: html)
      end

      def remove_to(streamable, target:)
        Turbo::StreamsChannel.broadcast_remove_to(streamable, target: target)
      end

      private

      def render(partial:, locals:)
        CoPlan::ApplicationController.render(partial: partial, locals: locals)
      end
    end
  end
end
