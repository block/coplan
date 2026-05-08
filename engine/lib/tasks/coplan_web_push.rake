namespace :coplan do
  namespace :web_push do
    desc "Generate a VAPID key pair for Web Push notifications"
    task :generate_keys do
      require "web-push"
      keys = WebPush.generate_key
      puts ""
      puts "VAPID key pair generated."
      puts ""
      puts "Add these to your host app's config/initializers/coplan.rb:"
      puts ""
      puts "  config.vapid_public_key  = #{keys.public_key.inspect}"
      puts "  config.vapid_private_key = #{keys.private_key.inspect}"
      puts "  config.vapid_subject     = \"mailto:you@example.com\""
      puts ""
      puts "For production, store the private key in your secrets manager"
      puts "(e.g., Rails encrypted credentials) and reference it from the initializer."
    end
  end
end
