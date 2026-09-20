# frozen_string_literal: true

require 'securerandom'
require_relative 'ui/layout'
require_relative 'ui/comment_box_page'
require_relative 'ui/pipeline_page'
require_relative 'ui/comment_detail_page'

class ModeratorApp < Sidereal::App
  # Scoped cookie name so this demo's session doesn't collide with the other
  # examples on localhost. The fallback keeps the demo runnable with no .env;
  # set SESSION_SECRET to anything else and existing cookies stop validating.
  session secret: ENV.fetch('SESSION_SECRET', 'm' * 64), key: 'sidereal_moderator.session'
  layout ModeratorLayout

  # Stamps the session's commenter id onto every command. Only CreateComment
  # declares `commenter_id`; Plumb drops the key for the others.
  before_command do |cmd|
    session[:commenter_id] ||= SecureRandom.uuid
    cmd
      .with_metadata(producer: 'UI')
      .with_payload(commenter_id: session[:commenter_id])
  end

  # One channel per comment. Both pipeline pages subscribe with the
  # `comments.>` glob, so every comment's events and the projector's
  # Projected signal reach every open board.
  channel_name do |msg|
    if msg.payload.respond_to?(:comment_id) && msg.payload.comment_id
      "comments.#{msg.payload.comment_id}"
    else
      'comments'
    end
  end

  # Frozen-snapshot view: the detail page with the comment replayed up to the
  # Nth message of its stream. Static — no SSE subscription. The step links
  # and arrows in the event feed point here.
  get '/comments/:comment_id/:step' do |comment_id:, step:|
    page = CommentDetailPage.load(params, self)
    halt 404, 'Not found' unless page.valid_step?

    component page
  end

  # The comment box: append the command, then send the commenter back to a
  # fresh form carrying the new id, so the page can offer a link into the
  # pipeline for that comment.
  handle Comment::CreateComment do |cmd|
    dispatch cmd
    browser.redirect "/?sent=#{cmd.payload.comment_id}&subject_id=#{cmd.payload.subject_id}"
  end

  # Moderator verdicts are plain async commands: the detail page the
  # moderator is already on re-renders over SSE once the projector catches up.
  handle Comment::StartModeration,
         Comment::MarkPositive,
         Comment::MarkNeutral,
         Comment::MarkNegative,
         Comment::MarkSpam

  page CommentBoxPage
  page PipelinePage
  page CommentDetailPage
end
