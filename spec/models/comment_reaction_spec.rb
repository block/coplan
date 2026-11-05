require "rails_helper"

RSpec.describe CoPlan::CommentReaction, type: :model do
  it "is valid with valid attributes" do
    expect(create(:comment_reaction)).to be_valid
  end

  it "only accepts kinds from the fixed set" do
    reaction = build(:comment_reaction, kind: "👍")
    expect(reaction).not_to be_valid
    expect(reaction.errors[:kind]).to include("is not included in the list")
  end

  it "allows one reaction of each kind per person per comment" do
    existing = create(:comment_reaction)
    duplicate = build(:comment_reaction, comment: existing.comment, user: existing.user, kind: existing.kind)
    expect(duplicate).not_to be_valid

    other_kind = build(:comment_reaction, comment: existing.comment, user: existing.user, kind: "heart")
    expect(other_kind).to be_valid
  end

  it "enforces uniqueness in the database too" do
    existing = create(:comment_reaction)
    duplicate = build(:comment_reaction, comment: existing.comment, user: existing.user, kind: existing.kind)
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "maps every kind to an emoji and a spoken label" do
    described_class::KINDS.each_key do |kind|
      expect(described_class.emoji_for(kind)).to be_present
      expect(described_class.label_for(kind)).to be_present
    end
    expect(described_class.emoji_for("thumbs_up")).to eq("👍")
  end

  describe ".summarize" do
    it "groups by kind in the fixed order with reactors in the order they reacted" do
      comment = create(:comment)
      alex = create(:coplan_user, name: "Alex")
      sam = create(:coplan_user, name: "Sam")
      create(:comment_reaction, comment: comment, user: sam, kind: "rocket", created_at: 2.minutes.ago)
      create(:comment_reaction, comment: comment, user: alex, kind: "thumbs_up", created_at: 1.minute.ago)
      create(:comment_reaction, comment: comment, user: sam, kind: "thumbs_up", created_at: 3.minutes.ago)

      summary = described_class.summarize(comment.reactions.includes(:user))

      expect(summary.map { |entry| entry[:kind] }).to eq(%w[thumbs_up rocket])
      expect(summary.first).to include(emoji: "👍", count: 2)
      expect(summary.first[:reactions].map(&:user)).to eq([ sam, alex ])
    end
  end

  it "is removed with its comment" do
    reaction = create(:comment_reaction)
    reaction.comment.destroy!
    expect(described_class.exists?(reaction.id)).to be(false)
  end

  it "is removed with its user" do
    reaction = create(:comment_reaction)
    reaction.user.destroy!
    expect(described_class.exists?(reaction.id)).to be(false)
  end
end
