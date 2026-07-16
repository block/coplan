module CoPlan
  module AttachmentsHelper
    # Uploader identity is stamped into the blob metadata at upload time (see
    # Plans::AddAttachment) because ActiveStorage has no user association of
    # its own. The name captured at upload time is rendered as-is — a live
    # User lookup would cost a query per attachment just to reflect renames.
    def attachment_uploader_name(blob)
      (blob.metadata || {})["uploaded_by_name"].presence
    end

    # Markdown snippet for embedding an attachment in the plan body. Uses the
    # permanent blob path (rails_blob_path is signed but non-expiring), so the
    # snippet keeps working across sessions. Images render inline in the plan
    # (the sanitizer allows <img src>); other types become a download link.
    #
    # `url` can be passed in by callers that have already generated the blob
    # path (the API controller includes this module and can't use main_app
    # view helpers the same way).
    def attachment_markdown_snippet(blob, url = nil)
      url ||= main_app.rails_blob_path(blob, only_path: true)
      # Escape markdown label metacharacters in the filename and
      # percent-encode characters that would terminate the (url) part, so a
      # filename like "report (final).pdf" — or a maliciously crafted one —
      # can't break out of the snippet.
      label = blob.filename.to_s.gsub(/([\\\[\]])/) { "\\#{$1}" }
      safe_url = url.gsub("(", "%28").gsub(")", "%29").gsub(" ", "%20")
      prefix = blob.content_type.to_s.start_with?("image/") ? "!" : ""
      "#{prefix}[#{label}](#{safe_url})"
    end

    def attachment_icon(content_type)
      case content_type.to_s
      when "application/pdf" then "📕"
      when "application/zip" then "🗜️"
      when "text/csv", "application/json" then "🗒️"
      else "📄"
      end
    end
  end
end
