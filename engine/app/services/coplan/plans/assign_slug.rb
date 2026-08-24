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
        @folder = folder == :unset ? plan.folder : folder
        # A move has already changed the placement by the time we run, so
        # the old URL can't be derived from the plan any more — the caller
        # captures it beforehand and hands it over.
        @previous_path = previous_path == :unset ? default_previous_path : previous_path
        @record_alias = record_alias
      end

      # Runs inside the caller's transaction — a plan's own `before_save`,
      # a move, or the folder rename that shadowed it — and takes the
      # destination library's namespace lock before reading, so the
      # `contested?` answer is still true when the caller writes it.
      def call
        target_library&.lock_namespace!

        @plan.slug = derive
        @plan.slug_suffix = contested? ? assign_suffix : nil

        record_alias
        @plan
      end

      private

      # Where the plan is landing, which is the namespace it competes in.
      # Mid-move that's the destination, not where it's leaving: the level
      # it vacates can't gain a collision by losing a member.
      def target_library
        @target_library ||= @folder&.library || @plan.library
      end

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
      # under /orders/liveorder loses both leading words regardless of
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

      # Something else at this level already holds the segment.
      #
      # Enforced here rather than by a unique index, and not only because
      # the slug and the location live in different tables: the contest
      # crosses *models*. A folder and a plan compete for the same segment,
      # and no single index spans coplan_folders and coplan_plans. So the
      # write path is where "one segment, one thing" can actually be
      # decided, and it decides it from the read below.
      def contested?
        taken.include?([ @plan.slug, nil ])
      end

      # Every segment already spoken for at this level, as [slug, suffix].
      #
      # Sibling *folders* count too. Urls::Resolve hands the segment to a
      # folder when both want it — mistaking a folder for a plan would
      # break a whole subtree — so a plan sharing a folder's slug would
      # have no reachable address at all. Folders never take a suffix, which
      # is what makes the plan the one that moves.
      #
      # Read with FOR UPDATE, and not because these rows are being written.
      # Under MySQL's REPEATABLE READ a plain SELECT answers from the
      # snapshot this transaction took at its *first* read, which happened
      # before Library#lock_namespace! — so the writer we just finished
      # waiting for would still be invisible and we would confidently claim
      # the segment it had already taken. A locking read sees the latest
      # committed row instead. Safe under the namespace lock: one writer per
      # library is in here at a time, and neither query reaches outside the
      # library it holds.
      def taken
        @taken ||= (
          sibling_folders.lock.pluck(:slug).map { |slug| [ slug, nil ] } +
            siblings.lock.pluck(:slug, :slug_suffix)
        ).to_set
      end

      # The folders that sit at the same level of the URL as this plan: the
      # children of the folder it's filed in, or the library's root folders
      # when it's filed nowhere.
      def sibling_folders
        return Folder.none if target_library.nil?

        target_library.folders.where(parent_id: @folder&.id)
      end

      # The plans at that same level.
      #
      # Both shapes below keep coplan_plans in the *outer* query, and that's
      # the load-bearing part. FOR UPDATE reads latest-committed only for
      # what the query itself scans, so a plan reached through
      # `where(id: <subquery over coplan_plans>)` — the shape this used to
      # have — gets filtered out by the snapshot before the locking scan
      # ever sees it, and the lock guards a set that was never refreshed.
      #
      # The filed case joins, because the placement row is what decides
      # membership and so has to be read fresh too. The unfiled case can
      # leave placements in a subquery: a plan created a moment ago has no
      # placement in either the snapshot or the present, so `NOT IN` gives
      # the same answer from both, and the plan row itself comes off the
      # locking scan.
      def siblings
        scope = if @folder
          Plan.joins(:placement).where(coplan_plan_placements: { folder_id: @folder.id })
        else
          target_library&.unfiled_plans || Plan.none
        end
        scope = scope.where.not(id: @plan.id) if @plan.persisted?
        scope
      end

      # Keeps trying until the pair is free. Random rather than sequential
      # so the suffix says nothing about how many plans came before.
      def assign_suffix
        10.times do
          candidate = SUFFIX_LENGTH.times.map { SUFFIX_ALPHABET[SecureRandom.random_number(SUFFIX_ALPHABET.length)] }.join
          return candidate unless taken.include?([ @plan.slug, candidate ])
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
