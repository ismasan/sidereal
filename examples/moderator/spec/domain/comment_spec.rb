# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Comment do
  include Sourced::Testing::RSpec

  let(:comment_id) { SecureRandom.uuid }
  let(:commenter_id) { SecureRandom.uuid }
  let(:subject_id) { Subjects.first.id }
  let(:created) do
    { comment_id:, subject_id:, commenter_id:, content: 'This is a terrible take because…' }
  end

  describe Comment::CreateComment do
    it 'creates a pending comment' do
      with_reactor(Comment, comment_id:)
        .when(Comment::CreateComment, comment_id:, subject_id:, commenter_id:, content: '  Well said!  ')
        .then(Comment::CommentCreated, comment_id:, subject_id:, commenter_id:, content: 'Well said!')
    end

    it 'silently no-ops a re-submit of an existing comment' do
      with_reactor(Comment, comment_id:)
        .given(Comment::CommentCreated, **created)
        .when(Comment::CreateComment, comment_id:, subject_id:, commenter_id:, content: 'again')
        .then
    end

    it 'rejects a blank commenter' do
      with_reactor(Comment, comment_id:)
        .when(Comment::CreateComment, comment_id:, subject_id:, content: 'hi')
        .then(RuntimeError, 'commenter required')
    end

    it 'rejects an unknown subject' do
      with_reactor(Comment, comment_id:)
        .when(Comment::CreateComment, comment_id:, subject_id: SecureRandom.uuid, commenter_id:, content: 'hi')
        .then(RuntimeError, 'unknown subject')
    end
  end

  describe Comment::StartModeration do
    it 'moves a pending comment into moderation' do
      with_reactor(Comment, comment_id:)
        .given(Comment::CommentCreated, **created)
        .when(Comment::StartModeration, comment_id:, started_by: 'moderator')
        .then(Comment::ModerationStarted, comment_id:, started_by: 'moderator')
    end

    it 'silently no-ops when moderation already started (two moderators race)' do
      with_reactor(Comment, comment_id:)
        .given(Comment::CommentCreated, **created)
        .and(Comment::ModerationStarted, comment_id:, started_by: 'moderator')
        .when(Comment::StartModeration, comment_id:, started_by: 'moderator')
        .then
    end

    it 'silently no-ops on an already moderated comment' do
      with_reactor(Comment, comment_id:)
        .given(Comment::CommentCreated, **created)
        .and(Comment::ModerationStarted, comment_id:, started_by: 'moderator')
        .and(Comment::MarkedSpam, comment_id:)
        .when(Comment::StartModeration, comment_id:, started_by: 'moderator')
        .then
    end

    it 'silently no-ops a comment that does not exist' do
      with_reactor(Comment, comment_id:)
        .when(Comment::StartModeration, comment_id:, started_by: 'moderator')
        .then
    end

    # The Classifier reads this off the event to decide whether the verdict is
    # its to give, so the actor has to survive the command→event hop.
    it 'carries started_by onto the event' do
      with_reactor(Comment, comment_id:)
        .given(Comment::CommentCreated, **created)
        .when(Comment::StartModeration, comment_id:, started_by: 'classifier')
        .then(Comment::ModerationStarted, comment_id:, started_by: 'classifier')
    end

    it 'rejects an unknown actor' do
      expect {
        Comment::StartModeration.parse(payload: { comment_id:, started_by: 'nobody' })
      }.to raise_error(Plumb::ParseError, /must be included in/)
    end
  end

  describe 'verdicts' do
    {
      Comment::MarkPositive => Comment::MarkedPositive,
      Comment::MarkNeutral => Comment::MarkedNeutral,
      Comment::MarkNegative => Comment::MarkedNegative,
      Comment::MarkSpam => Comment::MarkedSpam
    }.each do |cmd, evt|
      it "#{cmd.name.split('::').last} on a moderating comment emits #{evt.name.split('::').last}" do
        with_reactor(Comment, comment_id:)
          .given(Comment::CommentCreated, **created)
          .and(Comment::ModerationStarted, comment_id:, started_by: 'moderator')
          .when(cmd, comment_id:)
          .then(evt, comment_id:)
      end

      it "#{cmd.name.split('::').last} silently no-ops a comment still in the inbox" do
        with_reactor(Comment, comment_id:)
          .given(Comment::CommentCreated, **created)
          .when(cmd, comment_id:)
          .then
      end

      it "#{cmd.name.split('::').last} silently no-ops a comment that already has a verdict (stale page)" do
        with_reactor(Comment, comment_id:)
          .given(Comment::CommentCreated, **created)
          .and(Comment::ModerationStarted, comment_id:, started_by: 'moderator')
          .and(Comment::MarkedPositive, comment_id:)
          .when(cmd, comment_id:)
          .then
      end
    end

    it 'silently no-ops a comment that does not exist' do
      with_reactor(Comment, comment_id:)
        .when(Comment::MarkSpam, comment_id:)
        .then
    end
  end

  describe 'state' do
    it 'tracks status and vibe through the pipeline' do
      with_reactor(Comment, comment_id:)
        .given(Comment::CommentCreated, **created)
        .and(Comment::ModerationStarted, comment_id:, started_by: 'moderator')
        .and(Comment::MarkedNegative, comment_id:)
        .then { |result|
          expect(result.state.status).to eq('approved')
          expect(result.state.vibe).to eq('negative')
          expect(result.state.content).to eq(created[:content])
        }
    end

    it 'leaves vibe unknown for spam' do
      with_reactor(Comment, comment_id:)
        .given(Comment::CommentCreated, **created)
        .and(Comment::ModerationStarted, comment_id:, started_by: 'moderator')
        .and(Comment::MarkedSpam, comment_id:)
        .then { |result|
          expect(result.state.status).to eq('spam')
          expect(result.state.vibe).to eq('unknown')
        }
    end
  end
end
