module CoPlan
  # Rendered diagrams: a fenced block whose source CoPlan can't draw itself
  # (a draw-diagram render.mjs, Graphviz, PlantUML), shown as the image an
  # agent rendered from it. The source stays in the document, so it is
  # versioned, diffed, attributed, and commented on like any other content.
  #
  #   ```draw-diagram {image="/rails/active_storage/blobs/…/flow.png" alt="Checkout flow" lang=javascript}
  #   …source…
  #   ```
  #
  # The fence language names the renderer, which is also the agent skill
  # that edits and renders it unless `skill` names another. The braces
  # carry the image, its alt text, an optional display width, the language
  # to highlight the source in, and an optional `skill-source` URL where the
  # skill can be found. CoPlan doesn't know how to render anything itself;
  # how is the skill's business, and notes for the next editor live in
  # comments in the source. A fence without an `image` is an ordinary code
  # block; Mermaid keeps rendering in the browser.
  module RenderedDiagrams
    Block = Data.define(:renderer, :image, :alt, :width, :lang, :skill, :skill_source, :source)

    RENDERER_NAME = /[A-Za-z0-9_+-]+/
    # Commonmarker splits the info string at the first space into the
    # language and the rest, so the braces have to follow a space.
    # Quoted values may contain braces, e.g. alt="Config {a, b}".
    INFO = /\A(?<renderer>#{RENDERER_NAME.source})\s+\{(?<attributes>(?:"[^"]*"|[^"}])*)\}\s*\z/
    # Skill names as agents install them, e.g. `draw-diagram` or `plugin:skill`.
    SKILL_NAME = %r{\A[\w:./-]{1,100}\z}
    ATTRIBUTE = /([A-Za-z][\w-]*)=(?:"([^"]*)"|(\S+))/
    # Same-site paths and http(s) URLs only, as for any other image.
    # No backslashes: browsers read `/\host` as `//host`.
    IMAGE_URL = %r{\A(?:/(?!/)|https?://)[^\s"'<>\\]*\z}i
    BROWSER_RENDERED = %w[mermaid].freeze
    # Part of the stale-image cache key: bump when what counts as stale changes.
    STALE_CACHE_VERSION = 1

    module_function

    # The renderer and attributes from a fence info string, or nil when the
    # fence isn't a rendered diagram.
    def parse_info(info)
      match = INFO.match(info.to_s.strip)
      return nil unless match && !BROWSER_RENDERED.include?(match[:renderer])

      attributes = match[:attributes].scan(ATTRIBUTE).to_h { |key, quoted, bare| [ key, quoted || bare ] }
      image = attributes["image"].to_s
      return nil unless IMAGE_URL.match?(image)

      width, lang, skill = attributes.values_at("width", "lang", "skill").map(&:to_s)
      skill_source = attributes["skill-source"].to_s
      { renderer: match[:renderer], image: image, alt: attributes["alt"].to_s,
        width: width.match?(/\A\d{1,4}\z/) ? width : nil,
        # Not a language CoPlan draws itself, or the source would be drawn too.
        lang: lang.match?(/\A[\w+#.-]{1,40}\z/) && !BROWSER_RENDERED.include?(lang) ? lang : nil,
        skill: SKILL_NAME.match?(skill) ? skill : match[:renderer],
        skill_source: skill_source.match?(%r{\Ahttps?://[^\s"'<>\\]+\z}i) ? skill_source : nil }
    end

    def blocks(markdown)
      return [] unless markdown.to_s.include?("image=")

      found = []
      Markdown.parse(markdown.to_s).walk do |node|
        next unless node.type == :code_block

        info = parse_info(node.fence_info)
        found << Block.new(**info, source: node.string_content) if info
      end
      found
    end

    # Images in the plan's current content whose source changed after the
    # image went in, so they no longer show what the source draws. Compares
    # each fence's source with the source in the earliest version that showed
    # its image. Cached per version: history before it never changes.
    def stale_images(plan)
      version = plan.current_plan_version
      # Already loaded to render the plan; most plans have no rendered diagrams.
      return Set.new unless version&.content_markdown.to_s.include?("image=")

      Rails.cache.fetch([ "coplan/rendered-diagrams/stale", STALE_CACHE_VERSION, version.id ]) do
        blocks(version.content_markdown).select { |block| stale?(plan, block, version.revision) }.map(&:image)
      end.to_set
    end

    def stale?(plan, block, revision)
      ids = plan.plan_versions.reorder(:revision)
        .where("revision <= ?", revision)
        .where("content_markdown LIKE ?", "%#{PlanVersion.sanitize_sql_like(block.image)}%")
        .pluck(:id)
      # Usually the first match; one content load at a time either way.
      ids.each do |id|
        original = blocks(PlanVersion.where(id: id).pick(:content_markdown))
          .find { |candidate| candidate.image == block.image && candidate.renderer == block.renderer }
        return original.source != block.source if original
      end
      false
    end
  end
end
