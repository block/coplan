module CoPlan
  module AttachmentsHelper
    # Uploader identity is stamped into the blob metadata at upload time (see
    # Plans::AddAttachment) because ActiveStorage has no user association of
    # its own. Prefer a live User lookup so renames are reflected; fall back
    # to the name captured at upload time if the user has since been removed.
    def attachment_uploader_name(blob)
      metadata = blob.metadata || {}
      id = metadata["uploaded_by_id"]
      user = CoPlan::User.find_by(id: id) if id.present?
      user&.name || metadata["uploaded_by_name"].presence
    end

    # Markdown snippet for embedding an attachment in the plan body. Uses the
    # permanent blob path (rails_blob_path is signed but non-expiring), so the
    # snippet keeps working across sessions. Images render inline in the plan
    # (the sanitizer allows <img src>); other types become a download link.
    def attachment_markdown_snippet(blob)
      url = main_app.rails_blob_path(blob, only_path: true)
      if blob.content_type.to_s.start_with?("image/")
        "![#{blob.filename}](#{url})"
      else
        "[#{blob.filename}](#{url})"
      end
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
