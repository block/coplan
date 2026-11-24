module Coplan
  module ApplicationHelper
    include Coplan::KeyboardShortcutsHelper
    include MarkdownHelper

    def use_coplan_client_messages(*groups)
      (@coplan_client_message_groups ||= []).concat(groups)
    end

    def coplan_client_messages
      groups = [ :common, *@coplan_client_message_groups ].uniq
      groups.index_with { |group| I18n.t("coplan.client.#{group}", default: {}) }
    end

    def relative_ui_time(time)
      I18n.t("coplan.display.relative_time", duration: time_ago_in_words(time))
    end

    def coplan_plan_streams(plan)
      localized = Broadcaster.localized_stream(plan, I18n.locale)
      return turbo_stream_from(plan) if localized == plan

      safe_join([ turbo_stream_from(plan), turbo_stream_from(localized) ])
    end

    # The app theme for this page, as <html data-app-theme> (docs/THEMES.md):
    # the viewer's pick from Settings, else the host's default.
    def coplan_app_theme
      choice = current_user.app_theme if signed_in?
      Coplan::Themes.resolve(choice).key
    end

    # The viewer's pick as Settings shows it, as <html data-app-theme-choice>:
    # a theme key, or "default". A stored theme that Coplan no longer ships
    # counts as "default".
    def coplan_app_theme_choice
      (Coplan::Themes.find(current_user.app_theme)&.key if signed_in?) || Coplan::User::DEFAULT_APP_THEME
    end

    def coplan_theme_name(theme)
      theme.key == "classic" ? t("coplan.interface.classic_name") : t("coplan.interface.neutral_name")
    end

    def coplan_theme_description(theme)
      theme.key == "classic" ? t("coplan.interface.classic_description") : t("coplan.interface.neutral_description")
    end

    def voice_hotkey_label(hotkey)
      case hotkey
      when "ctrl_space" then t("coplan.interface.ctrl_space")
      when "shift" then t("coplan.interface.shift")
      when "alt" then t("coplan.interface.alt")
      when "off" then t("coplan.interface.hotkey_off")
      end
    end

    def review_requirement_label(requirement)
      requirement == "required" ? t("coplan.interface.required_review") : t("coplan.interface.optional_review")
    end

    def review_decision_label(status)
      status == "approved" ? t("coplan.interface.approved_review") : t("coplan.interface.changes_requested_review")
    end

    def notification_reason_label(reason)
      case reason
      when "new_comment" then t("coplan.interface.notification_new_comment")
      when "reply" then t("coplan.interface.notification_reply")
      when "agent_response" then t("coplan.interface.notification_agent_response")
      when "status_change" then t("coplan.interface.notification_status_change")
      when "mention" then t("coplan.interface.notification_mention")
      end
    end

    def coplan_favicon_tag
      safe_join([
        tag.link(rel: "icon", type: "image/png", sizes: "192x192", href: asset_path(coplan_logo_asset(format: :png))),
        tag.link(rel: "icon", type: "image/svg+xml", sizes: "any", href: asset_path(coplan_logo_asset))
      ])
    end

    def plan_og_description(plan)
      # One preview builder for OG tags, Slack unfurls, and anything else —
      # its context carries the Private/Archived flag (published unmarked).
      preview = LinkPreviews.for_plan(plan, base_url: request.base_url + coplan.root_path)
      truncate([ preview.context, preview.description ].compact.join(" — "), length: 250, omission: "…")
    end

    # Where a person lives: their library, which is their page. Their handle
    # is usually their username, but not always (collisions get a suffix),
    # so it has to be read rather than derived.
    #
    # Memoized per request because list pages ask for the same few authors
    # over and over — one lookup per distinct person, not per row. A library
    # is materialized on first touch (User#library), so the first ask for
    # someone who has never had one also creates it.
    def profile_path_for(user)
      handles = (@browse_handles ||= {})
      browse_library_path(handle: handles[user.id] ||= user.library.handle)
    end

    # Author names everywhere in the app link to their library.
    def profile_link(user, css_class: "profile-link")
      return "" unless user
      link_to user.name, profile_path_for(user), class: css_class
    end

    def user_avatar(user, size: "sm", css_class: "avatar avatar--#{size} avatar--initials")
      initials = user.name.split.map { |w| w[0] }.first(2).join.upcase
      tag.span(class: css_class, role: "img", aria: { label: user.name }, title: user.name) do
        photo = if user.avatar_url.present?
          tag.img(src: user.avatar_url, alt: "", class: "avatar__image", loading: "lazy",
            data: { controller: "coplan--avatar", action: "load->coplan--avatar#loaded error->coplan--avatar#failed" })
        end
        safe_join([ initials, photo ])
      end
    end

    # The nav, favicon, and notification icon share one environment palette.
    def coplan_logo_asset(format: :svg)
      suffix = case Rails.env
      when "development" then "-development"
      when "staging" then "-staging"
      else ""
      end

      "coplan/coplan-logo#{suffix}.#{format}"
    end

    def coplan_environment_logo_title
      return if Rails.env.production?

      I18n.t("coplan.common.messages.capitalize_environment", capitalize: Rails.env.capitalize)
    end
  end
end
