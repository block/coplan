puts "Seeding users..."
hampton = CoPlan::User.find_or_create_by!(email: "hampton@squareup.com") do |u|
  u.external_id = "hampton@squareup.com"
  u.name = "Hampton Lintorn-Catlin"
  u.username = "hampton"
  u.admin = true
  u.avatar_url = "https://avatars.githubusercontent.com/u/111?s=80"
  u.title = "Staff Engineer"
  u.team = "Developer Tools"
end
hampton.update!(avatar_url: "https://avatars.githubusercontent.com/u/111?s=80") if hampton.avatar_url.blank?

puts "Seeding plans..."
if CoPlan::Plan.count == 0
  plan = CoPlan::Plans::Create.call(
    title: "Q3 Product Roadmap",
    content: "# Q3 Product Roadmap\n\n## Goals\n\n- Launch new dashboard\n- Improve API performance\n- Add team collaboration features\n\n## Timeline\n\n### Month 1\n- Design reviews\n- Technical planning\n\n### Month 2\n- Core implementation\n- Testing\n\n### Month 3\n- Beta launch\n- Feedback collection\n",
    user: hampton
  )
  plan.update!(status: "considering")
end

puts "Seeding comments..."
if CoPlan::CommentThread.count == 0
  plan = CoPlan::Plan.first
  if plan&.current_plan_version
    reviewer = CoPlan::User.find_or_create_by!(email: "reviewer@squareup.com") do |u|
      u.external_id = "reviewer@squareup.com"
      u.name = "Plan Reviewer"
      u.title = "Senior Engineer"
      u.team = "Platform"
    end

    thread = CoPlan::CommentThread.create!(
      plan: plan,
      plan_version: plan.current_plan_version,
      start_line: 5,
      end_line: 8,
      created_by_user: reviewer
    )
    thread.comments.create!(
      author_type: "human",
      author_id: reviewer.id,
      body_markdown: "I think the timeline for Month 1 is too aggressive. Can we break this into smaller milestones?"
    )

    general_thread = CoPlan::CommentThread.create!(
      plan: plan,
      plan_version: plan.current_plan_version,
      created_by_user: hampton
    )
    general_thread.comments.create!(
      author_type: "human",
      author_id: hampton.id,
      body_markdown: "Overall this is looking good. Let's move forward with the **beta launch** plan."
    )
  end
end

puts "Seeding API tokens..."
if CoPlan::ApiToken.count == 0
  raw_token = "dev-api-token-#{SecureRandom.hex(8)}"
  CoPlan::ApiToken.create!(
    user: hampton,
    name: "Development Agent",
    token_digest: Digest::SHA256.hexdigest(raw_token),
    token_prefix: raw_token[0, 8]
  )
  puts "  Created API token: #{raw_token}"
  puts "  (Save this — it won't be shown again)"
end

puts "Seeding plan types..."
general = CoPlan::PlanType.find_or_create_by!(name: "General") do |pt|
  pt.description = "General-purpose plan"
end
CoPlan::PlanType.find_or_create_by!(name: "RFC") do |pt|
  pt.description = "Request for Comments — propose a significant change for team review"
  pt.default_tags = ["rfc"]
end
CoPlan::PlanType.find_or_create_by!(name: "Design Doc") do |pt|
  pt.description = "Technical design document for a new system or feature"
  pt.default_tags = ["design"]
end
CoPlan::PlanType.find_or_create_by!(name: "ADR") do |pt|
  pt.description = "Architecture Decision Record — document a key technical decision"
  pt.default_tags = ["adr"]
end

# Backfill any plans without a plan type
CoPlan::Plan.where(plan_type_id: nil).update_all(plan_type_id: general.id)

puts "Seeding tags on plans..."
CoPlan::Plan.includes(:tags, :plan_type).find_each do |p|
  if p.tags.empty? && p.plan_type&.default_tags&.any?
    p.tag_names = p.plan_type.default_tags
  end
end

# Add some demo plans with tags for local development
if CoPlan::Plan.count < 3
  rfc_type = CoPlan::PlanType.find_by(name: "RFC")
  design_type = CoPlan::PlanType.find_by(name: "Design Doc")

  api_plan = CoPlan::Plans::Create.call(
    title: "API Rate Limiting Strategy",
    content: "# API Rate Limiting Strategy\n\n## Problem\n\nOur API endpoints have no rate limiting, leading to occasional abuse.\n\n## Proposal\n\nImplement token-bucket rate limiting at the gateway level.\n\n## Alternatives Considered\n\n- Per-IP limiting\n- API key quotas\n",
    user: hampton,
    plan_type_id: rfc_type&.id
  )
  api_plan.update!(status: "considering")
  api_plan.tag_names = ["api", "infrastructure", "security"]

  auth_plan = CoPlan::Plans::Create.call(
    title: "Authentication System Redesign",
    content: "# Authentication System Redesign\n\n## Goals\n\n- Migrate from session-based to token-based auth\n- Support SSO providers\n- Improve security posture\n\n## Architecture\n\nOIDC-based flow with JWT access tokens.\n",
    user: hampton,
    plan_type_id: design_type&.id
  )
  auth_plan.update!(status: "developing")
  auth_plan.tag_names = ["security", "infrastructure", "design"]
end

# Tag the original Q3 roadmap if it has no tags
q3 = CoPlan::Plan.find_by(title: "Q3 Product Roadmap")
q3.tag_names = ["roadmap", "product"] if q3 && q3.tags.empty?

puts "Seeding automated plan reviewers..."
CoPlan::AutomatedPlanReviewer.create_defaults

puts "Done! #{CoPlan::User.count} users, #{CoPlan::Plan.count} plans, #{CoPlan::CommentThread.count} threads, #{CoPlan::Comment.count} comments, #{CoPlan::ApiToken.count} API tokens, #{CoPlan::AutomatedPlanReviewer.count} reviewers."
