module CoPlan
  module Plans
    # Works out a plan's URL segment and writes it, recording an alias for
    # the old one.
    #
    # The rule is: **strip whatever the URL already says.** A plan titled
    # "LiveOrder Cart Roadmap" filed in a folder called "LiveOrder" is
    # just `cart-roadmap` — repeating the folder in the leaf is exactly
    # the noise that makes a folder full of `liveorder-*` plans unreadable.
    # Three sources of redundancy get stripped: the library handle, the
    # folder name, and the plan type. Plus the word "plan" itself, which
    # carries no information in an app where everything is a plan.
    #
    # Matching is hyphen-insensitive, so it works whether the folder was
    # named "LiveOrder", "Live Order", or "live-order".
    #
    # Deliberately *not* implemented: stripping the common prefix across
    # sibling plans. It would catch more cases, but one new plan without
    # the prefix would silently change every sibling's URL.
    class AssignSlug
      # Unambiguous alphabet — no 0/o/1/l — for the disambiguating suffix.
      SUFFIX_ALPHABET = "23456789abcdefghjkmnpqrstuvwxyz".freeze
      SUFFIX_LENGTH = 4

      def self.call(plan:, folder: :unset, previous_path: :unset, record_alias: true)
        new(plan:, folder:, previous_path:, record_alias:).call
      end

      def initialize(plan:, folder: :unset, previous_path: :unset, record_alias: true)
        @plan = plan
        # Callers mid-move pass the destination folder explicitly, since
        # the placement row may not be written yet.
        @folder = folder == :unset ? plan.canonical_folder : folder
        # A move has already changed the placement by the time we run, so
        # the old URL can't be derived from the plan any more — the caller
        # captures it beforehand and hands it over.
        @previous_path = previous_path == :unset ? default_previous_path : previous_path
        @record_alias = record_alias
      end

      def call
        @plan.slug = derive
        @plan.slug_suffix = contested? ? assign_suffix : nil

        record_alias
        @plan
      end

      private

      def default_previous_path
        @plan.slug.present? ? @plan.url_path : nil
      end

      # Full title slug, and the shortened form with everything the path
      # already says removed. Falls back to the full form when stripping
      # would leave nothing meaningful behind.
      def derive
        full = Slug.strip_noise(Slug.tokens(@plan.title))
        return "untitled" if full.empty?

        Slug.from_tokens(strip_redundancy(full))
      end

      # Repeats until nothing more comes off, so "Orders LiveOrder Cart"
      # under /l/orders/liveorder loses both leading words regardless of
      # the order they appear in.
      def strip_redundancy(tokens)
        kept = tokens
        loop do
          before = kept
          redundant_phrases.each { |phrase| kept = strip_leading(kept, phrase) }
          break if kept == before
        end
        kept.presence || tokens
      end

      # Everything the path already spells out: the handle, every folder
      # on the way down (not just the immediate one — the URL says the
      # whole chain), and the plan type.
      def redundant_phrases
        folder_names = @folder ? (@folder.ancestors + [ @folder ]).map(&:name) : []
        [ @plan.library_handle, *folder_names, @plan.plan_type&.name ].compact_blank
      end

      # Drops the leading tokens that spell out `phrase`, hyphens ignored.
      # Never strips everything — a plan titled exactly "LiveOrder" inside
      # "LiveOrder" keeps its name rather than becoming empty.
      def strip_leading(tokens, phrase)
        key = Slug.compare_key(phrase)
        return tokens if key.blank?

        (1...tokens.length).each do |n|
          return tokens.drop(n) if tokens.first(n).join == key
        end
        tokens
      end

      # Another plan already holds this slug in the same folder. Checked
      # against the folder's placements, which is the plan's real
      # uniqueness scope — see the note in AddPlanSlugsAndUrlAliases about
      # why this isn't a DB constraint yet.
      def contested?
        siblings.where(slug: @plan.slug, slug_suffix: nil).exists?
      end

      def siblings
        scope = if @folder
          Plan.where(id: @folder.placements.select(:plan_id))
        else
          Plan.where(id: unfiled_sibling_ids)
        end
        scope = scope.where.not(id: @plan.id) if @plan.persisted?
        scope
      end

      # At a library root, a plan's siblings are the other plans its
      # library shows there — the ones with no placement of their own.
      def unfiled_sibling_ids
        @plan.canonical_library&.unfiled_plans&.select(:id) || []
      end

      # Keeps trying until the pair is free. Random rather than sequential
      # so the suffix says nothing about how many plans came before.
      def assign_suffix
        10.times do
          candidate = SUFFIX_LENGTH.times.map { SUFFIX_ALPHABET[SecureRandom.random_number(SUFFIX_ALPHABET.length)] }.join
          return candidate unless siblings.where(slug: @plan.slug, slug_suffix: candidate).exists?
        end
        SecureRandom.hex(4)
      end

      def record_alias
        return unless @record_alias
        return if @previous_path.blank?

        current = @plan.url_path
        UrlAlias.record!(from: @previous_path, to: current) if current.present?
      end
    end
  end
end
