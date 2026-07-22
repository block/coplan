require "zlib"

module CoPlan
  module PlansHelper
    include MarkdownHelper

    # Everything a workspace (plans index) link may carry. Filter links
    # build on the current params via workspace_path so no call site has
    # to re-list this whitelist — or remember which param to omit.
    WORKSPACE_LINK_PARAMS = %i[scope filter plan_type tag folder updated].freeze

    # A plans-index URL carrying the current filters with `overrides`
    # applied; pass nil to clear a filter (blank values are dropped).
    def workspace_path(**overrides)
      plans_path(
        params.permit(*WORKSPACE_LINK_PARAMS).to_h.symbolize_keys
          .merge(overrides).compact_blank
      )
    end

    # Published is the unmarked normal state. The hidden states (draft,
    # archived) get a quiet crossed-out eye — "this one isn't listed" —
    # rather than a loud colored badge. Safe in broadcast partials
    # (derives from the plan alone, no current_user).
    HIDDEN_EYE_ICON = <<~SVG.html_safe.freeze
      <svg class="state-flag__eye" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9.88 9.88a3 3 0 1 0 4.24 4.24"/><path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68"/><path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61"/><line x1="2" x2="22" y1="2" y2="22"/></svg>
    SVG

    def plan_state_badge(plan)
      flags = []
      flags << hidden_state_flag("Private", "Not shared — hidden from lists and search; anyone with the link can still read it") if plan.draft?
      flags << hidden_state_flag("Archived", "Hidden from lists unless filtered for") if plan.archived?
      return "".html_safe if flags.empty?

      safe_join([ " ", safe_join(flags, " ") ])
    end

    def hidden_state_flag(label, title)
      content_tag(:span, safe_join([ HIDDEN_EYE_ICON, label ]), class: "state-flag", title: title)
    end

    # Built-in icon set for plan types (lucide outlines, matching the rest
    # of the chrome). Installs pick by name (`PlanType#icon`) — a curated
    # set rather than raw SVG so nothing user-supplied is ever rendered as
    # markup. Unknown/blank names fall back to the plain document icon.
    PLAN_TYPE_ICONS = {
      "file-text" => %(<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>),
      "scroll" => %(<path d="M19 17V5a2 2 0 0 0-2-2H4"/><path d="M8 21h12a2 2 0 0 0 2-2v-1a1 1 0 0 0-1-1H11a1 1 0 0 0-1 1v1a2 2 0 1 1-4 0V5a2 2 0 1 0-4 0v2a1 1 0 0 0 1 1h3"/>),
      "compass" => %(<path d="m16.24 7.76-1.804 5.411a2 2 0 0 1-1.265 1.265L7.76 16.24l1.804-5.411a2 2 0 0 1 1.265-1.265z"/><circle cx="12" cy="12" r="10"/>),
      "scale" => %(<path d="m16 16 3-8 3 8c-.87.65-1.92 1-3 1s-2.13-.35-3-1"/><path d="m2 16 3-8 3 8c-.87.65-1.92 1-3 1s-2.13-.35-3-1"/><path d="M7 21h10"/><path d="M12 3v18"/><path d="M3 7h2c2 0 5-1 7-2 2 1 5 2 7 2h2"/>),
      "lightbulb" => %(<path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5"/><path d="M9 18h6"/><path d="M10 22h4"/>),
      "rocket" => %(<path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z"/><path d="m12 15-3-3a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.35 22.35 0 0 1-4 2z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0"/><path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/>),
      "map" => %(<path d="M14.106 5.553a2 2 0 0 0 1.788 0l3.659-1.83A1 1 0 0 1 21 4.619v12.764a1 1 0 0 1-.553.894l-4.553 2.277a2 2 0 0 1-1.788 0l-4.212-2.106a2 2 0 0 0-1.788 0l-3.659 1.83A1 1 0 0 1 3 19.381V6.618a1 1 0 0 1 .553-.894l4.553-2.277a2 2 0 0 1 1.788 0z"/><path d="M15 5.764v15"/><path d="M9 3.236v15"/>),
      "flask" => %(<path d="M10 2v7.527a2 2 0 0 1-.211.896L4.72 20.55a1 1 0 0 0 .9 1.45h12.76a1 1 0 0 0 .9-1.45l-5.069-10.127A2 2 0 0 1 14 9.527V2"/><path d="M8.5 2h7"/><path d="M7 16h10"/>),
      "shield" => %(<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>),
      "wrench" => %(<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>)
    }.freeze

    # How many tint classes exist in CSS (.plan-type-icon--0 … --N-1).
    PLAN_TYPE_COLOR_COUNT = 6

    # The document's file icon — a colored rounded square with the type's
    # glyph, like a Drive/Finder file icon. Leads the title in rows, the
    # plan header, feed items, and search results; the type's name lives in
    # the tooltip so it never reads as a tag. Untyped plans get the neutral
    # document glyph. Safe in broadcast partials (derives from the plan
    # alone, no current_user).
    def plan_type_icon(plan, size: :md)
      plan_type = plan.plan_type
      paths = PLAN_TYPE_ICONS[plan_type&.icon] || PLAN_TYPE_ICONS["file-text"]
      # Stable per-name tint (Zlib.crc32, not #hash — that differs across
      # processes) so a type keeps its color everywhere, every request.
      tint = plan_type ? Zlib.crc32(plan_type.name) % PLAN_TYPE_COLOR_COUNT : nil
      glyph = %(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{paths}</svg>).html_safe

      classes = [ "plan-type-icon", "plan-type-icon--#{size}" ]
      classes << "plan-type-icon--#{tint}" if tint
      content_tag(:span, glyph,
        class: classes.join(" "),
        title: plan_type&.name,
        aria: { label: plan_type ? "#{plan_type.name} document" : "Document" })
    end

    def plan_content_preview(plan, limit: 200)
      stub = plan.current_version_stub
      return nil if stub.nil?

      # Cached per content SHA: without this, every index page fell back to a
      # full Commonmarker + Nokogiri parse per plan without an AI summary.
      # The document body itself is fetched only on a cache miss — list pages
      # preload just the stub (id + sha), never the MEDIUMTEXT columns.
      cache_key = [ "coplan/plan-preview", MarkdownHelper::RENDER_CACHE_VERSION, plan.id,
                   stub.content_sha256 || plan.current_revision ]
      plain = Rails.cache.fetch(cache_key) do
        markdown_to_plain_text(PlanVersion.where(id: stub.id).pick(:content_markdown))
      end
      return nil if plain.blank?

      truncate(plain, length: limit, omission: "…", separator: " ")
    end
  end
end
