require "coplan/development_seed"

class SessionsController < ApplicationController
  around_action :use_ui_locale
  skip_before_action :authenticate_user!, only: [ :new, :create ]

  def new
    return unless Rails.env.development?

    definitions = Coplan::DevelopmentSeed::USERS
    users = Coplan::User.where(external_id: definitions.map { |entry| "seed:#{entry.fetch(:key)}" }).index_by(&:external_id)
    @demo_users = definitions.filter_map { |entry| users["seed:#{entry.fetch(:key)}"] }
    @demo_user = @demo_users.find { |user| user.email == Coplan::DevelopmentSeed::DEFAULT_EMAIL }
  end

  def create
    email = params[:email].to_s.strip.downcase

    user = Coplan::User.find_or_initialize_by(email: email)
    user.assign_attributes(
      external_id: user.external_id || email,
      name: user.name || email.split("@").first.titleize
    )
    user.save!

    session[:user_id] = user.id
    flash.delete(:alert)
    redirect_to coplan.root_path, notice: I18n.t("coplan.sign_in.messages.signed_in_as_name", name: user.name)
  end

  def destroy
    language = session[:coplan_ui_locale]
    reset_session
    session[:coplan_ui_locale] = language if language.present?
    redirect_to sign_in_path, notice: I18n.t("coplan.sign_in.messages.signed_out")
  end

  private

  def use_ui_locale(&action)
    locale = Coplan::UiLocale.for_request(request)
    I18n.with_locale(locale, &action)
    return unless response.media_type == "text/html"

    response.headers["Content-Language"] = locale.to_s
    response.headers["Vary"] = "Accept-Language, Cookie" if Coplan.configuration.ui_locales.many?
  end
end
