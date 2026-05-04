module CoPlan
  # Session-authenticated user typeahead for in-app pickers (the @-mention
  # picker in the comment textarea today; future pickers welcome).
  class UsersController < ApplicationController
    ALLOWED_FIELDS = %i[id name email username avatar_url title team].freeze

    def search
      query = params[:q].to_s.strip
      if query.blank?
        return render json: []
      end

      users = if CoPlan.configuration.user_search
        # Hook may return external candidates (LDAP, etc.) — keep only those
        # whose username also exists in coplan_users, since RewriteMentions
        # and ProcessMentions can only resolve local usernames. Surfacing
        # external-only users would let the picker offer mentions that
        # silently fall through to plain text on save.
        candidates = CoPlan.configuration.user_search.call(query)
        local_usernames = CoPlan::User.where(username: candidates.filter_map { |c| c[:username] || c["username"] }).pluck(:username).to_set
        candidates.select { |c| local_usernames.include?(c[:username] || c["username"]) }
      else
        sanitized = CoPlan::User.sanitize_sql_like(query)
        CoPlan::User
          .where("name LIKE :q OR email LIKE :q OR username LIKE :q", q: "%#{sanitized}%")
          .limit(20)
      end

      render json: users.map { |u| user_json(u) }
    end

    private

    def user_json(user)
      if user.respond_to?(:id)
        ALLOWED_FIELDS.to_h { |f| [f, user.public_send(f)] }
      else
        ALLOWED_FIELDS.to_h { |f| [f, user[f]] }
      end
    end
  end
end
