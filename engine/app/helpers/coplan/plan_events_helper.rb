module CoPlan
  module PlanEventsHelper
    # Render a one-line, human-readable summary of a PlanEvent for the
    # history feed. Each event type gets a tailored "X → Y" or "added X" /
    # "removed X" phrasing instead of a generic field/before/after dump,
    # because the same shape doesn't read well for status changes and tag
    # adds and reference removals.
    def render_event_summary(event)
      case event.event_type
      when "status_changed"
        safe_join([
          "Status: ",
          content_tag(:strong, event.before_value || "—"),
          " → ",
          content_tag(:strong, event.after_value || "—")
        ])
      when "title_changed"
        safe_join([
          "Renamed: ",
          content_tag(:em, event.before_value.to_s.presence || "—"),
          " → ",
          content_tag(:em, event.after_value.to_s.presence || "—")
        ])
      when "plan_type_changed"
        safe_join([
          "Plan type: ",
          content_tag(:strong, event.before_value || "—"),
          " → ",
          content_tag(:strong, event.after_value || "—")
        ])
      when "tag_added"
        safe_join(["Added tag ", content_tag(:code, event.after_value.to_s)])
      when "tag_removed"
        safe_join(["Removed tag ", content_tag(:code, event.before_value.to_s)])
      when "reference_added"
        title = event.metadata.is_a?(Hash) ? event.metadata["title"].presence : nil
        url = event.after_value.to_s
        label = title || url
        safe_join(["Added reference ", link_to(label, url, class: "history-split__event-link", target: "_blank", rel: "noopener")])
      when "reference_removed"
        title = event.metadata.is_a?(Hash) ? event.metadata["title"].presence : nil
        url = event.before_value.to_s
        label = title || url
        safe_join(["Removed reference ", content_tag(:span, label, class: "history-split__event-link")])
      when "attachment_added"
        safe_join(["Added attachment ", content_tag(:code, event.after_value.to_s)])
      when "attachment_removed"
        safe_join(["Removed attachment ", content_tag(:code, event.before_value.to_s)])
      when "comment_deleted"
        preview = event.metadata.is_a?(Hash) ? event.metadata["body_preview"].to_s.presence : nil
        if preview
          safe_join(["Deleted comment: ", content_tag(:em, preview)])
        else
          "Deleted comment"
        end
      else
        # Fallback for unknown / future event types — still useful, never blank.
        "#{event.event_type}: #{event.before_value || "—"} → #{event.after_value || "—"}"
      end
    end
  end
end
