# frozen_string_literal: true

require 'securerandom'
require_relative 'components/subject_picker'

# ui:CommentBox — where the public leaves comments.
class CommentBoxPage < Sidereal::Page
  path '/'

  def self.load(params, ctx)
    # Establish the commenter's identity on first visit; `before_command`
    # stamps it onto CreateComment.
    ctx.session[:commenter_id] ||= SecureRandom.uuid
    new(
      subject: Subjects.find(params[:subject_id]) || Subjects.first,
      sent_id: params[:sent]
    )
  end

  def initialize(subject:, sent_id: nil)
    @subject = subject
    @sent_id = sent_id
  end

  def view_template
    div(id: 'comment-box-page', class: 'page page--narrow') do
      header(class: 'topbar') do
        a(href: '/', class: 'brand') do
          span(class: 'brand__mark', aria_hidden: true)
          plain 'Moderator'
        end
        nav(class: 'topbar__nav') do
          a(href: "/comments?subject_id=#{@subject.id}", class: 'button') { 'Open the board' }
        end
      end

      main(class: 'page__body') do
        h1(class: 'page__title') { 'Leave a comment' }
        p(class: 'page__lede') { 'Every comment goes through moderation before it is published.' }

        if @sent_id
          div(class: 'notice', id: 'sent-notice') do
            span(class: 'notice__icon', aria_hidden: true)
            p do
              plain 'Your comment is in the moderation inbox. '
              a(href: "/comments/#{@sent_id}") { 'Follow it through the pipeline' }
            end
          end
        end

        div(class: 'panel') do
          command Comment::CreateComment, class: 'comment-form', autocomplete: 'off' do |f|
            div(class: 'command-field') do
              label(for: 'comment-subject', class: 'field-label') { 'Subject' }
              select(id: 'comment-subject', name: 'command[payload][subject_id]', class: 'select') do
                Subjects.all.each do |s|
                  option(value: s.id, selected: s.id == @subject.id) { s.title }
                end
              end
            end

            label do
              span(class: 'field-label') { 'Comment' }
              f.text_area :content,
                class: 'textarea',
                rows: 7,
                required: true,
                placeholder: 'Be nice. Or don’t — that’s what the pipeline is for.'
            end

            div(class: 'form-actions') do
              button(type: :submit, class: 'button button--primary') { 'Post comment' }
            end
          end
        end
      end
    end
  end
end
