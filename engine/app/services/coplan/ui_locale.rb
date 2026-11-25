module Coplan
  module UiLocale
    LANGUAGE_PREFERENCE = /\A([a-z]{1,8}(?:-[a-z0-9]{1,8})*|\*)(?:\s*;\s*q\s*=\s*(0(?:\.\d{0,3})?|1(?:\.0{0,3})?))?\z/i

    def self.check_configuration!
      config = Coplan.configuration
      unless config.ui_locales.is_a?(Array)
        raise ArgumentError, "Coplan ui_locales must be an array of Rails locale tags"
      end

      locales = config.ui_locales.map(&:to_s)
      unless locales.include?(config.ui_default_locale.to_s)
        raise ArgumentError, "Coplan ui_default_locale must be included in ui_locales"
      end

      locales.each do |locale|
        unless I18n.locale_available?(locale) && I18n.exists?("coplan", locale, fallback: false)
          raise ArgumentError, "Coplan ui_locales includes #{locale.inspect}, which needs a Rails locale and a Coplan UI catalog"
        end
      end
    end

    def self.for_request(request)
      config = Coplan.configuration
      locales = config.ui_locales
      return config.ui_default_locale if locales.one?

      select(request.get_header("HTTP_ACCEPT_LANGUAGE"), locales: locales,
        default: config.ui_default_locale, preference: request.session[:coplan_ui_locale])
    end

    def self.select(header, locales:, default:, preference: nil)
      return default if locales.size == 1
      if preference
        preferred = locales.find { |locale| locale.to_s == preference }
        return preferred if preferred
      end
      return default if header.nil? || header.bytesize > 4096 || !header.ascii_only?

      supported = locales.index_by { |locale| locale.to_s.downcase }
      preferences = header.split(",").filter_map do |entry|
        match = LANGUAGE_PREFERENCE.match(entry.strip)
        [ match[1].downcase, match[2]&.to_f || 1.0 ] if match
      end
      qualities = preferences.group_by(&:first).transform_values { |entries| entries.map(&:last).max }

      preferences.each_with_index.sort_by { |(_, quality), index| [ -quality, index ] }.each do |(range, quality), _|
        break if quality.zero?

        if range == "*"
          # An explicit range takes precedence over the wildcard for that language.
          wildcard_locale = [ default, *locales ].find do |locale|
            language_chain(locale.to_s.downcase).none? { |tag| qualities.key?(tag) }
          end
          return wildcard_locale if wildcard_locale
        else
          language_chain(range).each do |tag|
            candidate = supported[tag]
            return candidate if candidate && qualities[tag] != 0.0
          end
        end
      end

      default
    end

    def self.language_chain(tag)
      labels = tag.split("-")
      labels.length.downto(1).map { |length| labels.first(length).join("-") }
    end
    private_class_method :language_chain
  end
end
