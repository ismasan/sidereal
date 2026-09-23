# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CommentsProjector do
  include Sourced::Testing::RSpec

  let(:test_db) { Sequel.sqlite }

  before do
    test_db.create_table(:comments) do
      String :comment_id, primary_key: true
      String :subject_id, null: false
      String :commenter_id, null: false
      String :content, null: false
      String :status, null: false
      String :vibe, null: false
      String :created_at, null: false
      String :updated_at, null: false
    end

    allow(Sourced).to receive_message_chain(:store, :db).and_return(test_db)
  end

  let(:subject_id) { Subjects.first.id }
  let(:comment_id) { SecureRandom.uuid }
  let(:created) do
    { comment_id:, subject_id:, commenter_id: SecureRandom.uuid, content: 'Well said!' }
  end

  describe 'evolve' do
    it 'projects a pending comment from CommentCreated' do
      with_reactor(CommentsProjector, comment_id:)
        .given(Comment::CommentCreated, **created)
        .then { |result|
          expect(result.state).to include(comment_id:, subject_id:, content: 'Well said!', status: 'pending', vibe: 'unknown')
          expect(result.state[:created_at]).to be_a(String)
        }
    end

    it 'moves to moderating on ModerationStarted' do
      with_reactor(CommentsProjector, comment_id:)
        .given(Comment::CommentCreated, **created)
        .and(Comment::ModerationStarted, comment_id:, started_by: 'moderator')
        .then { |result| expect(result.state[:status]).to eq('moderating') }
    end

    {
      Comment::MarkedPositive => %w[approved positive],
      Comment::MarkedNeutral => %w[approved neutral],
      Comment::MarkedNegative => %w[approved negative],
      Comment::MarkedSpam => %w[spam unknown]
    }.each do |evt, (status, vibe)|
      it "#{evt.name.split('::').last} sets status #{status} and vibe #{vibe}" do
        with_reactor(CommentsProjector, comment_id:)
          .given(Comment::CommentCreated, **created)
          .and(Comment::ModerationStarted, comment_id:, started_by: 'moderator')
          .and(evt, comment_id:)
          .then { |result| expect(result.state).to include(status:, vibe:) }
      end
    end
  end

  describe 'sync — DB upserts' do
    it 'writes and updates the row' do
      with_reactor(CommentsProjector, comment_id:)
        .given(Comment::CommentCreated, **created)
        .and(Comment::ModerationStarted, comment_id:, started_by: 'moderator')
        .and(Comment::MarkedPositive, comment_id:)
        .then! { |_|
          row = test_db[:comments].where(comment_id:).first
          expect(row).to include(status: 'approved', vibe: 'positive', content: 'Well said!')
        }
    end
  end

  describe 'class-level queries' do
    # ModerationStarted is the one event here that needs more than a comment_id.
    EXTRA_ATTRS = { Comment::ModerationStarted => { started_by: 'moderator' } }.freeze

    def project(id, *events)
      with_reactor(CommentsProjector, comment_id: id)
        .given(Comment::CommentCreated, **created, comment_id: id)
        .tap { |t| events.each { |e| t.and(e, comment_id: id, **EXTRA_ATTRS.fetch(e, {})) } }
        .then! { |_| }
    end

    it '.find returns the row or nil' do
      project(comment_id)
      expect(described_class.find(comment_id)).to include(comment_id:, status: 'pending')
      expect(described_class.find('nope')).to be_nil
    end

    it '.board_for groups a subject’s comments by status and leaves spam out' do
      project('a')
      project('b', Comment::ModerationStarted)
      project('c', Comment::ModerationStarted, Comment::MarkedNeutral)
      project('d', Comment::ModerationStarted, Comment::MarkedSpam)

      board = described_class.board_for(subject_id)
      expect(board[:pending].map { |r| r[:comment_id] }).to eq(['a'])
      expect(board[:moderating].map { |r| r[:comment_id] }).to eq(['b'])
      expect(board[:approved].map { |r| r[:comment_id] }).to eq(['c'])
    end

    it '.board_for ignores other subjects' do
      project('a')
      expect(described_class.board_for(Subjects.all.last.id)).to eq(pending: [], moderating: [], approved: [])
    end

    it '.board_for with a nil subject covers every subject' do
      project('a')
      project('b', Comment::ModerationStarted)
      board = described_class.board_for(nil)
      expect(board[:pending].map { |r| r[:comment_id] }).to eq(['a'])
      expect(board[:moderating].map { |r| r[:comment_id] }).to eq(['b'])
    end

    it '.spam_count with a nil subject counts spam across every subject' do
      project('d', Comment::ModerationStarted, Comment::MarkedSpam)
      expect(described_class.spam_count(nil)).to eq(1)
    end

    it '.spam_count counts spam for a subject' do
      project('d', Comment::ModerationStarted, Comment::MarkedSpam)
      project('e', Comment::ModerationStarted, Comment::MarkedSpam)
      project('f', Comment::ModerationStarted, Comment::MarkedPositive)
      expect(described_class.spam_count(subject_id)).to eq(2)
    end
  end
end
