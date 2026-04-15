module CoPlan
  module ReferencesHelper
    def reference_icon(reference_type)
      case reference_type
      when "plan" then "📋"
      when "repository" then "📦"
      when "pull_request" then "🔀"
      when "document" then "📄"
      else "🔗"
      end
    end
  end
end
