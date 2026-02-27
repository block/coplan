class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern unless Rails.env.test?

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :authenticate_user!

  helper_method :current_user, :signed_in?

  private

  def current_user
    @current_user ||= CoPlan::User.find_by(id: session[:user_id]) if session[:user_id]
  end

  def signed_in?
    current_user.present?
  end

  def authenticate_user!
    unless signed_in?
      redirect_to main_app.sign_in_path, alert: "Please sign in."
    end
  end

  class NotAuthorizedError < StandardError; end

  rescue_from NotAuthorizedError do
    head :not_found
  end

  def authenticate_admin!
    authenticate_user!
    redirect_to coplan.root_path, alert: "Not authorized." unless current_user&.admin?
  end
end
