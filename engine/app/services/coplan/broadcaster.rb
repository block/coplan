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

      # Broadcasts a custom turbo-stream action that the client may apply
      # conditionally. Used by live-content-update: the client checks for
      # unsaved drafts before swapping the body, otherwise shows a "reload"
      # banner so the user doesn't lose typed-but-unsent text.
      #
      # We don't go through Turbo::StreamsChannel's helpers because they
      # only emit the built-in actions (replace/update/append/etc.); a custom
      # action requires building the <turbo-stream> element ourselves.
      def custom_action_to(streamable, action:, target:, html:, attrs: {})
        attr_string = attrs.map { |k, v| %( #{k}="#{ERB::Util.html_escape(v)}") }.join
        stream = %(<turbo-stream action="#{action}" target="#{target}"#{attr_string}><template>#{html}</template></turbo-stream>)
        Turbo::StreamsChannel.broadcast_stream_to(streamable, content: stream.html_safe)
      end

      # Convenience wrapper for the most common content-mutation broadcast:
      # push the freshly rendered plan body to every open tab, letting the
      # client decide whether to apply it (clean) or show a stale-revision
      # banner (dirty draft in progress).
      def replace_plan_content(plan)
        html = render(partial: "coplan/plans/content_body", locals: { plan: plan })
        custom_action_to(
          plan,
          action: "coplan-replace-if-clean",
          target: "plan-content-body",
          html: html,
          attrs: { "data-revision" => plan.current_revision }
        )
      end

      private

      def render(partial:, locals:)
        CoPlan::ApplicationController.render(partial: partial, locals: locals)
      end
    end
  end
end
