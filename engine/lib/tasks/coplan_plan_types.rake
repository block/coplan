namespace :coplan do
  namespace :plan_types do
    desc "Install the default plan types (fills blank fields on existing types; FORCE=1 overwrites edited fields with the shipped defaults)"
    task install_defaults: :environment do
      result = CoPlan::PlanTypes::InstallDefaults.call(force: ENV["FORCE"] == "1")

      puts "coplan:plan_types:install_defaults#{" (FORCE)" if ENV["FORCE"] == "1"}"
      puts "  created: #{result.created.any? ? result.created.join(", ") : "(none)"}"
      puts "  updated: #{result.updated.any? ? result.updated.join(", ") : "(none)"}"
      puts "  skipped: #{result.skipped.any? ? result.skipped.join(", ") : "(none)"} (already match or hand-edited; FORCE=1 overwrites)"
    end
  end
end
