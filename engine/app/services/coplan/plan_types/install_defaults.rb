module CoPlan
  module PlanTypes
    # Installs the plan types shipped with the engine
    # (engine/db/default_plan_types/*.md — YAML front matter for the
    # attributes, Markdown body as the template).
    #
    # Admin edits are data, defaults are code, and the defaults must never
    # silently clobber the data: without `force`, existing types only gain
    # values for fields that are currently blank (the common upgrade case —
    # a type created before templates existed gets the default template,
    # but a hand-written description survives). With `force`, the shipped
    # defaults win on every field. Types unknown to the defaults are never
    # touched either way.
    class InstallDefaults
      DEFAULTS_DIR = CoPlan::Engine.root.join("db", "default_plan_types")
      FRONT_MATTER = /\A---\n(?<yaml>.*?)\n---\n?(?<body>.*)\z/m

      Result = Struct.new(:created, :updated, :skipped, keyword_init: true)

      def self.call(force: false, dir: DEFAULTS_DIR)
        new(force:, dir:).call
      end

      def initialize(force: false, dir: DEFAULTS_DIR)
        @force = force
        @dir = Pathname(dir)
      end

      def call
        result = Result.new(created: [], updated: [], skipped: [])

        @dir.glob("*.md").sort.each do |path|
          attrs = parse(path)
          type = PlanType.find_by_name(attrs[:name])

          if type.nil?
            PlanType.create!(**attrs)
            result.created << attrs[:name]
          elsif apply(type, attrs)
            result.updated << attrs[:name]
          else
            result.skipped << attrs[:name]
          end
        end

        result
      end

      private

      def parse(path)
        match = FRONT_MATTER.match(path.read)
        raise ArgumentError, "#{path.basename}: missing YAML front matter" unless match

        meta = YAML.safe_load(match[:yaml]) || {}
        name = meta["name"].to_s.strip
        raise ArgumentError, "#{path.basename}: front matter needs a name" if name.empty?

        {
          name: name,
          description: meta["description"].to_s.strip.presence,
          icon: meta["icon"].to_s.strip.presence,
          default_tags: Array(meta["default_tags"]).map(&:to_s),
          template_content: match[:body].strip.presence
        }
      end

      # Assigns default values onto an existing type; returns whether
      # anything changed. Only blank fields are filled unless forcing.
      def apply(type, attrs)
        attrs.except(:name).each do |field, value|
          next if value.blank?
          next unless @force || type[field].blank?

          type[field] = value
        end
        return false unless type.changed?

        type.save!
        true
      end
    end
  end
end
