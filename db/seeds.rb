puts "Seeding organizations..."
square = Organization.find_or_create_by!(slug: "square") do |org|
  org.name = "Square"
  org.allowed_email_domains = ["squareup.com", "block.xyz"]
end

puts "Seeding users..."
hampton = User.find_or_create_by!(organization: square, email: "hampton@squareup.com") do |u|
  u.name = "Hampton Lintorn-Catlin"
  u.org_role = "admin"
end

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
    reviewer = User.find_or_create_by!(organization: square, email: "reviewer@squareup.com") do |u|
      u.name = "Plan Reviewer"
      u.org_role = "member"
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

puts "Seeding automated plan reviewers..."
CoPlan::AutomatedPlanReviewer.create_defaults

puts "Done! #{Organization.count} orgs, #{User.count} users, #{CoPlan::Plan.count} plans, #{CoPlan::CommentThread.count} threads, #{CoPlan::Comment.count} comments, #{CoPlan::ApiToken.count} API tokens, #{CoPlan::AutomatedPlanReviewer.count} reviewers."
