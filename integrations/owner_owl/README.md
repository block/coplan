# CoPlan Owner Owl adapter

`coplan-owner-owl` routes plan approval requests from explicit repository paths through Owner Owl's Ownership API v2.

Add the adapter next to `coplan-engine`:

```ruby
gem "coplan-owner-owl"
```

Configure it with an HTTP client that can reach the Ownership API. The client must respond to `post(path, body, headers)`; a Square deployment normally supplies its service-container connector:

```ruby
CoPlan::OwnerOwl.install!(
  http_client: Sq::Common.connector.create(:ownership_api)
)
```

Configure that connector to target the `github-webhooks` app's `ownership` cluster. The adapter sends `expandTeams: true`, so Owner Owl team principals can be resolved to individual CoPlan users. By default, GitHub identities are matched case-insensitively against `CoPlan::User#username`. A host with different identity domains can override the mapping:

```ruby
CoPlan.configure do |config|
  config.approval_identity_resolver = ->(github_login) {
    CoPlan::User.find_by(external_id: GithubDirectory.ldap_for(github_login))
  }
end
```

Agents attach paths when creating or updating a plan:

```json
{
  "touched_files": [
    { "repo": "squareup/example", "ref": "main", "path": "payments/service.rb" }
  ]
}
```

The plan author then requests routing with `POST /api/v1/plans/:id/approval_requests`. The response contains the pending approver collaborators plus any Owner Owl identities that could not be mapped to a CoPlan user. Repeating the request reconciles only approvers previously routed by Owner Owl; manually assigned approvers are preserved.
