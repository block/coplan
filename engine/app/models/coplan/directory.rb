module CoPlan
  # The host directory adapter's engine-side half. Profiles render whatever
  # `profile_for` returns; hosts plug their people directory in via
  # `CoPlan.configuration.directory_profile` and the engine never learns
  # which directory that is. Without a hook (or when the hook fails), the
  # profile falls back to the local coplan_users columns — a minimal
  # profile beats a broken page.
  module Directory
    Profile = Struct.new(:name, :avatar_url, :title, :team, :profile_url, keyword_init: true)

    def self.profile_for(user)
      local = Profile.new(
        name: user.name,
        avatar_url: user.avatar_url,
        title: user.title,
        team: user.team,
        profile_url: nil
      )

      hook = CoPlan.configuration.directory_profile
      return local unless hook

      begin
        remote = hook.call(user)
      rescue StandardError => e
        CoPlan.configuration.error_reporter&.call(e, { source: "directory_profile", user_id: user.id })
        return local
      end
      return local unless remote.is_a?(Hash)

      remote = remote.symbolize_keys
      Profile.new(
        name: remote[:name].presence || local.name,
        avatar_url: remote[:avatar_url].presence || local.avatar_url,
        title: remote[:title].presence || local.title,
        team: remote[:team].presence || local.team,
        profile_url: remote[:profile_url].presence
      )
    end
  end
end
