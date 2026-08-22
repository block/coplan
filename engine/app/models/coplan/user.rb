module CoPlan
  class User < ApplicationRecord
    THEME_PREFERENCES = %w[system light dark].freeze

    # Which key holds the microphone open for push-to-talk commenting.
    # A short list rather than a free capture: each one carries its own
    # feel in the browser (a bare modifier needs a hold delay, because
    # people press it while typing; a chord doesn't), and the tooltip on
    # the mic has to be able to name it.
    VOICE_HOTKEYS = %w[ctrl_space shift alt off].freeze
    DEFAULT_VOICE_HOTKEY = "ctrl_space".freeze

    # Names for the keys, for the settings row and the mic's own tooltip.
    # Alt is written out both ways because the server can't know which
    # keyboard is in front of the person; the voice controller narrows it
    # to ⌥ Option on a Mac once it's running.
    VOICE_HOTKEY_LABELS = {
      "ctrl_space" => "Ctrl+Space",
      "shift" => "Shift",
      "alt" => "Option / Alt",
      "off" => "Off"
    }.freeze

    has_many :api_tokens, dependent: :destroy
    has_many :created_plans, class_name: "CoPlan::Plan", foreign_key: :created_by_user_id, dependent: :nullify, inverse_of: :created_by_user
    has_many :created_folders, class_name: "CoPlan::Folder", foreign_key: :created_by_user_id, dependent: :nullify, inverse_of: :created_by_user
    has_many :plan_collaborators, dependent: :destroy
    has_many :notifications, dependent: :destroy
    has_many :web_push_subscriptions, class_name: "CoPlan::WebPushSubscription", dependent: :destroy

    validates :external_id, presence: true, uniqueness: true
    validates :name, presence: true
    validates :email, uniqueness: true, allow_nil: true
    validates :username, uniqueness: true, allow_nil: true,
      format: { with: /\A[a-z0-9][a-z0-9._-]*\z/, message: "must be lowercase alphanumeric (dots, hyphens, underscores allowed)" }

    after_initialize { self.metadata ||= {} }
    after_initialize { self.notification_preferences ||= {} }

    # Every user always has a library — it's an invariant, materialized on
    # first touch. Never read the association directly; this accessor is
    # what guarantees "user without a library" isn't a state that exists.
    def library
      @library ||= Library.for(self)
    end

    def self.ransackable_attributes(auth_object = nil)
      %w[id external_id name username email admin avatar_url title team created_at updated_at]
    end

    def self.ransackable_associations(auth_object = nil)
      %w[api_tokens plan_collaborators]
    end

    def theme_preference
      metadata&.dig("theme_preference") || "system"
    end

    def theme_preference=(value)
      self.metadata ||= {}
      self.metadata["theme_preference"] = value
    end

    # Unset means Ctrl+Space. Everyone who was already here when the
    # setting arrived had their old key (Shift) written down by the
    # backfill, so "no preference" only ever means "new here".
    def voice_hotkey
      key = metadata&.dig("voice_hotkey")
      VOICE_HOTKEYS.include?(key) ? key : DEFAULT_VOICE_HOTKEY
    end

    def voice_hotkey=(value)
      self.metadata ||= {}
      self.metadata["voice_hotkey"] = value
    end
  end
end
