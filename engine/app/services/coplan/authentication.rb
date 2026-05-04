module CoPlan
  module Authentication
    MISSING_AUTHENTICATE_MESSAGE = "CoPlan.configure { |c| c.authenticate = ->(request) { ... } } is required"

    module_function

    def user_from_request(request, callback: CoPlan.configuration.authenticate)
      raise MISSING_AUTHENTICATE_MESSAGE unless callback

      attrs = callback.call(request)
      return nil unless attrs && attrs[:external_id].present?

      provision_user!(attrs)
    end

    def provision_user!(attrs)
      external_id = attrs[:external_id].to_s
      user = CoPlan::User.find_or_initialize_by(external_id: external_id)
      sync_user_attrs(user, attrs)
      user.save! if user.new_record? || user.changed?
      user
    rescue ActiveRecord::RecordNotUnique
      user = CoPlan::User.find_by!(external_id: external_id)
      sync_user_attrs(user, attrs)
      user.save! if user.changed?
      user
    end

    def sync_user_attrs(user, attrs)
      safe_attrs = attrs.slice(:name, :username, :admin, :avatar_url, :title, :team).compact
      user.assign_attributes(safe_attrs)
      if attrs.key?(:metadata) && attrs[:metadata].is_a?(Hash)
        user.metadata = (user.metadata || {}).merge(attrs[:metadata])
      end
    end
  end
end
