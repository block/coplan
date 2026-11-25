module Coplan
  module PlanEventsHelper
    # Who did this, for a history row — same convention as comment authors:
    # "Claude (via Hampton)" when an agent acted for a user, the plain name
    # for the user themselves, the actor_type as a last resort for rows
    # with no resolvable user (system jobs, cloud personas).
    def history_actor_name(item)
      name = item.actor_user&.name || item.actor_type
      item.agent_name.present? ? I18n.t("coplan.common.messages.agent_name_via_user_name", agent_name: item.agent_name, user_name: name) : name
    end

    def section_update_details(version)
      { by: history_actor_name(version), at: version.created_at.iso8601, revision: version.revision,
        ago: I18n.t("coplan.versions.messages.created_at_ago", created_at: time_ago_in_words(version.created_at)) }
    end

    # Render a one-line, human-readable summary of a PlanEvent for the
    # history feed. Each event type gets a tailored "X → Y" or "added X" /
    # "removed X" phrasing instead of a generic field/before/after dump,
    # because the same shape doesn't read well for status changes and tag
    # adds and reference removals.
    def render_event_summary(event)
      case event.event_type
      when "published"
        I18n.t("coplan.versions.messages.published_listed_for_everyone")
      when "archived"
        I18n.t("coplan.common.messages.archived")
      when "unarchived"
        I18n.t("coplan.versions.messages.restored_from_archive")
      when "status_changed"
        safe_join([
          I18n.t("coplan.versions.messages.status"),
          content_tag(:strong, event.before_value || "—"),
          " → ",
          content_tag(:strong, event.after_value || "—")
        ])
      when "title_changed"
        safe_join([
          I18n.t("coplan.versions.messages.renamed"),
          content_tag(:em, event.before_value.to_s.presence || "—"),
          " → ",
          content_tag(:em, event.after_value.to_s.presence || "—")
        ])
      when "plan_type_changed"
        safe_join([
          I18n.t("coplan.versions.messages.plan_type"),
          content_tag(:strong, event.before_value || "—"),
          " → ",
          content_tag(:strong, event.after_value || "—")
        ])
      when "tag_added"
        safe_join([ I18n.t("coplan.versions.messages.added_tag"), content_tag(:code, event.after_value.to_s) ])
      when "tag_removed"
        safe_join([ I18n.t("coplan.versions.messages.removed_tag"), content_tag(:code, event.before_value.to_s) ])
      when "reference_added"
        title = event.metadata.is_a?(Hash) ? event.metadata["title"].presence : nil
        url = event.after_value.to_s
        label = title || url
        safe_join([ I18n.t("coplan.versions.messages.added_reference"), link_to(label, url, class: "history-split__event-link", target: "_blank", rel: "noopener") ])
      when "reference_removed"
        title = event.metadata.is_a?(Hash) ? event.metadata["title"].presence : nil
        url = event.before_value.to_s
        label = title || url
        safe_join([ I18n.t("coplan.versions.messages.removed_reference"), content_tag(:span, label, class: "history-split__event-link") ])
      when "attachment_added"
        safe_join([ I18n.t("coplan.versions.messages.added_attachment"), content_tag(:code, event.after_value.to_s) ])
      when "attachment_removed"
        safe_join([ I18n.t("coplan.versions.messages.removed_attachment"), content_tag(:code, event.before_value.to_s) ])
      when "moved_to_folder"
        if event.after_value.present?
          safe_join([ I18n.t("coplan.versions.messages.moved_to_folder"), content_tag(:strong, event.after_value) ])
        else
          safe_join([ I18n.t("coplan.versions.messages.removed_from_folder"), content_tag(:strong, event.before_value.to_s) ])
        end
      when "review_requested"
        safe_join([ I18n.t("coplan.versions.messages.requested_a_review_from"), content_tag(:strong, event.metadata["reviewer_name"]),
                    " · v#{event.metadata["revision"]}" ])
      when "review_removed"
        safe_join([ I18n.t("coplan.versions.messages.removed_reviewer"), content_tag(:strong, event.metadata["reviewer_name"]), I18n.t("coplan.versions.messages.past_decisions_preserved") ])
      when "review_withdrawn"
        safe_join([ I18n.t("coplan.versions.messages.withdrew_the_review_request_for"), content_tag(:strong, event.metadata["reviewer_name"]) ])
      when "comment_deleted"
        I18n.t("coplan.versions.messages.deleted_comment")
      when "comment_permanently_deleted"
        I18n.t("coplan.versions.messages.permanently_deleted_comment")
      else
        "#{event.event_type}: #{event.before_value || "—"} → #{event.after_value || "—"}"
      end
    end
  end
end
