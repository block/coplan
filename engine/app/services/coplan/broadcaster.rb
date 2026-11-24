module Coplan
  module Broadcaster
    # Prefer partial:/locals: over html: — partials are rendered here in a
    # requestless context. Never pass request-rendered HTML that contains
    # forms via html:: form_with/button_to embed the acting user's session
    # authenticity token, and a broadcast would send that secret to every
    # subscribed viewer. Use html: only for form-free, locale-independent
    # fragments.
    class << self
      def prepend_to(streamable, target:, html: nil, partial: nil, locals: {})
        broadcast_html(streamable, html:, partial:, locals:) do |stream, markup|
          Turbo::StreamsChannel.broadcast_prepend_to(stream, target: target, html: markup)
        end
      end

      def append_to(streamable, target:, html: nil, partial: nil, locals: {})
        broadcast_html(streamable, html:, partial:, locals:) do |stream, markup|
          Turbo::StreamsChannel.broadcast_append_to(stream, target: target, html: markup)
        end
      end

      def replace_to(streamable, target:, html: nil, partial: nil, locals: {})
        broadcast_html(streamable, html:, partial:, locals:) do |stream, markup|
          Turbo::StreamsChannel.broadcast_replace_to(stream, target: target, html: markup)
        end
      end

      # targets: takes a CSS selector, so one render can fill several
      # containers (e.g. the masthead and sticky-nav copies of presence).
      def update_to(streamable, target: nil, targets: nil, html: nil, partial: nil, locals: {})
        broadcast_html(streamable, html:, partial:, locals:) do |stream, markup|
          Turbo::StreamsChannel.broadcast_update_to(stream, target: target, targets: targets, html: markup)
        end
      end

      def remove_to(streamable, target:)
        Turbo::StreamsChannel.broadcast_remove_to(streamable, target: target)
      end

      # Tells every browser watching `streamable` to re-fetch its own page.
      # Carries no content — just the news that there is some.
      #
      # That's the only correct shape for a library listing. What the page
      # shows depends on the viewer (Plan.visible_to bounds every list and
      # every count, so two people in the same folder see different numbers)
      # and on where they are in it (current folder, active filters). There
      # is no one fragment to render once and send to everyone, and the page
      # carries forms, whose tokens are per-session.
      #
      # Turbo tags the stream with the acting request's id, so the browser
      # that caused the change doesn't refresh on top of its own response.
      def refresh_to(streamable)
        Turbo::StreamsChannel.broadcast_refresh_to(streamable)
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
      #
      # changed_sections (section keys from Plans::ChangedSections) rides
      # along so viewing tabs can flash exactly the sections this revision
      # touched instead of hard-swapping the whole body silently.
      def replace_plan_content(plan, changed_sections: nil)
        attrs = { "data-revision" => plan.current_revision }
        attrs["data-changed-sections"] = changed_sections.to_json if changed_sections.present?
        version = plan.current_plan_version
        changes = section_update_changes(plan, changed_sections) if version
        # Anchor ranges move with prose. Load their projection once, then render
        # the discussion controls in the same locale as each document update.
        threads = plan.comment_threads.where.not(anchor_kind: nil).with_kept_comments
          .includes({ comments: { reactions: :user } }, :created_by_user).to_a

        each_ui_stream(plan) do |stream|
          html = render(partial: "coplan/plans/content_body", locals: { plan: plan })
          if version
            details = ApplicationController.helpers.section_update_details(version)
            attrs["data-section-update"] = details.merge(keys: changes.keys, rewritten: changes.rewritten?).to_json
          end
          custom_action_to(stream, action: "coplan-replace-if-clean", target: "plan-content-body", html: html, attrs: attrs)
          updates = threads.map do |thread|
            target = ERB::Util.html_escape(ActionView::RecordIdentifier.dom_id(thread))
            html = render(partial: "coplan/comment_threads/thread_popover", locals: { plan: plan, thread: thread })
            %(<turbo-stream action="replace" target="#{target}"><template>#{html}</template></turbo-stream>)
          end
          Turbo::StreamsChannel.broadcast_stream_to(stream, content: updates.join.html_safe) if updates.any?
        end
      end

      # Reference extraction runs after the version transaction commits. Build
      # and broadcast this projection only then, so open readers receive the
      # newly extracted resources rather than the previous revision's list.
      def replace_plan_references(plan)
        references = plan.references.order(reference_type: :asc, created_at: :desc).to_a
        each_ui_stream(plan) do |stream|
          back_matter = Coplan::ApplicationController.helpers.plan_citation_back_matter(plan, references)
          listed_references = Coplan::ApplicationController.helpers.listed_plan_references(references, back_matter[:cited_urls])
          extracted_references = listed_references.select { |reference| reference.source == "extracted" }
          reference_count = back_matter[:count] + listed_references.size
          extracted_html = render(
            partial: "coplan/plans/reference_list",
            locals: { references: extracted_references, plan: plan, allow_removal: false }
          )
          custom_action_to(
            stream,
            action: "coplan-replace-if-clean",
            target: "plan-citations",
            html: Coplan::ApplicationController.helpers.citation_edit_controls(back_matter[:html]),
            attrs: { "data-revision" => plan.current_revision }
          )
          custom_action_to(
            stream,
            action: "coplan-replace-if-clean",
            target: "plan-extracted-references",
            html: extracted_html,
            attrs: { "data-revision" => plan.current_revision }
          )
          [ "references-count", "nav-references-count" ].each do |target|
            custom_action_to(
              stream,
              action: "coplan-replace-if-clean",
              target: target,
              html: reference_count.positive? ? reference_count : "",
              attrs: { "data-revision" => plan.current_revision }
            )
          end
        end
      end

      def localized_stream(streamable, locale)
        return streamable if Coplan.configuration.ui_locales.one?

        [ streamable, "ui-#{locale}" ]
      end

      private

      def broadcast_html(streamable, html:, partial:, locals:)
        return yield(streamable, html) if html

        each_ui_stream(streamable) { |stream| yield(stream, render(partial:, locals:)) }
      end

      def each_ui_stream(streamable)
        Coplan.configuration.ui_locales.each do |locale|
          I18n.with_locale(locale) { yield localized_stream(streamable, locale) }
        end
      end

      # Some write paths do not request a diff flash. Still update attribution
      # and mark new sections while preserving the extensive-update notice.
      def section_update_changes(plan, changes)
        return changes if changes.respond_to?(:rewritten?)

        previous = plan.plan_versions.where("revision < ?", plan.current_revision).reorder(revision: :desc).first
        Plans::ChangedSections.call(old_content: previous&.content_markdown, new_content: plan.current_content)
      end

      def render(partial:, locals:)
        Coplan::ApplicationController.render(partial: partial, locals: locals)
      end
    end
  end
end
