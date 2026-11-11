# Test setup for legacy/empty bodies. Production model writes remain immutable.
module VersionFixtures
  def set_version_fixture(version, **attributes)
    if attributes.key?(:content_markdown)
      attributes[:content_sha256] = Digest::SHA256.hexdigest(attributes[:content_markdown].to_s)
    end
    CoPlan::PlanVersion.where(id: version.id).update_all(attributes)
    version.reload
  end
end

RSpec.configure { |config| config.include VersionFixtures }
