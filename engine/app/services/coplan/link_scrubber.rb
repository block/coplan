module CoPlan
  # Permit application deep links on anchors without broadening image sources
  # or allowing browser-executable URLs. All other HTML uses Rails' sanitizer.
  class LinkScrubber < Rails::HTML::PermitScrubber
    SCHEME = /\A[a-z][a-z0-9+.-]*:/i
    UNSAFE_SCHEME = /\A(?:javascript|vbscript|data|blob):/i

    def scrub_attribute(node, attribute)
      if node.name == "a" && attribute.name == "href" && attribute.namespace.nil?
        value = attribute.value
        return if SCHEME.match?(value) && !UNSAFE_SCHEME.match?(value) && !/[[:space:]\x00-\x1f\x7f]/.match?(value)
      end
      super
    end
  end
end
