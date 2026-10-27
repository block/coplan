module CoPlan
  # Optional host integration. Preserve Rails' normal handling for every
  # status/format other than an HTML 404, including JSON API failures.
  class ExceptionsApp
    def initialize(public_path)
      @fallback = ActionDispatch::PublicExceptions.new(public_path)
    end

    def call(env)
      request = ActionDispatch::Request.new(env)
      if request.path_info == "/404" && request.format.html?
        ErrorsController.action(:not_found).call(env)
      else
        @fallback.call(env)
      end
    end
  end
end
